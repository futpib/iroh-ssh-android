import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:iroh_ssh_app/models/connection_type.dart';
import 'package:iroh_ssh_app/models/fs_entry.dart';
import 'package:iroh_ssh_app/models/ssh_session_info.dart';
import 'package:iroh_ssh_app/services/fs/remote_fs.dart';
import 'package:iroh_ssh_app/widgets/file_manager_tab.dart';
import 'package:path/path.dart' as p;

/// On-device checks for the file-manager UI fixes (back navigation + status-bar
/// avoidance), running the real widgets against the real device insets. Uses a
/// fake fs so no connection / RustLib init is needed.
class FakeRemoteFs implements RemoteFs {
  final String initial;
  FakeRemoteFs({this.initial = '/home/user/sub'});
  @override
  Future<String> initialDir() async => initial;
  @override
  Future<List<FsEntry>> list(String path) async => <FsEntry>[];
  @override
  Future<FsEntry> stat(String path, {bool followLink = true}) async => FsEntry(
      name: p.posix.basename(path), path: path, isDir: true, isLink: false);
  @override
  Future<void> mkdir(String path) async {}
  @override
  Future<void> rename(String from, String to) async {}
  @override
  Future<void> remove(String path, {bool recursive = false}) async {}
  @override
  Stream<int> download(String r, String l) async* {}
  @override
  Stream<int> upload(String l, String r) async* {}
  @override
  String join(String dir, String name) => p.posix.join(dir, name);
  @override
  String parentOf(String path) {
    final parent = p.posix.dirname(path);
    return parent.isEmpty ? '/' : parent;
  }

  @override
  Future<void> close() async {}
}

const _session = SshSessionInfo(
  sessionId: 's',
  host: 'h',
  port: 22,
  username: 'u',
  displayName: 'd',
  connectionType: ConnectionType.ssh,
);

Future<void> _pumpUntil(WidgetTester tester, bool Function() cond) async {
  for (var i = 0; i < 50; i++) {
    if (cond()) return;
    await tester.pump(const Duration(milliseconds: 10));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('toolbar clears the real device status-bar inset',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: FileManagerTab(
          session: _session, onDisconnected: () {}, connectOnInit: false),
    ));
    await tester.pump();

    final insetLogical =
        tester.view.padding.top / tester.view.devicePixelRatio;
    final upTop = tester.getTopLeft(find.byTooltip('Up')).dy;
    // ignore: avoid_print
    print('STATUSBAR_INSET=$insetLogical UP_TOP=$upTop');

    // The toolbar must sit at/below the real status-bar inset.
    expect(upTop, greaterThanOrEqualTo(insetLogical - 0.5));
  });

  testWidgets('system back navigates up against the real runtime',
      (tester) async {
    final key = GlobalKey<FileManagerTabState>();
    await tester.pumpWidget(MaterialApp(
      home: FileManagerTab(
        key: key,
        session: _session,
        onDisconnected: () {},
        connectOnInit: false,
        testFs: FakeRemoteFs(initial: '/home/user/sub'),
      ),
    ));
    final state = key.currentState!;
    await _pumpUntil(tester, () => state.cwd == '/home/user/sub');

    expect(state.handleBack(), isTrue);
    await _pumpUntil(tester, () => state.cwd == '/home/user');
    expect(state.cwd, '/home/user');
    expect(state.handleBack(), isTrue);
    await _pumpUntil(tester, () => state.cwd == '/home');
    expect(state.cwd, '/home');
    expect(state.handleBack(), isTrue);
    await _pumpUntil(tester, () => state.cwd == '/');
    expect(state.cwd, '/');
    expect(state.handleBack(), isFalse);
  });
}
