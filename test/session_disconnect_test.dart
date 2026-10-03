import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iroh_ssh_app/models/connection_type.dart';
import 'package:iroh_ssh_app/models/ssh_session_info.dart';
import 'package:iroh_ssh_app/screens/sessions_screen.dart';
import 'package:iroh_ssh_app/services/settings_storage.dart';
import 'package:iroh_ssh_app/widgets/terminal_tab.dart';

void main() {
  testWidgets(
    'duplicate and stale disconnect callbacks never close a different session',
    (tester) async {
      SettingsStorage.instance.cache = AppSettings();
      await tester.pumpWidget(
        MaterialApp(
          home: SessionsScreen(
            existingSessions: [
              for (final id in ['a', 'b', 'c'])
                SshSessionInfo(
                  sessionId: id,
                  host: 'localhost',
                  port: 22,
                  username: 'u',
                  displayName: id,
                  connectionType: ConnectionType.ssh,
                ),
            ],
            connectOnInit: false,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final view = tester.widget<TabBarView>(find.byType(TabBarView));
      // Callbacks from the frame before the list changes, as in one IPC dispatch.
      TerminalTab tab(Widget child) =>
          (((child as Stack).children.first as Positioned).child as Padding)
                  .child
              as TerminalTab;
      final a = tab(view.children[0]).onDisconnected;
      final b = tab(view.children[1]).onDisconnected;
      a();
      a();
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TabBarView>(find.byType(TabBarView))
            .children
            .map((child) => tab(child).session.sessionId),
        ['b', 'c'],
      );
      b();
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TabBarView>(find.byType(TabBarView))
            .children
            .map((child) => tab(child).session.sessionId),
        ['c'],
      );
    },
  );
}
