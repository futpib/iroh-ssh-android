import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iroh_ssh_app/models/ssh_session_info.dart';
import 'package:iroh_ssh_app/screens/sessions_screen.dart';
import 'package:iroh_ssh_app/services/settings_storage.dart';
import 'package:iroh_ssh_app/widgets/terminal_tab.dart';
import 'package:xterm/xterm.dart';

FocusNode? findTerminalViewFocusNode(BuildContext context) {
  FocusNode? focusNode;
  void visit(Element el) {
    if (focusNode != null) return;
    final widget = el.widget;
    if (widget is TerminalView && widget.focusNode != null) {
      focusNode = widget.focusNode;
      return;
    }
    el.visitChildElements(visit);
  }
  context.visitChildElements(visit);
  return focusNode;
}

void main() {
  testWidgets('switching tabs transfers focus to active TerminalTab',
      (tester) async {
    final tabKey1 = GlobalKey<TerminalTabState>();
    final tabKey2 = GlobalKey<TerminalTabState>();

    final session1 = SshSessionInfo(
      host: 'localhost',
      port: 10001,
      username: 'user1',
      displayName: 'test1',
    );
    final session2 = SshSessionInfo(
      host: 'localhost',
      port: 10002,
      username: 'user2',
      displayName: 'test2',
    );

    final tabController = TabController(length: 2, vsync: const TestVSync());

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TabBarView(
            controller: tabController,
            children: [
              TerminalTab(
                key: tabKey1,
                session: session1,
                onDisconnected: () {},
                connectOnInit: false,
              ),
              TerminalTab(
                key: tabKey2,
                session: session2,
                onDisconnected: () {},
                connectOnInit: false,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final focusNode1 = findTerminalViewFocusNode(tabKey1.currentContext!)!;
    expect(focusNode1.hasFocus, isTrue,
        reason: 'Tab 1 should have autofocus');

    // Switch to tab 2 and call requestFocus (mirroring _onTabChanged)
    tabController.animateTo(1);
    await tester.pumpAndSettle();

    tabKey2.currentState!.requestFocus();
    await tester.pumpAndSettle();

    final focusNode2 = findTerminalViewFocusNode(tabKey2.currentContext!)!;
    expect(focusNode2.hasFocus, isTrue,
        reason: 'Tab 2 should have focus after switch');
    expect(focusNode1.hasFocus, isFalse,
        reason: 'Tab 1 should lose focus after switch');

    // Switch back to tab 1
    tabController.animateTo(0);
    await tester.pumpAndSettle();

    tabKey1.currentState!.requestFocus();
    await tester.pumpAndSettle();

    expect(focusNode1.hasFocus, isTrue,
        reason: 'Tab 1 should regain focus when switched back');
    expect(focusNode2.hasFocus, isFalse,
        reason: 'Tab 2 should lose focus when switched away');

    tabController.dispose();
  });

  testWidgets('terminal does not regain focus after connection info dialog closes',
      (tester) async {
    SettingsStorage.instance.cache = AppSettings();

    final session = SshSessionInfo(
      host: 'localhost',
      port: 10001,
      username: 'user1',
      displayName: 'test1',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: SessionsScreen(
          initialSession: session,
          connectOnInit: false,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Find the terminal's FocusNode
    final terminalView = tester.widget<TerminalView>(find.byType(TerminalView));
    final focusNode = terminalView.focusNode!;
    expect(focusNode.hasFocus, isTrue,
        reason: 'Terminal should have focus initially');

    // Tap the connection info button
    await tester.tap(find.byIcon(Icons.info_outline));
    await tester.pumpAndSettle();

    // Dialog should be visible
    expect(find.text('Connection Info'), findsOneWidget);

    // Close the dialog
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    // Terminal should not have regained focus (keyboard stays closed)
    expect(focusNode.hasFocus, isFalse,
        reason: 'Terminal should not regain focus after dialog closes');
  });
}
