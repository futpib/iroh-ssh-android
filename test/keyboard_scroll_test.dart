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

/// Find the Scrollable inside TerminalView and return its scroll offset.
double _scrollOffset(WidgetTester tester) {
  final scrollable = tester.widget<Scrollable>(
    find.descendant(
      of: find.byType(TerminalView),
      matching: find.byType(Scrollable),
    ),
  );
  return scrollable.controller!.offset;
}

void main() {
  testWidgets(
      'cursor row stays visible after text input when keyboard is open '
      'and terminal has few lines', (tester) async {
    final terminal = Terminal(maxLines: 100);

    // Start without keyboard to establish full terminal dimensions.
    await tester.pumpWidget(_buildApp(
      terminal: terminal,
      keyboardHeight: 0,
    ));
    await tester.pumpAndSettle();

    final fullViewHeight = terminal.viewHeight;
    expect(fullViewHeight, greaterThan(0));

    // Write a short prompt (only a few lines of content).
    terminal.write('user@host:~\$ ');

    await tester.pumpAndSettle();

    // Cursor should be near the top of the terminal (row 0).
    expect(terminal.buffer.cursorY, lessThan(fullViewHeight ~/ 2),
        reason: 'Cursor should be in the top half of the terminal');

    // Open the keyboard — viewport shrinks significantly.
    await tester.pumpWidget(_buildApp(
      terminal: terminal,
      keyboardHeight: 300,
    ));
    await tester.pumpAndSettle();

    // Simulate typing a character. In a real scenario this goes through
    // TerminalView's _onInsert which calls _scrollToBottom().
    terminal.textInput('a');
    await tester.pumpAndSettle();

    // The scroll offset should be small enough that the cursor row (near
    // the top) is still within the visible viewport. If the bug is present,
    // the scroll jumps to maxScrollExtent showing the bottom empty rows.
    final offset = _scrollOffset(tester);
    final cellHeight = tester.getSize(find.byType(TerminalView)).height /
        fullViewHeight; // approximate cell height if no autoResize
    final cursorPixelY = terminal.buffer.cursorY * cellHeight;

    // The visible viewport starts at `offset` and extends for the viewport
    // height. The cursor row must fall within this range.
    final viewportHeight = tester.getSize(find.byType(TerminalView)).height;
    expect(offset, lessThanOrEqualTo(cursorPixelY),
        reason:
            'Scroll offset should not be past the cursor (cursor scrolled off top)');
    expect(offset + viewportHeight, greaterThanOrEqualTo(cursorPixelY),
        reason:
            'Cursor row should be within the visible viewport (cursor scrolled off bottom)');
  });

  testWidgets('scroll correction is suppressed while user finger is down',
      (tester) async {
    final terminal = Terminal(maxLines: 100);

    await tester.pumpWidget(_buildApp(
      terminal: terminal,
      keyboardHeight: 0,
    ));
    await tester.pumpAndSettle();

    // Fill enough lines so there is scrollback when keyboard opens.
    final fullViewHeight = terminal.viewHeight;
    for (var i = 0; i < fullViewHeight + 10; i++) {
      terminal.write('line $i\r\n');
    }
    await tester.pumpAndSettle();

    // Open keyboard.
    await tester.pumpWidget(_buildApp(
      terminal: terminal,
      keyboardHeight: 300,
    ));
    await tester.pumpAndSettle();

    // Record where the scroll settled after keyboard opened.
    final offsetAfterKeyboard = _scrollOffset(tester);

    // User manually scrolls up by dragging.
    final terminalCenter = tester.getCenter(find.byType(TerminalView));
    final gesture = await tester.startGesture(terminalCenter);
    await tester.pump();
    await gesture.moveBy(const Offset(0, 100));
    await tester.pump();

    final offsetAfterDrag = _scrollOffset(tester);
    expect(offsetAfterDrag, isNot(equals(offsetAfterKeyboard)),
        reason: 'User drag should have moved scroll position');

    // While finger is still down, terminal output arrives that moves cursor.
    terminal.write('new output\r\n');
    await tester.pumpAndSettle();

    // Scroll should NOT have jumped back — user is still touching.
    expect(_scrollOffset(tester), equals(offsetAfterDrag),
        reason:
            'Scroll correction must not fire while user finger is on screen');

    // Lift finger.
    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('same-position cursor move does not trigger scroll correction',
      (tester) async {
    final terminal = Terminal(maxLines: 100);

    await tester.pumpWidget(_buildApp(
      terminal: terminal,
      keyboardHeight: 0,
    ));
    await tester.pumpAndSettle();

    // Fill lines so there is scrollback.
    final fullViewHeight = terminal.viewHeight;
    for (var i = 0; i < fullViewHeight + 10; i++) {
      terminal.write('line $i\r\n');
    }
    await tester.pumpAndSettle();

    // Open keyboard and let initial correction settle.
    await tester.pumpWidget(_buildApp(
      terminal: terminal,
      keyboardHeight: 300,
    ));
    await tester.pumpAndSettle();

    final offsetAfterKeyboard = _scrollOffset(tester);

    // User scrolls up manually.
    final terminalCenter = tester.getCenter(find.byType(TerminalView));
    final gesture = await tester.startGesture(terminalCenter);
    await tester.pump();
    await gesture.moveBy(const Offset(0, 80));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    final offsetAfterScroll = _scrollOffset(tester);
    expect(offsetAfterScroll, isNot(equals(offsetAfterKeyboard)),
        reason: 'User should have scrolled to a different position');

    // Move cursor to same absolute position it's already at (CUP to current
    // row). This triggers a terminal change notification without actually
    // moving the cursor.
    final cursorRow = terminal.buffer.cursorY + 1; // 1-based for CSI
    final cursorCol = terminal.buffer.cursorX + 1;
    terminal.write('\x1B[${cursorRow};${cursorCol}H');
    await tester.pumpAndSettle();

    // Scroll should stay where the user left it.
    expect(_scrollOffset(tester), equals(offsetAfterScroll),
        reason:
            'Same-position cursor move should not trigger scroll correction');
  });
}
