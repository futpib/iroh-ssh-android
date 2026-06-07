import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iroh_ssh_app/models/connection_type.dart';
import 'package:iroh_ssh_app/models/fs_entry.dart';
import 'package:iroh_ssh_app/models/tab_kind.dart';
import 'package:iroh_ssh_app/services/background_session.dart';
import 'package:iroh_ssh_app/services/fs/remote_fs.dart';
import 'package:iroh_ssh_app/services/session_messages.dart';
import 'package:iroh_ssh_app/services/transfer_notifications.dart';

/// Fake [RemoteFs] whose download/upload are driven by controllers the test
/// owns, so the service's transfer orchestration can be exercised step by step.
class _FakeFs implements RemoteFs {
  final downloadController = StreamController<int>();
  final uploadController = StreamController<int>();
  bool downloadCancelled = false;

  _FakeFs() {
    downloadController.onCancel = () => downloadCancelled = true;
  }

  @override
  Stream<int> download(String remotePath, String localPath) =>
      downloadController.stream;
  @override
  Stream<int> upload(String localPath, String remotePath) =>
      uploadController.stream;

  @override
  Future<FsEntry> stat(String path, {bool followLink = true}) async =>
      FsEntry(name: 'x', path: path, isDir: false, isLink: false, size: 1000);

  @override
  Future<List<FsEntry>> list(String path) async => const [];
  @override
  Future<String> initialDir() async => '/';
  @override
  Future<void> mkdir(String path) async {}
  @override
  Future<void> rename(String from, String to) async {}
  @override
  Future<void> remove(String path, {bool recursive = false}) async {}
  @override
  String join(String dir, String name) => '$dir/$name';
  @override
  String parentOf(String path) => path;
  @override
  Future<void> close() async {}
}

/// Flush pending microtasks/awaits.
Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 10));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const transferChannel = MethodChannel('iroh_ssh/transfer');
  const mediaChannel = MethodChannel('iroh_ssh/mediastore');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late List<MethodCall> transferCalls;
  late List<MethodCall> mediaCalls;
  late List<ServiceEvent> events;
  late _FakeFs fs;
  late BackgroundSession session;

  setUp(() {
    transferCalls = [];
    mediaCalls = [];
    events = [];
    messenger.setMockMethodCallHandler(transferChannel, (call) async {
      transferCalls.add(call);
      return null;
    });
    messenger.setMockMethodCallHandler(mediaChannel, (call) async {
      mediaCalls.add(call);
      return 'Downloads/${(call.arguments as Map)['displayName']}';
    });

    fs = _FakeFs();
    session = BackgroundSession(
      sessionId: 's',
      displayName: 'd',
      username: 'u',
      port: 0,
      identities: const [],
      connectionType: ConnectionType.local,
      kind: TabKind.files,
    );
    session.onSendToUi = (raw) => events.add(ServiceEvent.decode(raw));
    session.notifications = TransferNotifications();
    session.debugAttachFs(fs);
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(transferChannel, null);
    messenger.setMockMethodCallHandler(mediaChannel, null);
  });

  List<MethodCall> shows() =>
      transferCalls.where((c) => c.method == 'show').toList();

  test('download shows progress, publishes to Downloads, emits done', () async {
    await session.handleSftp(SftpDownloadCommand(
      sessionId: 's',
      requestId: 'r1',
      remotePath: '/remote/photo.jpg',
      localPath: '/cache/photo.jpg',
      publishName: 'photo.jpg',
    ));
    await _settle(); // _resolveTotal stat

    fs.downloadController.add(500);
    await _settle();
    await fs.downloadController.close();
    await _settle();

    // Published to public Downloads via MediaStore, off the UI isolate.
    expect(mediaCalls, hasLength(1));
    final args = mediaCalls.single.arguments as Map;
    expect(args['sourcePath'], '/cache/photo.jpg');
    expect(args['displayName'], 'photo.jpg');

    // The notification was shown and ends in a "Saved" state.
    expect(shows(), isNotEmpty);
    expect((shows().last.arguments as Map)['text'],
        contains('Saved to Downloads/photo.jpg'));
    expect((shows().last.arguments as Map)['ongoing'], isFalse);

    // The UI is told to refresh.
    expect(events.whereType<SftpDoneEvent>(), hasLength(1));
  });

  test('cancel aborts the download, clears its notification, no done', () async {
    await session.handleSftp(SftpDownloadCommand(
      sessionId: 's',
      requestId: 'r2',
      remotePath: '/remote/big.bin',
      localPath: '/cache/big.bin',
      publishName: 'big.bin',
    ));
    await _settle();
    fs.downloadController.add(1000);
    await _settle();

    expect(session.hasTransfer('r2'), isTrue);
    await session.cancelTransfer('r2');
    await _settle();

    expect(fs.downloadCancelled, isTrue); // underlying stream aborted
    expect(session.hasTransfer('r2'), isFalse);
    // Its notification was removed and nothing was published.
    expect(
        transferCalls.where((c) =>
            c.method == 'cancel' &&
            (c.arguments as Map)['requestId'] == 'r2'),
        hasLength(1));
    expect(mediaCalls, isEmpty);
    expect(events.whereType<SftpDoneEvent>(), isEmpty);
  });

  test('upload finishes without publishing, emits done', () async {
    await session.handleSftp(SftpUploadCommand(
      sessionId: 's',
      requestId: 'r3',
      localPath: '/cache/note.txt',
      remotePath: '/remote/note.txt',
    ));
    await _settle();
    fs.uploadController.add(10);
    await _settle();
    await fs.uploadController.close();
    await _settle();

    expect(mediaCalls, isEmpty); // uploads don't touch Downloads
    expect((shows().last.arguments as Map)['text'], 'Uploaded');
    expect(events.whereType<SftpDoneEvent>(), hasLength(1));
  });
}
