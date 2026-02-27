import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:iroh_ssh_app/models/ssh_session_info.dart';
import 'package:iroh_ssh_app/services/session_messages.dart';
import 'package:iroh_ssh_app/src/rust/frb_generated.dart';
import 'package:iroh_ssh_app/screens/connect_screen.dart';
import 'package:iroh_ssh_app/screens/sessions_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();

  if (Platform.isAndroid) {
    FlutterForegroundTask.initCommunicationPort();
  }

  runApp(const IrohSshApp());
}

class IrohSshApp extends StatefulWidget {
  const IrohSshApp({super.key});

  @override
  State<IrohSshApp> createState() => _IrohSshAppState();
}

class _IrohSshAppState extends State<IrohSshApp> {
  final _navigatorKey = GlobalKey<NavigatorState>();
  List<SshSessionInfo>? _existingSessions;
  bool _checked = false;

  @override
  void initState() {
    super.initState();
    if (Platform.isAndroid) {
      _checkExistingService();
    } else {
      _checked = true;
    }
  }

  Future<void> _checkExistingService() async {
    final running = await FlutterForegroundTask.isRunningService;
    if (running) {
      // Request session list from the running service
      final completer = Completer<List<SshSessionInfo>>();

      void onData(Object data) {
        if (data is! String) return;
        try {
          final event = ServiceEvent.decode(data);
          if (event is SessionListEvent) {
            FlutterForegroundTask.removeTaskDataCallback(onData);
            final sessions = event.sessions
                .map((s) => SshSessionInfo(
                      sessionId: s.sessionId,
                      host: 'localhost',
                      port: s.port,
                      username: s.username,
                      displayName: s.displayName,
                    ))
                .toList();
            if (!completer.isCompleted) {
              completer.complete(sessions);
            }
          }
        } catch (_) {}
      }

      FlutterForegroundTask.addTaskDataCallback(onData);
      FlutterForegroundTask.sendDataToTask(
        ListSessionsCommand().encode(),
      );

      // Wait up to 2 seconds for a response
      final sessions = await completer.future
          .timeout(const Duration(seconds: 2), onTimeout: () => []);

      if (sessions.isNotEmpty && mounted) {
        setState(() {
          _existingSessions = sessions;
          _checked = true;
        });
        return;
      }
    }
    if (mounted) {
      setState(() => _checked = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_checked) {
      return MaterialApp(
        title: 'iroh-ssh',
        theme: ThemeData(
          colorSchemeSeed: Colors.deepPurple,
          useMaterial3: true,
          brightness: Brightness.dark,
        ),
        home: const Scaffold(
          body: Center(child: CircularProgressIndicator()),
        ),
      );
    }

    return MaterialApp(
      navigatorKey: _navigatorKey,
      title: 'iroh-ssh',
      theme: ThemeData(
        colorSchemeSeed: Colors.deepPurple,
        useMaterial3: true,
        brightness: Brightness.dark,
      ),
      home: _existingSessions != null && _existingSessions!.isNotEmpty
          ? SessionsScreen(existingSessions: _existingSessions!)
          : const ConnectScreen(),
    );
  }
}
