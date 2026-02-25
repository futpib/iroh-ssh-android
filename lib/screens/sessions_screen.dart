import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:iroh_ssh_app/models/ssh_session_info.dart';
import 'package:iroh_ssh_app/screens/connect_screen.dart';
import 'package:iroh_ssh_app/widgets/terminal_tab.dart';

class SessionsScreen extends StatefulWidget {
  final SshSessionInfo initialSession;

  const SessionsScreen({
    super.key,
    required this.initialSession,
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

  @override
  void initState() {
    super.initState();
    _sessions = [widget.initialSession];
    _tabController = TabController(length: 1, vsync: this);
    _tabController.addListener(_onTabChanged);
    _tabKeys[widget.initialSession.port] = GlobalKey<TerminalTabState>();
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
      child: Scaffold(
        resizeToAvoidBottomInset: false,
        appBar: AppBar(
          title: Text(currentSession.displayName),
          actions: [
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
            );
          }),
        ),
      ),
    );

    if (_isAndroid) {
      return WithForegroundTask(child: scaffold);
    }
    return scaffold;
  }
}
