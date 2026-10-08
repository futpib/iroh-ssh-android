import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iroh_ssh_app/widgets/terminal_pane.dart';
import 'package:xterm/xterm.dart';

void main() {
  for (final alternate in [false, true]) {
    testWidgets(
      'selection pauses pane scrolling and copies (alternate=$alternate)',
      (tester) async {
        final output = <String>[];
        final scrollEvents = <double>[];
        String? copied;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.setData') {
              copied = (call.arguments as Map)['text'] as String;
            }
            return null;
          },
        );
        final terminal = Terminal(onOutput: output.add);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: TerminalPane(
                terminal: terminal,
                onVerticalScrollDelta: scrollEvents.add,
              ),
            ),
          ),
        );
        if (alternate) terminal.write('\x1b[?1049h\x1b[?1002h\x1b[?1006h');
        terminal.write('hello world\r\nsecond line');
        await tester.pumpAndSettle();
        final state = tester.state<TerminalViewState>(
          find.byType(TerminalView),
        );
        final render = state.renderTerminal;
        final origin = render.localToGlobal(
          render.getOffset(const CellOffset(2, 0)) +
              Offset(render.cellSize.width / 2, render.lineHeight / 2),
        );
        final gesture = await tester.startGesture(origin);
        await tester.pump(const Duration(milliseconds: 600));
        await tester.pumpAndSettle();
        expect(find.text('Copy'), findsOneWidget);
        output.clear();
        scrollEvents.clear();
        await gesture.moveBy(Offset(0, render.lineHeight));
        await tester.pump();
        await gesture.up();
        await tester.pumpAndSettle();
        expect(scrollEvents, isEmpty);
        expect(
          output,
          isEmpty,
          reason: 'Selecting must not send wheel or arrow input',
        );
        final view = tester.widget<TerminalView>(find.byType(TerminalView));
        final selected = terminal.buffer.getText(view.controller!.selection!);
        expect(selected, contains('hello world\nsecond'));
        await tester.tap(find.text('Copy'));
        await tester.pumpAndSettle();
        expect(copied, selected);
        expect(view.controller!.selection, isNull);
        await tester.drag(find.byType(TerminalView), const Offset(0, -100));
        await tester.pumpAndSettle();
        expect(scrollEvents, isNotEmpty, reason: 'Ordinary scrolling resumes');
      },
    );
  }
  testWidgets('output does not pull a selected viewport to the cursor', (
    tester,
  ) async {
    final terminal = Terminal();
    Widget app(double inset) => MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(
          size: const Size(800, 600),
          viewInsets: EdgeInsets.only(bottom: inset),
        ),
        child: Scaffold(
          resizeToAvoidBottomInset: false,
          body: TerminalPane(terminal: terminal),
        ),
      ),
    );
    await tester.pumpWidget(app(0));
    for (var i = 0; i < 80; i++) {
      terminal.write('line $i\r\n');
    }
    await tester.pumpAndSettle();
    await tester.pumpWidget(app(250));
    await tester.pumpAndSettle();
    final view = tester.widget<TerminalView>(find.byType(TerminalView));
    view.scrollController!.jumpTo(0);
    await tester.pumpAndSettle();
    view.controller!.setSelection(
      terminal.buffer.createAnchor(0, 0),
      terminal.buffer.createAnchor(4, 0),
    );
    terminal.write('new output\r\n');
    await tester.pumpAndSettle();
    expect(view.scrollController!.offset, 0);
    expect(terminal.buffer.getText(view.controller!.selection!), 'line');
  });
  testWidgets('opening the keyboard keeps the selected text visible', (
    tester,
  ) async {
    final terminal = Terminal();
    Widget app(double inset) => MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(
          size: const Size(800, 600),
          viewInsets: EdgeInsets.only(bottom: inset),
        ),
        child: Scaffold(
          resizeToAvoidBottomInset: false,
          body: TerminalPane(terminal: terminal),
        ),
      ),
    );
    await tester.pumpWidget(app(0));
    terminal.write('hello world');
    await tester.pumpAndSettle();
    final view = tester.widget<TerminalView>(find.byType(TerminalView));
    view.controller!.setSelection(
      terminal.buffer.createAnchor(0, 0),
      terminal.buffer.createAnchor(5, 0),
    );
    tester
        .state<TerminalViewState>(find.byType(TerminalView))
        .showSelectionToolbar();
    await tester.pumpAndSettle();
    await tester.pumpWidget(app(250));
    await tester.pumpAndSettle();
    expect(view.scrollController!.offset, 0);
    expect(find.text('Copy'), findsOneWidget);
    expect(terminal.buffer.getText(view.controller!.selection!), 'hello');
  });
}
