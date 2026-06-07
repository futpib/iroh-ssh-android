import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iroh_ssh_app/models/connection_type.dart';
import 'package:iroh_ssh_app/models/fs_entry.dart';
import 'package:iroh_ssh_app/models/ssh_session_info.dart';
import 'package:iroh_ssh_app/models/tab_kind.dart';
import 'package:iroh_ssh_app/screens/sessions_screen.dart';
import 'package:iroh_ssh_app/services/fs/remote_fs.dart';
import 'package:iroh_ssh_app/services/media_store.dart';
import 'package:iroh_ssh_app/widgets/file_manager_tab.dart';
import 'package:path/path.dart' as p;

/// In-memory [RemoteFs] for driving the widget without a real connection.
class FakeRemoteFs implements RemoteFs {
  final String initial;
  FakeRemoteFs({this.initial = '/home/user/sub'});

  @override
  Future<String> initialDir() async => initial;

  @override
  Future<List<FsEntry>> list(String path) async => <FsEntry>[]; // growable (sorted in place)

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
  Stream<int> download(String remotePath, String localPath) async* {}
  @override
  Stream<int> upload(String localPath, String remotePath) async* {}
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

/// Pump frames until [cond] holds (navigation runs via Futures that
/// pumpAndSettle doesn't wait for) or a timeout elapses.
Future<void> _pumpUntil(WidgetTester tester, bool Function() cond) async {
  for (var i = 0; i < 50; i++) {
    if (cond()) return;
    await tester.pump(const Duration(milliseconds: 10));
  }
}

void main() {
  // Issue 2: the Android system back button navigates up one directory and
  // stops being consumed at the filesystem root.
  testWidgets('system back navigates up, then releases at root',
      (tester) async {
    final key = GlobalKey<FileManagerTabState>();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: FileManagerTab(
          key: key,
          session: _session,
          onDisconnected: () {},
          connectOnInit: false,
          testFs: FakeRemoteFs(initial: '/home/user/sub'),
        ),
      ),
    ));
    final state = key.currentState!;
    await _pumpUntil(tester, () => state.cwd == '/home/user/sub');

    expect(state.cwd, '/home/user/sub');
    expect(state.handleBack(), isTrue);
    await _pumpUntil(tester, () => state.cwd == '/home/user');
    expect(state.cwd, '/home/user');
    expect(state.handleBack(), isTrue);
    await _pumpUntil(tester, () => state.cwd == '/home');
    expect(state.cwd, '/home');
    expect(state.handleBack(), isTrue);
    await _pumpUntil(tester, () => state.cwd == '/');
    expect(state.cwd, '/');
    // At the root there's nowhere to go up — back is released to the host.
    expect(state.handleBack(), isFalse);
  });

  // Regression: cancelling the "New folder" dialog must not crash
  // (InheritedElement.debugDeactivated: _dependents.isEmpty).
  testWidgets('cancelling the new-folder dialog does not crash',
      (tester) async {
    final key = GlobalKey<FileManagerTabState>();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: FileManagerTab(
          key: key,
          session: _session,
          onDisconnected: () {},
          connectOnInit: false,
          testFs: FakeRemoteFs(initial: '/home/user'),
        ),
      ),
    ));
    await _pumpUntil(tester, () => key.currentState!.cwd == '/home/user');
    await tester.pump();

    final btn = find.widgetWithIcon(IconButton, Icons.create_new_folder_outlined);
    expect(btn, findsOneWidget);
    await tester.tap(btn);
    await tester.pumpAndSettle();
    expect(find.text('Cancel'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(AlertDialog), findsNothing);
  });

  // Regression: the Android system back button must navigate the file tab UP a
  // directory through SessionsScreen's PopScope wiring (not just handleBack in
  // isolation), instead of exiting the session.
  testWidgets('system back navigates file tab up via SessionsScreen',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: SessionsScreen(
        existingSessions: const [
          SshSessionInfo(
            sessionId: 's',
            host: 'h',
            port: 22,
            username: 'u',
            displayName: 'Local',
            connectionType: ConnectionType.local,
            kind: TabKind.files,
          ),
        ],
        connectOnInit: false,
        testFs: FakeRemoteFs(initial: '/home/user/sub'),
      ),
    ));
    await _pumpUntil(
        tester, () => find.text('/home/user/sub').evaluate().isNotEmpty);
    expect(find.text('/home/user/sub'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(find.text('/home/user'), findsOneWidget,
        reason: 'system back should navigate up a directory');
    expect(find.text('Disconnect all?'), findsNothing);
  });

  // Issue 3: the file-explorer toolbar renders below the system status bar so
  // its controls are tappable (regression for it hiding under the status bar).
  testWidgets('toolbar sits below the system status bar inset',
      (tester) async {
    const statusBar = 48.0;
    await tester.pumpWidget(MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(padding: EdgeInsets.only(top: statusBar)),
        child: FileManagerTab(
          session: _session,
          onDisconnected: () {},
          connectOnInit: false,
        ),
      ),
    ));
    await tester.pump();

    final upButton = find.byTooltip('Up');
    expect(upButton, findsOneWidget);
    expect(tester.getTopLeft(upButton).dy, greaterThanOrEqualTo(statusBar));
  });

  // Issue 1: downloading routes through the MediaStore platform channel (so the
  // file lands in the device's public Downloads, not a hidden app dir).
  test('MediaStore.saveToDownloads calls the platform channel', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    const channel = MethodChannel('iroh_ssh/mediastore');
    final calls = <MethodCall>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return {
        'uri': 'content://media/external/downloads/42',
        'displayPath': 'Downloads/${(call.arguments as Map)['displayName']}',
      };
    });

    final result = await MediaStore.saveToDownloads(
      sourcePath: '/cache/app-debug.apk',
      displayName: 'app-debug.apk',
      mimeType: 'application/vnd.android.package-archive',
    );

    expect(result, isNotNull);
    expect(result!.displayPath, 'Downloads/app-debug.apk');
    expect(result.uri, 'content://media/external/downloads/42');
    expect(calls, hasLength(1));
    expect(calls.single.method, 'saveToDownloads');
    final args = calls.single.arguments as Map;
    expect(args['sourcePath'], '/cache/app-debug.apk');
    expect(args['displayName'], 'app-debug.apk');
    expect(args['mimeType'], 'application/vnd.android.package-archive');

    messenger.setMockMethodCallHandler(channel, null);
  });
}
