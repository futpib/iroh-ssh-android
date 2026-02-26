import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iroh_ssh_app/widgets/terminal_pane.dart';
import 'package:xterm/xterm.dart';

Widget _buildApp({
  required Terminal terminal,
  required double keyboardHeight,
}) {
  return MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(
        size: const Size(800, 600),
        viewInsets: EdgeInsets.only(bottom: keyboardHeight),
      ),
      child: Scaffold(
        resizeToAvoidBottomInset: false,
        body: SizedBox(
          width: 800,
          height: 600,
          child: TerminalPane(
            terminal: terminal,
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('terminal rows and cols do not change when keyboard opens',
      (tester) async {
    final terminal = Terminal(maxLines: 100);

    await tester.pumpWidget(_buildApp(
      terminal: terminal,
      keyboardHeight: 0,
    ));
    await tester.pumpAndSettle();

    final widthBefore = terminal.viewWidth;
    final heightBefore = terminal.viewHeight;
    expect(widthBefore, greaterThan(0));
    expect(heightBefore, greaterThan(0));

    await tester.pumpWidget(_buildApp(
      terminal: terminal,
      keyboardHeight: 300,
    ));
    await tester.pumpAndSettle();

    expect(terminal.viewWidth, equals(widthBefore));
    expect(terminal.viewHeight, equals(heightBefore));
  });

  testWidgets('top of terminal is visible when keyboard opens',
      (tester) async {
    final terminal = Terminal(maxLines: 100);

    await tester.pumpWidget(_buildApp(
      terminal: terminal,
      keyboardHeight: 0,
    ));
    await tester.pumpAndSettle();

    final topBefore = tester.getTopLeft(find.byType(TerminalView)).dy;

    await tester.pumpWidget(_buildApp(
      terminal: terminal,
      keyboardHeight: 300,
    ));
    await tester.pumpAndSettle();

    final topAfter = tester.getTopLeft(find.byType(TerminalView)).dy;

    expect(topAfter, equals(topBefore));
    expect(topAfter, greaterThanOrEqualTo(0),
        reason: 'Top of terminal must remain visible');
  });
}
