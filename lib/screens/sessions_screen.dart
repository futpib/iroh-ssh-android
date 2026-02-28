import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:iroh_ssh_app/models/connection_type.dart';
import 'package:iroh_ssh_app/models/ssh_session_info.dart';
import 'package:iroh_ssh_app/screens/connect_screen.dart';
import 'package:iroh_ssh_app/services/session_messages.dart';
import 'package:iroh_ssh_app/services/settings_storage.dart';
import 'package:iroh_ssh_app/src/rust/api/simple.dart';
import 'package:iroh_ssh_app/widgets/terminal_pane.dart';
import 'package:iroh_ssh_app/widgets/terminal_tab.dart';

class SessionsScreen extends StatefulWidget {
  final List<SshSessionInfo> existingSessions;

  @visibleForTesting
  final bool connectOnInit;

  const SessionsScreen({
    super.key,
    required this.existingSessions,
    this.connectOnInit = true,
  });

  @override
  State<SessionsScreen> createState() => _SessionsScreenState();
}

class _SessionsScreenState extends State<SessionsScreen>
    with TickerProviderStateMixin {
  static final bool _isAndroid = Platform.isAndroid;

  late List<SshSessionInfo> _sessions;
  late TabController _tabController;
  final Map<String, GlobalKey<TerminalTabState>> _tabKeys = {};
  double _terminalFontSize = 14.0;
  String _terminalTheme = 'default';
  String _barPosition = 'bottom';
  double _barHideOffset = 0.0;
  final ValueNotifier<bool> _scalingNotifier = ValueNotifier(false);
  void Function(Object)? _serviceDataCallback;

  @override
  void initState() {
    super.initState();
    _sessions = List.of(widget.existingSessions);
    _tabController = TabController(length: _sessions.length, vsync: this);
    _tabController.addListener(_onTabChanged);
    for (final session in _sessions) {
      _tabKeys[session.sessionId] = GlobalKey<TerminalTabState>();
    }
    _loadTerminalSettings();
    if (_isAndroid) {
      _listenToService();
    }
  }

  void _listenToService() {
    _serviceDataCallback = _onServiceData;
    FlutterForegroundTask.addTaskDataCallback(_serviceDataCallback!);
  }

  void _onServiceData(Object data) {
    if (data is! String) return;
    try {
      final event = ServiceEvent.decode(data);
      switch (event) {
        case DisconnectedEvent():
          _onSessionDisconnected(event.sessionId, event.reason);
        case ConnectedEvent():
          // New session added via the add-session flow
          _onNewSessionConnected(event);
        case SessionListEvent():
          // Could be used for refresh, but we already have the list
          break;
        default:
          // output, replay, auth_prompt, etc. are handled by TerminalTab
          break;
      }
    } catch (_) {}
  }

  void _onSessionDisconnected(String sessionId, String reason) {
    final index = _sessions.indexWhere((s) => s.sessionId == sessionId);
    if (index < 0) return;
    _closeSessionAt(index);
  }

  void _onNewSessionConnected(ConnectedEvent event) {
    // This is handled by ConnectScreen's completer, not here.
    // But if somehow we get a connected event for a session we don't know about,
    // we could add it. For now, no-op.
  }

  Future<void> _loadTerminalSettings() async {
    final settings = await SettingsStorage.instance.load();
    if (mounted) {
      setState(() {
        _terminalFontSize = settings.terminalFontSize;
        _terminalTheme = settings.terminalTheme;
        _barPosition = settings.barPosition;
      });
    }
  }

  void _onTabChanged() {
    if (!_tabController.indexIsChanging) {
      final session = _sessions[_tabController.index];
      final keyboardOpen = MediaQuery.of(context).viewInsets.bottom > 0;
      if (keyboardOpen || !_isAndroid) {
        _tabKeys[session.sessionId]?.currentState?.requestFocus();
      }
      setState(() {});
    }
  }

  @override
  void dispose() {
    if (_serviceDataCallback != null) {
      FlutterForegroundTask.removeTaskDataCallback(_serviceDataCallback!);
    }
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    _scalingNotifier.dispose();
    super.dispose();
  }

  void _rebuildTabController(int newLength, {int? newIndex}) {
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    _tabController = TabController(
      length: newLength,
      vsync: this,
      initialIndex: newIndex ?? 0,
    );
    _tabController.addListener(_onTabChanged);
  }

  Future<void> _addSession() async {
    final result = await Navigator.of(context).push<SshSessionInfo>(
      MaterialPageRoute(
        builder: (_) => const ConnectScreen(returnResult: true),
      ),
    );
    if (result != null && mounted) {
      setState(() {
        _sessions.add(result);
        _tabKeys[result.sessionId] = GlobalKey<TerminalTabState>();
        _rebuildTabController(_sessions.length,
            newIndex: _sessions.length - 1);
      });
    }
  }

  void _closeSession(int index) {
    final session = _sessions[index];
    // Send disconnect to service
    if (_isAndroid) {
      FlutterForegroundTask.sendDataToTask(
        DisconnectCommand(sessionId: session.sessionId).encode(),
      );
    }
    _closeSessionAt(index);
  }

  void _closeSessionAt(int index) {
    if (index >= _sessions.length) return;
    final session = _sessions[index];
    _tabKeys.remove(session.sessionId);

    setState(() {
      _sessions.removeAt(index);
      if (_sessions.isEmpty) {
        Navigator.of(context).pop();
        return;
      }
      final newIndex =
          index >= _sessions.length ? _sessions.length - 1 : index;
      _rebuildTabController(_sessions.length, newIndex: newIndex);
    });
  }

  Future<void> _showConnectionInfo(SshSessionInfo session) async {
    final tabState = _tabKeys[session.sessionId]?.currentState;
    tabState?.disableFocus();
    await showDialog(
      context: context,
      builder: (ctx) => _ConnectionInfoDialog(session: session),
    );
    tabState?.enableFocus();
  }

  Future<bool> _onWillPop() async {
    if (_sessions.isEmpty) return true;

    if (_isAndroid) {
      // Detach all sessions and go back — sessions keep running in background
      for (final session in _sessions) {
        FlutterForegroundTask.sendDataToTask(
          DetachCommand(sessionId: session.sessionId).encode(),
        );
      }
      return true;
    }

    // Non-Android: confirm disconnect
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Disconnect all?'),
        content: Text(
          'This will close ${_sessions.length} active session${_sessions.length > 1 ? 's' : ''}.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Disconnect'),
          ),
        ],
      ),
    );

    return confirmed ?? false;
  }

  Widget _buildBar(bool keyboardOpen) {
    if (_sessions.isEmpty) return const SizedBox.shrink();
    final currentSession = _sessions[_tabController.index];
    final theme = Theme.of(context);
    final appBarTheme = AppBarTheme.of(context);
    final backgroundColor =
        appBarTheme.backgroundColor ?? theme.colorScheme.surface;
    final foregroundColor =
        appBarTheme.foregroundColor ?? theme.colorScheme.onSurface;

    return Material(
      color: backgroundColor,
      elevation: appBarTheme.elevation ?? 4,
      child: SafeArea(
        top: _barPosition == 'top',
        bottom: _barPosition == 'bottom',
        child: SizedBox(
          height: kToolbarHeight,
          child: Row(
            children: [
              const SizedBox(width: 4),
              IconButton(
                icon: Icon(Icons.arrow_back, color: foregroundColor),
                onPressed: () async {
                  if (await _onWillPop()) {
                    if (mounted) {
                      Navigator.of(context).pop();
                    }
                  }
                },
              ),
              Expanded(
                child: Text(
                  currentSession.displayName,
                  style: (appBarTheme.titleTextStyle ??
                          theme.textTheme.titleLarge)
                      ?.copyWith(color: foregroundColor),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                icon: Icon(Icons.info_outline, color: foregroundColor),
                onPressed: () => _showConnectionInfo(currentSession),
                tooltip: 'Connection info',
              ),
              if (_sessions.length > 1)
                _buildTabCountButton(foregroundColor),
              IconButton(
                icon: Icon(Icons.add, color: foregroundColor),
                onPressed: _addSession,
                tooltip: 'New connection',
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTabCountButton(Color foregroundColor) {
    return IconButton(
      tooltip: 'Tabs',
      onPressed: _showTabOverview,
      icon: Container(
        width: 24,
        height: 24,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: foregroundColor, width: 2),
        ),
        alignment: Alignment.center,
        child: Text(
          '${_sessions.length}',
          style: TextStyle(
            color: foregroundColor,
            fontSize: 12,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }

  void _showTabOverview() async {
    final tabState = _tabKeys[_sessions[_tabController.index].sessionId]?.currentState;
    tabState?.disableFocus();
    final result = await showDialog<_TabAction>(
      context: context,
      builder: (ctx) => _TabOverviewDialog(
        sessions: _sessions,
        currentIndex: _tabController.index,
      ),
    );
    tabState?.enableFocus();
    if (result == null) return;
    switch (result.action) {
      case 'switch':
        _tabController.animateTo(result.index);
      case 'close':
        _closeSession(result.index);
    }
  }


  double _computeBarHeight() {
    final mediaQuery = MediaQuery.of(context);
    final safePadding = _barPosition == 'top'
        ? mediaQuery.padding.top
        : mediaQuery.padding.bottom;
    return kToolbarHeight + safePadding;
  }

  @override
  Widget build(BuildContext context) {
    if (_sessions.isEmpty) {
      return const SizedBox.shrink();
    }

    final scaffold = PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _onWillPop()) {
          if (context.mounted) {
            Navigator.of(context).pop();
          }
        }
      },
      child: Builder(
        builder: (context) {
          final keyboardOpen = MediaQuery.of(context).viewInsets.bottom > 0;
          final isTop = _barPosition == 'top';
          final barHeight = keyboardOpen ? 0.0 : _computeBarHeight();
          final clampedOffset = _barHideOffset.clamp(0.0, barHeight);
          final barShift = keyboardOpen ? barHeight : clampedOffset;
          final terminalShift = isTop
              ? barHeight - barShift
              : -(barHeight - barShift);

          final terminalView = TabBarView(
            controller: _tabController,
            physics: ScaleAwareScrollPhysics(_scalingNotifier),
            children: List.generate(_sessions.length, (i) {
              final session = _sessions[i];
              return TerminalTab(
                key: _tabKeys[session.sessionId],
                session: session,
                onDisconnected: () => _closeSession(i),
                connectOnInit: widget.connectOnInit,
                fontSize: _terminalFontSize,
                themeName: _terminalTheme,
                onScalingChanged: (scaling) {
                  _scalingNotifier.value = scaling;
                },
                onVerticalScrollDelta: (delta) {
                  setState(() {
                    _barHideOffset = (_barHideOffset - delta).clamp(0.0, barHeight);
                  });
                },
              );
            }),
          );

          final barWidget = _buildBar(keyboardOpen);

          return Scaffold(
            resizeToAvoidBottomInset: false,
            body: Stack(
              children: [
                Positioned.fill(
                  child: Transform.translate(
                    offset: Offset(0, terminalShift),
                    child: terminalView,
                  ),
                ),
                if (!keyboardOpen)
                  Positioned(
                    top: isTop ? 0 : null,
                    bottom: isTop ? null : 0,
                    left: 0,
                    right: 0,
                    child: Transform.translate(
                      offset: Offset(0, isTop ? -barShift : barShift),
                      child: barWidget,
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );

    if (_isAndroid) {
      return WithForegroundTask(child: scaffold);
    }
    return scaffold;
  }
}

class _TabAction {
  final String action;
  final int index;
  const _TabAction(this.action, this.index);
}

class _TabOverviewDialog extends StatelessWidget {
  final List<SshSessionInfo> sessions;
  final int currentIndex;

  const _TabOverviewDialog({
    required this.sessions,
    required this.currentIndex,
  });

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Tabs'),
      contentPadding: const EdgeInsets.only(top: 12),
      content: SizedBox(
        width: double.maxFinite,
        child: ListView.builder(
          shrinkWrap: true,
          itemCount: sessions.length,
          itemBuilder: (ctx, i) {
            final session = sessions[i];
            final isCurrent = i == currentIndex;
            return ListTile(
              selected: isCurrent,
              leading: Icon(
                isCurrent ? Icons.terminal : Icons.tab,
              ),
              title: Text(session.displayName),
              subtitle: Text(session.username),
              trailing: IconButton(
                icon: const Icon(Icons.close, size: 18),
                onPressed: () =>
                    Navigator.pop(ctx, _TabAction('close', i)),
              ),
              onTap: () =>
                  Navigator.pop(ctx, _TabAction('switch', i)),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}

class _ConnectionInfoDialog extends StatefulWidget {
  final SshSessionInfo session;

  const _ConnectionInfoDialog({required this.session});

  @override
  State<_ConnectionInfoDialog> createState() => _ConnectionInfoDialogState();
}

class _ConnectionInfoDialogState extends State<_ConnectionInfoDialog> {
  IrohConnectionInfo? _irohInfo;
  String? _irohError;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    if (widget.session.connectionType == ConnectionType.iroh) {
      _fetch();
      _timer = Timer.periodic(const Duration(seconds: 1), (_) => _fetch());
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _fetch() async {
    try {
      final info = await connectionInfo(port: widget.session.port);
      if (mounted) {
        setState(() {
          _irohInfo = info;
          _irohError = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _irohError = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    return AlertDialog(
      title: const Text('Connection Info'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _infoRow('Type', session.connectionType.label),
          _infoRow('Target', session.displayName),
          if (session.connectionType != ConnectionType.local) ...[
            _infoRow('Username', session.username),
          ],
          if (session.connectionType == ConnectionType.ssh) ...[
            _infoRow('Host', session.host),
            _infoRow('Port', session.port.toString()),
          ],
          if (session.connectionType == ConnectionType.iroh) ...[
            _infoRow('Local port', session.port.toString()),
            if (_irohError != null)
              _infoRow('Error', _irohError!)
            else if (_irohInfo == null)
              _infoRow('Network', 'Waiting for connection...')
            else ...[
              _infoRow(
                'Path',
                _irohInfo!.isDirect
                    ? 'Direct'
                    : _irohInfo!.isRelay
                        ? 'Relay'
                        : 'Unknown',
              ),
              if (_irohInfo!.relayUrl != null)
                _infoRow('Relay', _irohInfo!.relayUrl!),
              if (_irohInfo!.latencyMs != null)
                _infoRow(
                  'Latency',
                  '${_irohInfo!.latencyMs!.toStringAsFixed(1)} ms',
                ),
            ],
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }

  static Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(fontSize: 12, color: Colors.grey)),
          const SizedBox(height: 2),
          SelectableText(
            value,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
          ),
        ],
      ),
    );
  }
}
