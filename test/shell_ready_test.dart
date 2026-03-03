import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iroh_ssh_app/models/ssh_session_info.dart';
import 'package:iroh_ssh_app/widgets/terminal_tab.dart';

void main() {
  testWidgets('shellReady is false when tab has not connected', (tester) async {
    final tabKey = GlobalKey<TerminalTabState>();

    final session = SshSessionInfo(
      sessionId: 'test1',
      host: 'localhost',
      port: 10001,
      username: 'user1',
      displayName: 'test1',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TerminalTab(
            key: tabKey,
            session: session,
            onDisconnected: () {},
            connectOnInit: false,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tabKey.currentState!.shellReady, isFalse,
        reason: 'shellReady should be false before shell is established');
    expect(tabKey.currentState!.connected, isFalse,
        reason: 'connected should be false before connection');
  });
}
