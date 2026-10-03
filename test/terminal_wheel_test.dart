import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iroh_ssh_app/widgets/terminal_pane.dart';
import 'package:xterm/xterm.dart';

void main() {
  for (final keyboardHeight in [0.0, 250.0]) {
    for (final direction in [1.0, -1.0]) {
      testWidgets(
        'touch scroll ${direction > 0 ? 'up' : 'down'} sends an unmodified '
        'wheel event with keyboard height $keyboardHeight',
        (tester) async {
          final output = <String>[];
          final terminal = Terminal(onOutput: output.add);
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
          await tester.pumpAndSettle();
          // tmux's outer terminal: alternate screen, button-event tracking,
          // and SGR mouse encoding. Its default bindings require plain wheels.
          terminal.write('\x1b[?1049h\x1b[?1002h\x1b[?1006h');
          await tester.pumpWidget(app(keyboardHeight));
          await tester.pumpAndSettle();
          output.clear();

          await tester.drag(
            find.byType(TerminalView),
            Offset(0, direction * 100),
          );
          await tester.pumpAndSettle();

          final packets = RegExp(
            r'\x1b\[<(\d+);(\d+);(\d+)M',
          ).allMatches(output.join()).toList();
          expect(packets, isNotEmpty);
          for (final packet in packets) {
            expect(packet.group(1), direction > 0 ? '64' : '65');
            expect(int.parse(packet.group(2)!), greaterThan(0));
            expect(int.parse(packet.group(3)!), greaterThan(0));
          }
        },
      );
    }
  }
}
