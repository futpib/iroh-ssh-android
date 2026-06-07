import 'package:flutter_test/flutter_test.dart';
import 'package:iroh_ssh_app/models/connection_type.dart';
import 'package:iroh_ssh_app/models/fs_entry.dart';
import 'package:iroh_ssh_app/models/ssh_session_info.dart';
import 'package:iroh_ssh_app/models/tab_kind.dart';
import 'package:iroh_ssh_app/services/session_messages.dart';

void main() {
  group('TabKind', () {
    test('parse defaults to terminal for null/unknown', () {
      expect(TabKind.parse(null), TabKind.terminal);
      expect(TabKind.parse('bogus'), TabKind.terminal);
      expect(TabKind.parse('files'), TabKind.files);
      expect(TabKind.parse('terminal'), TabKind.terminal);
    });
  });

  group('FsEntry json', () {
    test('round-trips with all fields', () {
      const entry = FsEntry(
        name: 'a.txt',
        path: '/home/u/a.txt',
        isDir: false,
        isLink: false,
        size: 123,
        mtime: 1700000000,
        mode: 33188,
      );
      final back = FsEntry.fromJson(entry.toJson());
      expect(back.name, entry.name);
      expect(back.path, entry.path);
      expect(back.isDir, entry.isDir);
      expect(back.isLink, entry.isLink);
      expect(back.size, entry.size);
      expect(back.mtime, entry.mtime);
      expect(back.mode, entry.mode);
    });

    test('round-trips with null optionals', () {
      const entry =
          FsEntry(name: 'dir', path: '/dir', isDir: true, isLink: false);
      final back = FsEntry.fromJson(entry.toJson());
      expect(back.size, isNull);
      expect(back.mtime, isNull);
      expect(back.mode, isNull);
      expect(back.isDir, isTrue);
    });
  });

  group('SshSessionInfo carries kind', () {
    test('defaults to terminal and round-trips files', () {
      const info = SshSessionInfo(
        sessionId: 's',
        host: 'h',
        port: 22,
        username: 'u',
        displayName: 'd',
        kind: TabKind.files,
      );
      final back = SshSessionInfo.fromJson(info.toJson());
      expect(back.kind, TabKind.files);

      final legacy = SshSessionInfo.fromJson({
        'sessionId': 's',
        'host': 'h',
        'port': 22,
        'username': 'u',
        'displayName': 'd',
      });
      expect(legacy.kind, TabKind.terminal);
    });
  });

  group('Connect messages carry kind', () {
    test('ConnectCommand', () {
      final cmd = ConnectCommand(
        connectionType: ConnectionType.ssh,
        kind: TabKind.files,
        username: 'u',
        displayName: 'd',
        keyNames: const [],
        relayUrls: const [],
        extraRelayUrls: const [],
      );
      final decoded = ServiceCommand.decode(cmd.encode()) as ConnectCommand;
      expect(decoded.kind, TabKind.files);
      expect(decoded.connectionType, ConnectionType.ssh);
    });

    test('ConnectedEvent', () {
      final ev = ConnectedEvent(
        sessionId: 's',
        displayName: 'd',
        username: 'u',
        port: 5,
        kind: TabKind.files,
      );
      final decoded = ServiceEvent.decode(ev.encode()) as ConnectedEvent;
      expect(decoded.kind, TabKind.files);
    });

    test('SessionSummary', () {
      final s = SessionSummary(
        sessionId: 's',
        displayName: 'd',
        username: 'u',
        port: 5,
        state: 'connected',
        kind: TabKind.files,
      );
      final back = SessionSummary.fromJson(s.toJson());
      expect(back.kind, TabKind.files);
    });
  });

  group('SFTP commands round-trip via ServiceCommand.decode', () {
    test('list / stat / mkdir / initialDir', () {
      for (final cmd in <ServiceCommand>[
        SftpListCommand(sessionId: 's', requestId: 'r', path: '/x'),
        SftpStatCommand(sessionId: 's', requestId: 'r', path: '/x'),
        SftpMkdirCommand(sessionId: 's', requestId: 'r', path: '/x'),
        SftpInitialDirCommand(sessionId: 's', requestId: 'r'),
      ]) {
        final decoded = ServiceCommand.decode(cmd.encode());
        expect(decoded.runtimeType, cmd.runtimeType);
      }
    });

    test('rename carries from/to', () {
      final cmd =
          SftpRenameCommand(sessionId: 's', requestId: 'r', from: '/a', to: '/b');
      final decoded = ServiceCommand.decode(cmd.encode()) as SftpRenameCommand;
      expect(decoded.from, '/a');
      expect(decoded.to, '/b');
    });

    test('remove carries recursive', () {
      final cmd = SftpRemoveCommand(
          sessionId: 's', requestId: 'r', path: '/x', recursive: true);
      final decoded = ServiceCommand.decode(cmd.encode()) as SftpRemoveCommand;
      expect(decoded.recursive, isTrue);
    });

    test('download / upload carry both paths', () {
      final dl = SftpDownloadCommand(
          sessionId: 's',
          requestId: 'r',
          remotePath: '/r',
          localPath: '/l',
          publishName: 'r.bin');
      final dld = ServiceCommand.decode(dl.encode()) as SftpDownloadCommand;
      expect(dld.remotePath, '/r');
      expect(dld.localPath, '/l');
      expect(dld.publishName, 'r.bin');

      // publishName is optional (desktop downloads don't publish).
      final dl2 = SftpDownloadCommand(
          sessionId: 's', requestId: 'r', remotePath: '/r', localPath: '/l');
      final dld2 = ServiceCommand.decode(dl2.encode()) as SftpDownloadCommand;
      expect(dld2.publishName, isNull);

      final up = SftpUploadCommand(
          sessionId: 's', requestId: 'r', localPath: '/l', remotePath: '/r');
      final upd = ServiceCommand.decode(up.encode()) as SftpUploadCommand;
      expect(upd.localPath, '/l');
      expect(upd.remotePath, '/r');
    });

    test('cancel', () {
      final cmd = SftpCancelCommand(sessionId: 's', requestId: 'r');
      final decoded = ServiceCommand.decode(cmd.encode()) as SftpCancelCommand;
      expect(decoded.requestId, 'r');
    });
  });

  group('SFTP events round-trip via ServiceEvent.decode', () {
    test('list result with entries', () {
      final ev = SftpListResultEvent(
        sessionId: 's',
        requestId: 'r',
        entries: const [
          FsEntry(name: 'a', path: '/a', isDir: true, isLink: false),
          FsEntry(name: 'b', path: '/b', isDir: false, isLink: false, size: 9),
        ],
      );
      final decoded = ServiceEvent.decode(ev.encode()) as SftpListResultEvent;
      expect(decoded.entries.length, 2);
      expect(decoded.entries.first.name, 'a');
      expect(decoded.entries.first.isDir, isTrue);
      expect(decoded.entries[1].size, 9);
    });

    test('path result', () {
      final ev =
          SftpPathResultEvent(sessionId: 's', requestId: 'r', path: '/home/u');
      final decoded = ServiceEvent.decode(ev.encode()) as SftpPathResultEvent;
      expect(decoded.path, '/home/u');
    });

    test('progress with and without total', () {
      final withTotal = ServiceEvent.decode(
              SftpProgressEvent(
                      sessionId: 's',
                      requestId: 'r',
                      transferred: 100,
                      total: 200)
                  .encode())
          as SftpProgressEvent;
      expect(withTotal.transferred, 100);
      expect(withTotal.total, 200);

      final noTotal = ServiceEvent.decode(
              SftpProgressEvent(sessionId: 's', requestId: 'r', transferred: 50)
                  .encode())
          as SftpProgressEvent;
      expect(noTotal.total, isNull);
    });

    test('ok / done / error', () {
      expect(
          ServiceEvent.decode(
                  SftpOkEvent(sessionId: 's', requestId: 'r').encode())
              .runtimeType,
          SftpOkEvent);
      expect(
          ServiceEvent.decode(
                  SftpDoneEvent(sessionId: 's', requestId: 'r').encode())
              .runtimeType,
          SftpDoneEvent);
      final err = ServiceEvent.decode(
              SftpErrorEvent(sessionId: 's', requestId: 'r', message: 'nope')
                  .encode())
          as SftpErrorEvent;
      expect(err.message, 'nope');
    });
  });
}
