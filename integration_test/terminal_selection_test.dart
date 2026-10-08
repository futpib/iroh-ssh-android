import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:iroh_ssh_app/widgets/terminal_pane.dart';
import 'package:xterm/xterm.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Android terminal selection uses the real clipboard', (
    tester,
  ) async {
    final output = <String>[];
    final terminal = Terminal(onOutput: output.add);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          resizeToAvoidBottomInset: false,
          appBar: AppBar(title: const Text('Terminal selection')),
          body: TerminalPane(terminal: terminal),
        ),
      ),
    );
    terminal.write(
      'Select and copy\r\nhello world\r\nDrag handles to adjust this text.\r\n',
    );
    await tester.pumpAndSettle();
    final state = tester.state<TerminalViewState>(find.byType(TerminalView));
    Offset word() {
      final render = state.renderTerminal;
      return render.localToGlobal(
        render.getOffset(const CellOffset(2, 1)) +
            Offset(render.cellSize.width / 2, render.lineHeight / 2),
      );
    }

    await tester.longPressAt(word());
    await tester.pumpAndSettle();
    expect(find.text('Copy'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('terminal-selection-start')),
      findsOneWidget,
    );
    await tester.tap(find.text('Copy'));
    await tester.pumpAndSettle();
    expect((await Clipboard.getData(Clipboard.kTextPlain))?.text, 'hello');

    terminal.write('\x1b[?2004h');
    await Clipboard.setData(const ClipboardData(text: 'paste test\n'));
    await tester.longPressAt(word());
    await tester.pumpAndSettle();
    output.clear();
    await tester.tap(find.text('Paste'));
    await tester.pumpAndSettle();
    expect(output.join(), '\x1b[200~paste test\n\x1b[201~');

    await tester.longPressAt(word());
    await tester.pumpAndSettle();
    final handle = find.byKey(const ValueKey('terminal-selection-end'));
    final gesture = await tester.startGesture(tester.getCenter(handle));
    await gesture.moveBy(const Offset(25, 0));
    await tester.pump();
    await gesture.moveBy(Offset(state.renderTerminal.cellSize.width * 4, 0));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    final controller = tester
        .widget<TerminalView>(find.byType(TerminalView))
        .controller!;
    expect(controller.selection!.end.x, greaterThan(5));
    await tester.tap(find.text('Select all'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy'));
    await tester.pumpAndSettle();
    expect(
      (await Clipboard.getData(Clipboard.kTextPlain))?.text,
      startsWith('Select and copy\nhello world\nDrag handles'),
    );
    await tester.longPressAt(word());
    await tester.pumpAndSettle();
  });
}
