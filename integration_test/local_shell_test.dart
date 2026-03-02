import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:iroh_ssh_app/models/connection_type.dart';
import 'package:iroh_ssh_app/models/ssh_session_info.dart';
import 'package:iroh_ssh_app/screens/sessions_screen.dart';
import 'package:iroh_ssh_app/services/settings_storage.dart';
import 'package:iroh_ssh_app/src/rust/frb_generated.dart';
import 'package:iroh_ssh_app/widgets/terminal_tab.dart';
import 'package:xterm/xterm.dart';

String _terminalText(WidgetTester tester) {
  final terminal =
      tester.widget<TerminalView>(find.byType(TerminalView)).terminal;
  final buffer = terminal.buffer;
  final lines = <String>[];
  for (var i = 0; i < buffer.lines.length; i++) {
    lines.add(buffer.lines[i].toString().trimRight());
  }
  return lines.join('\n');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async => await RustLib.init());

  testWidgets('local shell session: start, type, and receive output',
      (tester) async {
    final tabKey = GlobalKey<TerminalTabState>();

    final session = SshSessionInfo(
      sessionId: 'local_test',
      host: 'localhost',
      port: 0,
      username: '',
      displayName: 'Local',
      connectionType: ConnectionType.local,
    );

    SettingsStorage.instance.cache = AppSettings();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TerminalTab(
            key: tabKey,
            session: session,
            onDisconnected: () {},
            connectOnInit: true,
          ),
        ),
      ),
    );

    // Wait for the post-frame callback and PTY startup
    await tester.pump();
    await Future.delayed(const Duration(milliseconds: 500));
    await tester.pump();

    expect(tabKey.currentState!.connected, isTrue,
        reason: 'Shell should be connected after startup');

    // Type a command into the terminal
    final terminal =
        tester.widget<TerminalView>(find.byType(TerminalView)).terminal;
    terminal.textInput('echo hello_from_test\r');

    // Wait for PTY to process and respond
    await Future.delayed(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 10));

    final content = _terminalText(tester);
    expect(content, contains('hello_from_test'),
        reason: 'Terminal should contain the echoed text');
  });

  testWidgets('local shell retry restarts shell', (tester) async {
    final tabKey = GlobalKey<TerminalTabState>();

    final session = SshSessionInfo(
      sessionId: 'local_test_retry',
      host: 'localhost',
      port: 0,
      username: '',
      displayName: 'Local',
      connectionType: ConnectionType.local,
    );

    SettingsStorage.instance.cache = AppSettings();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TerminalTab(
            key: tabKey,
            session: session,
            onDisconnected: () {},
            connectOnInit: true,
          ),
        ),
      ),
    );

    await tester.pump();
    await Future.delayed(const Duration(milliseconds: 500));
    await tester.pump();

    expect(tabKey.currentState!.connected, isTrue);

    // Retry (kills old PTY, starts new one)
    await tabKey.currentState!.retry();
    await Future.delayed(const Duration(milliseconds: 500));
    await tester.pump();

    expect(tabKey.currentState!.connected, isTrue,
        reason: 'Shell should be connected after retry');

    // Verify the new shell works
    final terminal =
        tester.widget<TerminalView>(find.byType(TerminalView)).terminal;
    terminal.textInput('echo after_retry\r');

    await Future.delayed(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 10));

    final content = _terminalText(tester);
    expect(content, contains('after_retry'),
        reason: 'Shell should work after retry');
  });

  testWidgets('local shell disconnect calls onDisconnected', (tester) async {
    final tabKey = GlobalKey<TerminalTabState>();
    var disconnectedCalled = false;

    final session = SshSessionInfo(
      sessionId: 'local_test_disconnect',
      host: 'localhost',
      port: 0,
      username: '',
      displayName: 'Local',
      connectionType: ConnectionType.local,
    );

    SettingsStorage.instance.cache = AppSettings();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TerminalTab(
            key: tabKey,
            session: session,
            onDisconnected: () {
              disconnectedCalled = true;
            },
            connectOnInit: true,
          ),
        ),
      ),
    );

    await tester.pump();
    await Future.delayed(const Duration(milliseconds: 500));
    await tester.pump();

    expect(tabKey.currentState!.connected, isTrue);

    // Disconnect — for local shell this should not attempt to call
    // disconnectIroh (which would fail with no iroh connection).
    await tabKey.currentState!.disconnect();
    await tester.pump();

    expect(disconnectedCalled, isTrue,
        reason: 'onDisconnected callback should have been called');
  });

  testWidgets('ZMODEM file receive via lrzsz-sz', (tester) async {
    final tabKey = GlobalKey<TerminalTabState>();

    final session = SshSessionInfo(
      sessionId: 'local_test_zmodem',
      host: 'localhost',
      port: 0,
      username: '',
      displayName: 'Local',
      connectionType: ConnectionType.local,
    );

    SettingsStorage.instance.cache = AppSettings();

    final outputDir = await Directory.systemTemp.createTemp('zmodem_test_');

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TerminalTab(
            key: tabKey,
            session: session,
            onDisconnected: () {},
            connectOnInit: true,
          ),
        ),
      ),
    );

    await tester.pump();
    await Future.delayed(const Duration(milliseconds: 500));
    await tester.pump();

    expect(tabKey.currentState!.connected, isTrue);

    tabKey.currentState!.directoryPickerOverride = () async => outputDir.path;

    final terminal =
        tester.widget<TerminalView>(find.byType(TerminalView)).terminal;

    // Create a test file and send it with sz
    final testContent = 'zmodem_test_content_${DateTime.now().millisecondsSinceEpoch}';
    terminal.textInput('echo "$testContent" > /tmp/zmodem_test_file\r');
    await Future.delayed(const Duration(milliseconds: 500));
    await tester.pump();

    // Use lrzsz-sz (Arch) or sz (Ubuntu/Debian) depending on availability
    final szCommand = File('/usr/bin/lrzsz-sz').existsSync() ? 'lrzsz-sz' : 'sz';
    terminal.textInput('$szCommand /tmp/zmodem_test_file\r');

    // Poll for the output file to appear
    final expectedFile = File('${outputDir.path}/zmodem_test_file');
    var found = false;
    for (var i = 0; i < 40; i++) {
      await Future.delayed(const Duration(milliseconds: 250));
      await tester.pump();
      if (await expectedFile.exists()) {
        found = true;
        break;
      }
    }

    expect(found, isTrue, reason: 'Received file should appear in output directory');
    final receivedContent = await expectedFile.readAsString();
    expect(receivedContent.trim(), equals(testContent),
        reason: 'Received file should contain the correct content');

    // Cleanup
    await outputDir.delete(recursive: true);
    final tmpFile = File('/tmp/zmodem_test_file');
    if (await tmpFile.exists()) {
      await tmpFile.delete();
    }
  });

  testWidgets('local shell in sessions screen shows correct info',
      (tester) async {
    final session = SshSessionInfo(
      sessionId: 'local_test_info',
      host: 'localhost',
      port: 0,
      username: '',
      displayName: 'Local',
      connectionType: ConnectionType.local,
    );

    SettingsStorage.instance.cache = AppSettings();

    await tester.pumpWidget(
      MaterialApp(
        home: SessionsScreen(
          existingSessions: [session],
          connectOnInit: true,
        ),
      ),
    );

    await tester.pump();
    await Future.delayed(const Duration(milliseconds: 500));
    await tester.pump();

    // Open connection info dialog
    await tester.tap(find.byIcon(Icons.info_outline));
    await tester.pumpAndSettle();

    // Should show type and target
    expect(find.text('Connection Info'), findsOneWidget);
    expect(find.text('Local'), findsWidgets);

    // Should NOT show username or iroh-specific fields
    expect(find.text('Username'), findsNothing);
    expect(find.text('Local port'), findsNothing);

    // Close dialog
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
  });
}
