import 'package:flutter_test/flutter_test.dart';
import 'package:iroh_ssh_app/models/fs_entry.dart';
import 'package:iroh_ssh_app/services/fs/ipc_remote_fs.dart';
import 'package:iroh_ssh_app/services/session_messages.dart';

void main() {
  // The first requestId minted by IpcRemoteFs is "<sessionId>_0".
  const rid = 's_0';

  test('list correlates the response by requestId', () async {
    final fs = IpcRemoteFs(sessionId: 's', send: (_) {});
    final future = fs.list('/dir');
    fs.handleEvent(SftpListResultEvent(
      sessionId: 's',
      requestId: rid,
      entries: const [FsEntry(name: 'a', path: '/dir/a', isDir: false, isLink: false)],
    ));
    final entries = await future;
    expect(entries, hasLength(1));
    expect(entries.single.name, 'a');
  });

  test('an SFTP error fails the matching request', () async {
    final fs = IpcRemoteFs(sessionId: 's', send: (_) {});
    final future = fs.mkdir('/dir/new');
    fs.handleEvent(
        SftpErrorEvent(sessionId: 's', requestId: rid, message: 'denied'));
    await expectLater(future, throwsA(isA<RemoteFsException>()));
  });

  test('startDownload fires a download command with the publish name', () {
    final sent = <ServiceCommand>[];
    final fs = IpcRemoteFs(
        sessionId: 's', send: (raw) => sent.add(ServiceCommand.decode(raw)));

    fs.startDownload('/remote/file.bin', '/tmp/file.bin', publishName: 'file.bin');

    final cmd = sent.single as SftpDownloadCommand;
    expect(cmd.remotePath, '/remote/file.bin');
    expect(cmd.localPath, '/tmp/file.bin');
    expect(cmd.publishName, 'file.bin');
  });

  test('startUpload fires an upload command', () {
    final sent = <ServiceCommand>[];
    final fs = IpcRemoteFs(
        sessionId: 's', send: (raw) => sent.add(ServiceCommand.decode(raw)));

    fs.startUpload('/tmp/local.bin', '/remote/local.bin');

    final cmd = sent.single as SftpUploadCommand;
    expect(cmd.localPath, '/tmp/local.bin');
    expect(cmd.remotePath, '/remote/local.bin');
  });

  test('the streaming transfer API is unsupported in IPC mode', () {
    final fs = IpcRemoteFs(sessionId: 's', send: (_) {});
    expect(() => fs.download('/r', '/l'), throwsUnsupportedError);
    expect(() => fs.upload('/l', '/r'), throwsUnsupportedError);
  });
}
