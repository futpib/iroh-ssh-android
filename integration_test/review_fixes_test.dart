import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:iroh_ssh_app/main.dart' as app;
import 'package:iroh_ssh_app/models/connection_type.dart';
import 'package:iroh_ssh_app/models/ssh_session_info.dart';
import 'package:iroh_ssh_app/models/tab_kind.dart';
import 'package:iroh_ssh_app/screens/sessions_screen.dart';
import 'package:iroh_ssh_app/services/known_hosts.dart';
import 'package:iroh_ssh_app/services/session_messages.dart';
import 'package:iroh_ssh_app/widgets/file_manager_tab.dart';
import 'package:iroh_ssh_app/widgets/host_key_dialog.dart';
import 'package:path/path.dart' as p;

Future<void> pumpUntil(WidgetTester tester, bool Function() condition) async {
  for (var i = 0; i < 200 && !condition(); i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(condition(), isTrue, reason: 'device workflow timed out');
}

Future<T> commandResult<T extends ServiceEvent>(
  ServiceCommand command,
  bool Function(T) matches,
) async {
  final result = Completer<T>();
  void onData(Object raw) {
    if (raw is! String) return;
    final event = ServiceEvent.decode(raw);
    if (event is T && matches(event) && !result.isCompleted) {
      result.complete(event);
    }
  }

  FlutterForegroundTask.addTaskDataCallback(onData);
  try {
    FlutterForegroundTask.sendDataToTask(command.encode());
    return await result.future.timeout(const Duration(seconds: 10));
  } finally {
    FlutterForegroundTask.removeTaskDataCallback(onData);
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'Android service confines local files and disconnects only the named tab',
    (tester) async {
      addTearDown(() async {
        await FlutterForegroundTask.stopService();
      });
      await app.main();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Local'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Files'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open Files'));
      await pumpUntil(
        tester,
        () =>
            find.byType(FileManagerTab).evaluate().isNotEmpty &&
            tester
                .state<FileManagerTabState>(find.byType(FileManagerTab))
                .cwd
                .isNotEmpty,
      );
      final tab = tester.widget<FileManagerTab>(find.byType(FileManagerTab));
      final state = tester.state<FileManagerTabState>(
        find.byType(FileManagerTab),
      );
      final root = state.cwd;
      expect(p.basename(root), 'files');
      expect(state.handleBack(), isFalse);
      expect(
        tester
            .widget<IconButton>(
              find.widgetWithIcon(IconButton, Icons.arrow_upward),
            )
            .onPressed,
        isNull,
      );
      final denied = await commandResult<SftpErrorEvent>(
        SftpListCommand(
          sessionId: tab.session.sessionId,
          requestId: 'escape-probe',
          path: p.dirname(root),
        ),
        (event) => event.requestId == 'escape-probe',
      );
      expect(denied.message, contains('outside local files'));

      // Actual foreground-service transfer: same intended destination/name, two
      // source files. The service must stage independently and publish both.
      final stamp = DateTime.now().microsecondsSinceEpoch;
      final first = await File(
        p.join(root, 'first-$stamp.txt'),
      ).writeAsString('first');
      final second = await File(
        p.join(root, 'second-$stamp.txt'),
      ).writeAsString('second');
      final done = await Future.wait([
        commandResult<SftpDoneEvent>(
          SftpDownloadCommand(
            sessionId: tab.session.sessionId,
            requestId: 'first-download',
            remotePath: first.path,
            localPath: '',
            publishName: 'iroh-review-$stamp.txt',
          ),
          (event) => event.requestId == 'first-download',
        ),
        commandResult<SftpDoneEvent>(
          SftpDownloadCommand(
            sessionId: tab.session.sessionId,
            requestId: 'second-download',
            remotePath: second.path,
            localPath: '',
            publishName: 'iroh-review-$stamp.txt',
          ),
          (event) => event.requestId == 'second-download',
        ),
      ]);
      expect(done, hasLength(2));
      await first.delete();
      await second.delete();

      final connected = await commandResult<ConnectedEvent>(
        ConnectCommand(
          connectionType: ConnectionType.local,
          kind: TabKind.files,
          username: '',
          displayName: 'second-local',
          keyNames: [],
          relayUrls: [],
          extraRelayUrls: [],
        ),
        (_) => true,
      );
      final secondSession = SshSessionInfo(
        sessionId: connected.sessionId,
        host: '',
        port: 0,
        username: '',
        displayName: connected.displayName,
        connectionType: ConnectionType.local,
        kind: TabKind.files,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: SessionsScreen(existingSessions: [tab.session, secondSession]),
        ),
      );
      await tester.pumpAndSettle();
      FlutterForegroundTask.sendDataToTask(
        DisconnectCommand(sessionId: tab.session.sessionId).encode(),
      );
      await pumpUntil(
        tester,
        () =>
            tester
                .widget<TabBarView>(find.byType(TabBarView))
                .children
                .length ==
            1,
      );
      final sessions = await commandResult<SessionListEvent>(
        ListSessionsCommand(),
        (_) => true,
      );
      expect(sessions.sessions.map((s) => s.sessionId), [
        secondSession.sessionId,
      ]);
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      FlutterForegroundTask.sendDataToTask(
        DisconnectCommand(sessionId: secondSession.sessionId).encode(),
      );
      await FlutterForegroundTask.stopService();
    },
  );

  testWidgets(
    'host-key warning fits the Android screen and requires explicit trust',
    (tester) async {
      bool? trusted;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                trusted = await confirmHostKey(
                  context,
                  const HostKeyChallenge(
                    host: 'test.example',
                    port: 2222,
                    keyType: 'ssh-ed25519',
                    fingerprint: 'SHA256:new',
                    previousFingerprint: 'SHA256:old',
                  ),
                );
              },
              child: const Text('Connect'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Connect'));
      await tester.pumpAndSettle();
      expect(trusted, isNull);
      expect(find.text('SSH host key changed'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(trusted, isFalse);
    },
  );
}
