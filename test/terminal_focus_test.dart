import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iroh_ssh_app/models/ssh_session_info.dart';
import 'package:iroh_ssh_app/widgets/terminal_tab.dart';
import 'package:xterm/xterm.dart';

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

    // Get the FocusNode from the TerminalView rendered by tab 1
    FocusNode? getFocusNodeForTab(GlobalKey<TerminalTabState> tabKey) {
      final element = tabKey.currentContext!;
      FocusNode? focusNode;
      element.visitChildElements((child) {
        void visit(Element el) {
          final widget = el.widget;
          if (widget is TerminalView && widget.focusNode != null) {
            focusNode = widget.focusNode;
            return;
          }
          el.visitChildElements(visit);
        }
        visit(child);
      });
      return focusNode;
    }

    final focusNode1 = getFocusNodeForTab(tabKey1)!;
    expect(focusNode1.hasFocus, isTrue,
        reason: 'Tab 1 should have autofocus');

    // Switch to tab 2 and call requestFocus (mirroring _onTabChanged)
    tabController.animateTo(1);
    await tester.pumpAndSettle();

    tabKey2.currentState!.requestFocus();
    await tester.pumpAndSettle();

    final focusNode2 = getFocusNodeForTab(tabKey2)!;
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
}
