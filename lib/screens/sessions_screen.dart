import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:iroh_ssh_app/models/ssh_session_info.dart';
import 'package:iroh_ssh_app/screens/connect_screen.dart';
import 'package:iroh_ssh_app/src/rust/api/simple.dart';
import 'package:iroh_ssh_app/services/settings_storage.dart';
import 'package:iroh_ssh_app/widgets/terminal_tab.dart';

class SessionsScreen extends StatefulWidget {
  final SshSessionInfo initialSession;

  @visibleForTesting
  final bool connectOnInit;

  const SessionsScreen({
    super.key,
    required this.initialSession,
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
  final Map<int, GlobalKey<TerminalTabState>> _tabKeys = {};
  double _terminalFontSize = 14.0;
  String _terminalTheme = 'default';

  @override
  void initState() {
    super.initState();
    _sessions = [widget.initialSession];
    _tabController = TabController(length: 1, vsync: this);
    _tabController.addListener(_onTabChanged);
    _tabKeys[widget.initialSession.port] = GlobalKey<TerminalTabState>();
    _loadTerminalSettings();
    if (_isAndroid) {
      _initForegroundTask();
    }
  }

  Future<void> _initForegroundTask() async {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'iroh_ssh_foreground',
        channelName: 'SSH Session',
        channelDescription: 'Keeps SSH sessions alive in the background',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: false,
        autoRunOnMyPackageReplaced: false,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );

    await FlutterForegroundTask.requestNotificationPermission();
    await FlutterForegroundTask.startService(
      notificationTitle: 'iroh-ssh',
      notificationText: _notificationText,
    );
  }

  Future<void> _loadTerminalSettings() async {
    final settings = await SettingsStorage.instance.load();
    if (mounted) {
      setState(() {
        _terminalFontSize = settings.terminalFontSize;
        _terminalTheme = settings.terminalTheme;
      });
    }
  }

  String get _notificationText {
    final count = _sessions.length;
    return '$count active session${count > 1 ? 's' : ''}';
  }

  Future<void> _updateNotification() async {
    if (!_isAndroid) return;
    await FlutterForegroundTask.updateService(
      notificationTitle: 'iroh-ssh',
      notificationText: _notificationText,
    );
  }

  Future<void> _stopForegroundTask() async {
    if (!_isAndroid) return;
    await FlutterForegroundTask.stopService();
  }

  void _onTabChanged() {
    if (!_tabController.indexIsChanging) {
      final session = _sessions[_tabController.index];
      _tabKeys[session.port]?.currentState?.requestFocus();
      setState(() {});
    }
  }

  @override
  void dispose() {
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    _stopForegroundTask();
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
        _tabKeys[result.port] = GlobalKey<TerminalTabState>();
        _rebuildTabController(_sessions.length,
            newIndex: _sessions.length - 1);
      });
      _updateNotification();
    }
  }

  void _closeSession(int index) {
    final session = _sessions[index];
    _tabKeys.remove(session.port);

    setState(() {
      _sessions.removeAt(index);
      if (_sessions.isEmpty) {
        _stopForegroundTask();
        Navigator.of(context).pop();
        return;
      }
      final newIndex = index >= _sessions.length ? _sessions.length - 1 : index;
      _rebuildTabController(_sessions.length, newIndex: newIndex);
    });
    if (_sessions.isNotEmpty) {
      _updateNotification();
    }
  }

  Future<void> _showConnectionInfo(SshSessionInfo session) async {
    final tabState = _tabKeys[session.port]?.currentState;
    tabState?.disableFocus();
    await showDialog(
      context: context,
      builder: (ctx) => _ConnectionInfoDialog(session: session),
    );
    tabState?.enableFocus();
  }

  Future<bool> _onWillPop() async {
    if (_sessions.isEmpty) return true;

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

  @override
  Widget build(BuildContext context) {
    if (_sessions.isEmpty) {
      return const SizedBox.shrink();
    }

    final currentSession = _sessions[_tabController.index];

    final scaffold = PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _onWillPop()) {
          await _stopForegroundTask();
          if (context.mounted) {
            Navigator.of(context).pop();
          }
        }
      },
      child: Builder(
        builder: (context) {
          final keyboardOpen = MediaQuery.of(context).viewInsets.bottom > 0;
          return Scaffold(
        resizeToAvoidBottomInset: false,
        appBar: keyboardOpen
            ? null
            : AppBar(
                title: Text(currentSession.displayName),
                actions: [
                  IconButton(
                    icon: const Icon(Icons.info_outline),
                    onPressed: () => _showConnectionInfo(currentSession),
                    tooltip: 'Connection info',
                  ),
                  IconButton(
                    icon: const Icon(Icons.add),
                    onPressed: _addSession,
                    tooltip: 'New connection',
                  ),
                ],
                bottom: _sessions.length > 1
                    ? TabBar(
                        controller: _tabController,
                        isScrollable: true,
                        tabs: List.generate(_sessions.length, (i) {
                          final session = _sessions[i];
                          return Tab(
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(session.username),
                                const SizedBox(width: 4),
                                GestureDetector(
                                  onTap: () => _closeSession(i),
                                  child: const Icon(Icons.close, size: 16),
                                ),
                              ],
                            ),
                          );
                        }),
                      )
                    : null,
              ),
        body: TabBarView(
          controller: _tabController,
          children: List.generate(_sessions.length, (i) {
            final session = _sessions[i];
            return TerminalTab(
              key: _tabKeys[session.port],
              session: session,
              onDisconnected: () => _closeSession(i),
              connectOnInit: widget.connectOnInit,
              fontSize: _terminalFontSize,
              themeName: _terminalTheme,
            );
          }),
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
    _fetch();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _fetch());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _fetch() async {
    try {
      final info = await connectionInfo(port: widget.session.port);
      if (mounted) setState(() { _irohInfo = info; _irohError = null; });
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
          _infoRow('Target', session.displayName),
          _infoRow('Username', session.username),
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
          Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
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
