import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iroh_ssh_app/widgets/terminal_pane.dart';
import 'package:xterm/src/ui/custom_text_edit.dart';
import 'package:xterm/xterm.dart';

void main() {
  late List<String> output;
  late CustomTextEditState edit;

  Future<void> start(WidgetTester tester) async {
    output = [];
    final terminal = Terminal()..onOutput = output.add;
    Widget app(double inset) => MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(viewInsets: EdgeInsets.only(bottom: inset)),
        child: Scaffold(
          resizeToAvoidBottomInset: false,
          body: TerminalPane(terminal: terminal, autofocus: true),
        ),
      ),
    );
    await tester.pumpWidget(app(0));
    await tester.pumpAndSettle();
    await tester.pumpWidget(app(200));
    await tester.pumpAndSettle();
    await tester.tap(find.text('PSWRD'));
    await tester.pumpAndSettle();
    edit = tester.state(find.byType(CustomTextEdit));
  }

  void input(String text, {bool composing = false}) {
    edit.updateEditingValue(
      TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
        composing: composing
            ? TextRange(start: 0, end: text.length)
            : TextRange.empty,
      ),
    );
  }

  testWidgets('Gboard Enter clears retained word before next glide', (
    tester,
  ) async {
    await start(tester);
    input('hello');
    edit.performAction(TextInputAction.newline);
    expect(edit.currentTextEditingValue!.text, isEmpty);
    input('hello');
    expect(output.join(), 'hello\rhello');
  });

  testWidgets('Enter commits unfinished composition exactly once', (
    tester,
  ) async {
    await start(tester);
    input('hello', composing: true);
    expect(output, isEmpty);
    edit.performAction(TextInputAction.newline);
    expect(output.join(), 'hello\r');
    expect(edit.currentTextEditingValue!.text, isEmpty);
  });

  testWidgets('FUTO committed newline discards the submitted line', (
    tester,
  ) async {
    await start(tester);
    input('hello');
    input('hello\n');
    expect(edit.currentTextEditingValue!.text, isEmpty);
    input('world');
    expect(output.join(), 'hello\rworld');
  });

  for (final button in ['←', '→', 'HOME', 'END', '↑', '↓', 'TAB', 'ESC']) {
    testWidgets('$button invalidates old correction candidates', (
      tester,
    ) async {
      await start(tester);
      input('help');
      await tester.tap(find.text(button));
      await tester.pump();
      expect(edit.currentTextEditingValue!.text, isEmpty);
      output.clear();
      input('new');
      expect(
        output.join(),
        'new',
        reason: 'No backspaces against the old word',
      );
    });
  }

  testWidgets('toolbar navigation commits composition before moving', (
    tester,
  ) async {
    await start(tester);
    input('help', composing: true);
    await tester.tap(find.text('←'));
    await tester.pump();
    expect(output.join(), 'help\x1b[D');
    expect(edit.currentTextEditingValue!.text, isEmpty);
  });

  testWidgets('hardware arrow and Enter clear retained IME context', (
    tester,
  ) async {
    await start(tester);
    input('hello');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    expect(edit.currentTextEditingValue!.text, isEmpty);
    input('world');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(edit.currentTextEditingValue!.text, isEmpty);
    expect(output.join(), 'hello\x1b[Dworld\r');
  });

  testWidgets('ordinary candidates and word deletion still work', (
    tester,
  ) async {
    await start(tester);
    input('help');
    input('hello ');
    input('hello world');
    input('hello ');
    expect(output.join(), 'help\x7flo world${'\x7f' * 5}');
    expect(edit.currentTextEditingValue!.text, 'hello ');
  });

  testWidgets('password toggle discards correction context', (tester) async {
    await start(tester);
    input('hello');
    await tester.tap(find.text('PSWRD'));
    await tester.pump();
    expect(edit.currentTextEditingValue!.text, isEmpty);
    input('x');
    expect(edit.currentTextEditingValue!.text, isEmpty);
    expect(output.join(), 'hellox');
  });
  testWidgets('modifier activation commits pending word before Ctrl-W', (
    tester,
  ) async {
    await start(tester);
    input('hello', composing: true);
    await tester.tap(find.text('CTRL'));
    await tester.pump();
    input('w');
    input('world');
    expect(output.join(), 'hello\x17world');
  });

  testWidgets('password toggle commits unfinished word', (tester) async {
    await start(tester);
    input('hello', composing: true);
    await tester.tap(find.text('PSWRD'));
    await tester.pump();
    expect(output.join(), 'hello');
    expect(edit.currentTextEditingValue!.text, isEmpty);
  });

  testWidgets('committed multiline input retains only current line', (
    tester,
  ) async {
    await start(tester);
    input('one\r\ntwo\nthree');
    expect(output.join(), 'one\rtwo\rthree');
    expect(edit.currentTextEditingValue!.text, 'three');
    input('three!');
    expect(output.last, '!');
  });

  testWidgets(
    'clipboard paste commits composition and clears correction history',
    (tester) async {
      await start(tester);
      input('hello', composing: true);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.getData') return {'text': ' pasted'};
          return null;
        },
      );
      final context = tester.element(find.byType(CustomTextEdit));
      Actions.invoke(
        context,
        const PasteTextIntent(SelectionChangedCause.keyboard),
      );
      await tester.pumpAndSettle();
      expect(output.join(), 'hello pasted');
      expect(edit.currentTextEditingValue!.text, isEmpty);
      input('new');
      expect(output.last, 'new');
    },
  );
  testWidgets(
    'Ctrl-V shortcut preserves committed text and subsequent typing',
    (tester) async {
      await start(tester);
      input('hello');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.getData') return {'text': ' pasted '};
          return null;
        },
      );
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      input('world');
      expect(output.join(), 'hello pasted world');
    },
  );
}
