import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iroh_ssh_app/models/connection_type.dart';
import 'package:iroh_ssh_app/models/ssh_session_info.dart';
import 'package:iroh_ssh_app/models/tab_kind.dart';
import 'package:iroh_ssh_app/services/background_session.dart';
import 'package:iroh_ssh_app/services/download_storage.dart';
import 'package:iroh_ssh_app/services/fs/ipc_remote_fs.dart';
import 'package:iroh_ssh_app/services/fs/local_fs.dart';
import 'package:iroh_ssh_app/services/session_messages.dart';
import 'package:iroh_ssh_app/services/transfer_notifications.dart';
import 'package:iroh_ssh_app/widgets/file_manager_tab.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'Android IPC Back stops at the service-provided local files root',
    (tester) async {
      const root = '/data/user/0/com.github.futpib.iroh_ssh_app/files';
      final paths = <String>[];
      late IpcRemoteFs fs;
      fs = IpcRemoteFs(
        sessionId: 'local',
        send: (raw) {
          final command = ServiceCommand.decode(raw);
          if (command is SftpInitialDirCommand) {
            fs.handleEvent(
              SftpPathResultEvent(
                sessionId: 'local',
                requestId: command.requestId,
                path: root,
                navigationRoot: root,
              ),
            );
          } else if (command is SftpListCommand) {
            paths.add(command.path);
            fs.handleEvent(
              SftpListResultEvent(
                sessionId: 'local',
                requestId: command.requestId,
                entries: [],
              ),
            );
          }
        },
      );
      final key = GlobalKey<FileManagerTabState>();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FileManagerTab(
              key: key,
              session: const SshSessionInfo(
                sessionId: 'local',
                host: '',
                port: 0,
                username: '',
                displayName: 'Local',
                connectionType: ConnectionType.local,
                kind: TabKind.files,
              ),
              onDisconnected: () {},
              connectOnInit: false,
              testFs: fs,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(key.currentState!.cwd, root);
      expect(key.currentState!.handleBack(), isFalse);
      await tester.pumpAndSettle();
      expect(key.currentState!.cwd, root);
      expect(paths, [root]);
    },
  );

  for (final throws in [false, true]) {
    test(
      'MediaStore ${throws ? 'failure preserves bytes and reports failure' : 'unsupported keeps an accessible local copy'}',
      () async {
        final temp = await Directory.systemTemp.createTemp('iroh-review-');
        addTearDown(() => temp.delete(recursive: true));
        final source = File('${temp.path}/source.txt');
        final downloaded = File('${temp.path}/download.txt');
        await source.writeAsString('irreplaceable download');
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        const media = MethodChannel('iroh_ssh/mediastore');
        const notification = MethodChannel('iroh_ssh/transfer');
        final notices = <Map<dynamic, dynamic>>[];
        String? stagedPath;
        messenger.setMockMethodCallHandler(media, (call) async {
          stagedPath = (call.arguments as Map)['sourcePath'] as String;
          if (throws) {
            throw PlatformException(code: 'SAVE_FAILED', message: 'disk full');
          }
          return null;
        });
        messenger.setMockMethodCallHandler(notification, (call) async {
          if (call.method == 'show') notices.add(call.arguments as Map);
          return null;
        });
        addTearDown(() {
          messenger.setMockMethodCallHandler(media, null);
          messenger.setMockMethodCallHandler(notification, null);
        });
        final done = Completer<void>();
        final events = <ServiceEvent>[];
        final session = BackgroundSession(
          downloadStorage: DownloadStorage(baseDirectory: () async => temp),
          sessionId: 'local',
          displayName: 'Local',
          username: '',
          port: 0,
          identities: [],
          connectionType: ConnectionType.local,
          kind: TabKind.files,
        );
        session.debugAttachFs(LocalFs());
        session.notifications = TransferNotifications();
        session.onSendToUi = (raw) {
          final event = ServiceEvent.decode(raw);
          events.add(event);
          if (event is SftpDoneEvent || event is SftpErrorEvent) {
            done.complete();
          }
        };
        await session.handleSftp(
          SftpDownloadCommand(
            sessionId: 'local',
            requestId: 'download',
            remotePath: source.path,
            localPath: downloaded.path,
            publishName: 'download.txt',
          ),
        );
        await done.future.timeout(const Duration(seconds: 5));
        expect(
          notices.last['text'],
          contains(
            throws
                ? 'Could not save to Downloads'
                : 'public Downloads unavailable',
          ),
        );
        expect(notices.last['text'], contains('Local files/downloads/'));
        expect(
          events.whereType<SftpDoneEvent>(),
          throws ? isEmpty : hasLength(1),
        );
        expect(
          events.whereType<SftpErrorEvent>(),
          throws ? hasLength(1) : isEmpty,
        );
        expect(notices.last['openUri'], isNull);
        expect(
          await File(stagedPath!).readAsString(),
          'irreplaceable download',
        );
        expect(await downloaded.exists(), isFalse);
      },
    );
  }

  test(
    'same-name downloads publish their own bytes and clean up independently',
    () async {
      final temp = await Directory.systemTemp.createTemp('iroh-collision-');
      addTearDown(() => temp.delete(recursive: true));
      final first = await File(
        '${temp.path}/first',
      ).writeAsString('first server');
      final second = await File(
        '${temp.path}/second',
      ).writeAsString('second server');
      final shared = '${temp.path}/report.txt';
      final entered = [Completer<void>(), Completer<void>()];
      final release = [Completer<void>(), Completer<void>()];
      final done = [Completer<void>(), Completer<void>()];
      final published = <String>[];
      final stagedPaths = <String>[];
      var publishIndex = 0;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const media = MethodChannel('iroh_ssh/mediastore');
      messenger.setMockMethodCallHandler(media, (call) async {
        final index = publishIndex++;
        stagedPaths.add((call.arguments as Map)['sourcePath'] as String);
        entered[index].complete();
        await release[index].future;
        final source = File((call.arguments as Map)['sourcePath'] as String);
        if (!await source.exists()) {
          throw PlatformException(code: 'SAVE_FAILED');
        }
        published.add(await source.readAsString());
        return {
          'uri': 'content://downloads/$index',
          'displayPath': 'Downloads/report.txt',
        };
      });
      addTearDown(() => messenger.setMockMethodCallHandler(media, null));
      final session = BackgroundSession(
        downloadStorage: DownloadStorage(baseDirectory: () async => temp),
        sessionId: 's',
        displayName: 'Local',
        username: '',
        port: 0,
        identities: [],
        connectionType: ConnectionType.local,
        kind: TabKind.files,
      );
      session.debugAttachFs(LocalFs());
      session.onSendToUi = (raw) {
        final event = ServiceEvent.decode(raw);
        if (event is SftpDoneEvent) done[int.parse(event.requestId)].complete();
      };
      await session.handleSftp(
        SftpDownloadCommand(
          sessionId: 's',
          requestId: '0',
          remotePath: first.path,
          localPath: shared,
          publishName: 'report.txt',
        ),
      );
      await entered[0].future.timeout(const Duration(seconds: 5));
      await session.handleSftp(
        SftpDownloadCommand(
          sessionId: 's',
          requestId: '1',
          remotePath: second.path,
          localPath: shared,
          publishName: 'report.txt',
        ),
      );
      await entered[1].future.timeout(const Duration(seconds: 5));
      expect(stagedPaths.toSet(), hasLength(2));
      release[0].complete();
      await done[0].future.timeout(const Duration(seconds: 5));
      expect(await File(stagedPaths[1]).readAsString(), 'second server');
      release[1].complete();
      await done[1].future.timeout(const Duration(seconds: 5));
      expect(published, ['first server', 'second server']);
      for (final path in stagedPaths) {
        expect(await File(path).parent.exists(), isFalse);
      }
      expect(await File(shared).exists(), isFalse);
    },
  );
}
