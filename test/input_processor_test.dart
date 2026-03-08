import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iroh_ssh_app/input_processor.dart';

void main() {
  late InputProcessor processor;

  setUp(() {
    processor = InputProcessor();
  });

  group('applyModifiers', () {
    test('no modifiers passes through', () {
      expect(processor.applyModifiers('hello'), 'hello');
    });

    test('ctrl converts lowercase to control characters', () {
      processor.ctrlState = ModifierState.transient;
      // ctrl+w = 0x17 (0x77 - 0x60)
      expect(processor.applyModifiers('w'), String.fromCharCode(0x17));
    });

    test('ctrl converts uppercase to control characters', () {
      processor.ctrlState = ModifierState.transient;
      // ctrl+W = 0x17 (0x57 - 0x40)
      expect(processor.applyModifiers('W'), String.fromCharCode(0x17));
    });

    test('alt prepends ESC', () {
      processor.altState = ModifierState.transient;
      expect(processor.applyModifiers('a'), '\x1ba');
    });

    test('alt+shift uppercases', () {
      processor.altState = ModifierState.transient;
      processor.shiftState = ModifierState.transient;
      expect(processor.applyModifiers('a'), '\x1bA');
    });

    test('shift uppercases lowercase', () {
      processor.shiftState = ModifierState.transient;
      expect(processor.applyModifiers('abc'), 'ABC');
    });

    test('shift does not change non-letter characters', () {
      processor.shiftState = ModifierState.transient;
      expect(processor.applyModifiers('1'), '1');
    });

    test('locked modifier works same as transient', () {
      processor.ctrlState = ModifierState.locked;
      expect(processor.applyModifiers('c'), String.fromCharCode(0x03));
    });
  });

  group('clearModifiers', () {
    test('sets modifiedInput when transient ctrl is active', () {
      processor.ctrlState = ModifierState.transient;
      processor.clearModifiers();
      expect(processor.modifiedInput, true);
      expect(processor.ctrlState, ModifierState.off);
    });

    test('sets modifiedInput when transient alt is active', () {
      processor.altState = ModifierState.transient;
      processor.clearModifiers();
      expect(processor.modifiedInput, true);
      expect(processor.altState, ModifierState.off);
    });

    test('does not set modifiedInput for shift only', () {
      processor.shiftState = ModifierState.transient;
      processor.clearModifiers();
      expect(processor.modifiedInput, false);
      expect(processor.shiftState, ModifierState.off);
    });

    test('does not clear locked modifiers', () {
      processor.ctrlState = ModifierState.locked;
      processor.clearModifiers();
      expect(processor.ctrlState, ModifierState.locked);
    });
  });

  group('processInput', () {
    test('simple insert', () {
      final result = processor.processInput('', 'hello');
      expect(result.deletions, 0);
      expect(result.inserted, 'hello');
      expect(result.modified, 'hello');
    });

    test('simple delete', () {
      final result = processor.processInput('hello', 'hel');
      expect(result.deletions, 2);
      expect(result.inserted, '');
      expect(result.modified, '');
    });

    test('replacement', () {
      final result = processor.processInput('rusty', 'trust');
      expect(result.deletions, 5);
      expect(result.inserted, 'trust');
      expect(result.modified, 'trust');
    });

    test('partial replacement with common prefix', () {
      final result = processor.processInput('hello world', 'hello there');
      expect(result.deletions, 5);
      expect(result.inserted, 'there');
      expect(result.modified, 'there');
    });

    test('with ctrl active applies modifier to last char only', () {
      processor.ctrlState = ModifierState.transient;
      final result = processor.processInput('', 'w');
      expect(result.deletions, 0);
      expect(result.inserted, 'w');
      expect(result.modified, String.fromCharCode(0x17));
    });

    test('with ctrl active clears modifiers after processing', () {
      processor.ctrlState = ModifierState.transient;
      processor.processInput('', 'w');
      expect(processor.ctrlActive, false);
      // processInput handles the input itself, so it must NOT set
      // modifiedInput (that flag is only for the key-event path).
      expect(processor.modifiedInput, false);
    });

    test('with ctrl active extracts last char even when text got shorter', () {
      processor.ctrlState = ModifierState.transient;
      final result = processor.processInput('hello', 'hel');
      // Last char of "hel" is 'l', ctrl+l = 0x0c
      expect(result.inserted, 'l');
      expect(result.modified, String.fromCharCode(0x0c));
      expect(processor.ctrlActive, false);
      expect(processor.modifiedInput, false);
    });

    test('with ctrl active ignores auto-space prefix', () {
      processor.ctrlState = ModifierState.transient;
      final result = processor.processInput('hello', 'hello w');
      expect(result.deletions, 0);
      expect(result.inserted, 'w');
      expect(result.modified, String.fromCharCode(0x17));
    });

    test('append to existing text', () {
      final result = processor.processInput('hello', 'hello world');
      expect(result.deletions, 0);
      expect(result.inserted, ' world');
      expect(result.modified, ' world');
    });

    test('empty to empty', () {
      final result = processor.processInput('', '');
      expect(result.deletions, 0);
      expect(result.inserted, '');
      expect(result.modified, '');
    });
  });

  group('commitEditingState', () {
    test('retains text normally', () {
      final result = processor.commitEditingState(
        const TextEditingValue(
          text: 'hello',
          selection: TextSelection.collapsed(offset: 5),
        ),
      );
      expect(result, isNotNull);
      expect(result!.text, 'hello');
      expect(result.selection.baseOffset, 5);
    });

    test('returns null when ctrlActive', () {
      processor.ctrlState = ModifierState.transient;
      final result = processor.commitEditingState(
        const TextEditingValue(text: 'w'),
      );
      expect(result, isNull);
    });

    test('returns null when altActive', () {
      processor.altState = ModifierState.transient;
      final result = processor.commitEditingState(
        const TextEditingValue(text: 'x'),
      );
      expect(result, isNull);
    });

    test('returns null when modifiedInput is true', () {
      processor.modifiedInput = true;
      final result = processor.commitEditingState(
        const TextEditingValue(text: 'hello'),
      );
      expect(result, isNull);
      expect(processor.modifiedInput, false);
    });

    test('truncates at word boundary when over max length', () {
      final longText = 'the quick brown fox jumps over the lazy dog and then some more words here';
      final result = processor.commitEditingState(
        TextEditingValue(text: longText),
      );
      expect(result, isNotNull);
      expect(result!.text.length, lessThanOrEqualTo(InputProcessor.maxRetainedLength));
    });

    test('truncates to last N chars when no word boundary', () {
      final longText = 'a' * 100;
      final result = processor.commitEditingState(
        TextEditingValue(text: longText),
      );
      expect(result, isNotNull);
      expect(result!.text.length, InputProcessor.maxRetainedLength);
      expect(result.text, 'a' * InputProcessor.maxRetainedLength);
    });

    test('short text is not truncated', () {
      final result = processor.commitEditingState(
        const TextEditingValue(text: 'hello world'),
      );
      expect(result, isNotNull);
      expect(result!.text, 'hello world');
    });
  });

  group('cycleModifier', () {
    test('off -> transient -> locked -> off', () {
      var state = ModifierState.off;
      processor.cycleModifier(state, (s) => state = s);
      expect(state, ModifierState.transient);
      processor.cycleModifier(state, (s) => state = s);
      expect(state, ModifierState.locked);
      processor.cycleModifier(state, (s) => state = s);
      expect(state, ModifierState.off);
    });
  });

  group('ctrl+w with glide typing context', () {
    test('ctrl+w with retained buffer sends only ctrl+w, no auto-space', () {
      // Simulate: user has been glide-typing, buffer has accumulated text
      // Then user taps CTRL (transient) and types "w" on soft keyboard
      // Gboard sends " w" (auto-space + w)
      processor.ctrlState = ModifierState.transient;

      final result = processor.processInput(
        'test ready the door en',
        'test ready the door en w',
      );

      // Should extract only "w" (the actual key), not " w"
      expect(result.deletions, 0);
      expect(result.inserted, 'w');
      expect(result.modified, String.fromCharCode(0x17));

      // Modifiers should be cleared, but modifiedInput stays false because
      // processInput handled the input itself (no key-event-path involved).
      expect(processor.ctrlActive, false);
      expect(processor.modifiedInput, false);
    });

    test('ctrl+w without auto-space prefix', () {
      processor.ctrlState = ModifierState.transient;

      final result = processor.processInput('', 'w');

      expect(result.deletions, 0);
      expect(result.inserted, 'w');
      expect(result.modified, String.fromCharCode(0x17));
    });

    test('ctrl with shorter text extracts last char of current', () {
      processor.ctrlState = ModifierState.transient;

      final result = processor.processInput('hello', 'hel');

      // Last char of "hel" is 'l', ctrl+l = 0x0c
      expect(result.deletions, 0);
      expect(result.inserted, 'l');
      expect(result.modified, String.fromCharCode(0x0c));
    });
  });

  group('ctrl+w in glide mode should not pollute retained buffer', () {
    // Reproduces the bug from device logs where ctrl+w via processInput
    // no longer sets modifiedInput, so commitEditingState retains the
    // raw "w" in the buffer. After two ctrl+w's the buffer becomes
    // "test buddy ww" — the stale "ww" will corrupt the next diff.

    test('commitEditingState rejects buffer after processInput handles ctrl', () {
      // User glide-typed "test buddy", buffer retained as "test buddy"
      // Then user taps CTRL and types "w" — Gboard sends "test buddy w"
      processor.ctrlState = ModifierState.transient;
      final result = processor.processInput('test buddy', 'test buddy w');

      expect(result.modified, String.fromCharCode(0x17));

      // commitEditingState should reject (return null) so the raw "w"
      // is not retained in the buffer.
      final committed = processor.commitEditingState(
        const TextEditingValue(text: 'test buddy w'),
      );
      expect(committed, isNull,
          reason: 'Buffer must be reset after ctrl+key handled by processInput');
    });

    test('two ctrl+w do not accumulate stale chars in buffer', () {
      // First ctrl+w
      processor.ctrlState = ModifierState.transient;
      processor.processInput('test buddy', 'test buddy w');
      final c1 = processor.commitEditingState(
        const TextEditingValue(text: 'test buddy w'),
      );
      expect(c1, isNull,
          reason: 'First ctrl+w should reset buffer');

      // Second ctrl+w (buffer should have been reset, but Gboard may
      // keep sending with stale base)
      processor.ctrlState = ModifierState.transient;
      processor.processInput('test buddy w', 'test buddy ww');
      final c2 = processor.commitEditingState(
        const TextEditingValue(text: 'test buddy ww'),
      );
      expect(c2, isNull,
          reason: 'Second ctrl+w should also reset buffer');
    });

    test('normal input after ctrl+w is not corrupted by stale buffer', () {
      // ctrl+w
      processor.ctrlState = ModifierState.transient;
      processor.processInput('test buddy', 'test buddy w');
      final c1 = processor.commitEditingState(
        const TextEditingValue(text: 'test buddy w'),
      );
      expect(c1, isNull);

      // Assuming buffer was properly reset, next glide-typed word
      // diffs cleanly against "test buddy" (not "test buddy w")
      final result = processor.processInput('test buddy', 'test buddy hello');
      expect(result.deletions, 0);
      expect(result.inserted, ' hello');
      expect(result.modified, ' hello');
    });
  });

  group('ctrl+w handled by key event path (real device flow)', () {
    // On real devices, the ctrl+w key event is handled by the key event
    // handler (terminal_tab._handleIpcTerminalInput), NOT by processInput.
    // The key event handler calls clearModifiers() which sets modifiedInput.
    // Then the IME update arrives with the raw "w" in the buffer.

    test(
      'IME update after key-event-handled ctrl+w should not produce output',
      () {
        // Step 1: User taps CTRL (transient) on toolbar
        processor.ctrlState = ModifierState.transient;

        // Step 2: Key event path handles ctrl+w, calls clearModifiers()
        // (simulating what terminal_tab._handleIpcTerminalInput does)
        processor.clearModifiers();
        expect(processor.ctrlActive, false);
        expect(processor.modifiedInput, true);

        // Step 3: IME update arrives with "w" appended to retained buffer
        final result = processor.processInput(
          'test fork ido refill ',
          'test fork ido refill w',
        );

        // Should produce no output — ctrl+w was already handled
        expect(result.deletions, 0);
        expect(result.inserted, '');
        expect(result.modified, '');
      },
    );

    test(
      'commit after key-event-handled ctrl+w retains buffer',
      () {
        processor.ctrlState = ModifierState.transient;
        processor.clearModifiers();

        // processInput consumes modifiedInput (clears it to false)
        processor.processInput(
          'test fork ido refill ',
          'test fork ido refill w',
        );
        expect(processor.modifiedInput, false);

        // Since modifiedInput was already consumed, commit retains normally
        final committed = processor.commitEditingState(
          const TextEditingValue(text: 'test fork ido refill w'),
        );

        expect(committed, isNotNull,
            reason: 'modifiedInput was consumed by processInput');
      },
    );

    test(
      'stale base: repeated IME updates after failed reset',
      () {
        // After commit returns null, xterm.dart calls setEditingState to
        // reset the buffer. But Gboard ignores it and keeps sending updates
        // with the old base.
        processor.ctrlState = ModifierState.transient;
        processor.clearModifiers();

        // First IME update — skipped because modifiedInput is true
        processor.processInput(
          'test fork ido refill ',
          'test fork ido refill w',
        );
        processor.commitEditingState(
          const TextEditingValue(text: 'test fork ido refill w'),
        );

        // Gboard sends the same update again (stale base, reset didn't propagate)
        // ctrl is still active from toolbar (user pressed it again)
        processor.ctrlState = ModifierState.transient;
        final result = processor.processInput(
          'test fork ido refill ',
          'w',
        );

        // Should extract "w" as the last char and apply ctrl
        expect(result.deletions, 0);
        expect(result.inserted, 'w');
        expect(result.modified, String.fromCharCode(0x17));
      },
    );
  });

  group('ctrl+w in PWD mode loses keystrokes (regression)', () {
    // Reproduces the bug from device logs where typing "foo bar" then
    // ctrl+w then "qux" in PWD mode loses the ctrl+w and the "q".
    //
    // Log excerpt:
    //   base="" current="w" ctrl=transient modifiedInput=false → modified=""  (BUG: should be \x17)
    //   base="" current="w" ctrl=transient modifiedInput=true  → modified=""
    //   base="" current="w" ctrl=transient modifiedInput=false → modified=""  (BUG: should be \x17)
    //   base="" current="q" ctrl=off       modifiedInput=true  → modified=""  (BUG: "q" eaten)

    test('ctrl+w should produce ctrl character, not empty string', () {
      // User typed "foo bar" normally (each char one at a time in PWD mode),
      // then tapped CTRL (transient) and typed "w".
      // In PWD mode, base is always "" because there's no retained buffer.
      processor.ctrlState = ModifierState.transient;
      final result = processor.processInput('', 'w');

      // ctrl+w must produce the control character \x17
      expect(result.modified, String.fromCharCode(0x17),
          reason: 'ctrl+w should produce \\x17, not empty string');
      expect(result.inserted, 'w');
    });

    test('key after ctrl+w should not be swallowed by stale modifiedInput', () {
      // After ctrl+w is handled (whether by key event path or processInput),
      // the very next normal key must not be eaten by a leftover modifiedInput flag.
      processor.ctrlState = ModifierState.transient;

      // Simulate ctrl+w being handled (via key event path)
      processor.clearModifiers();
      expect(processor.modifiedInput, true);

      // IME delivers "w" — consumed by modifiedInput, fine
      final r1 = processor.processInput('', 'w');
      expect(r1.modified, '');
      expect(processor.modifiedInput, false);

      // Now the user types "q" normally — this MUST produce output
      final r2 = processor.processInput('', 'q');
      expect(r2.modified, 'q',
          reason: '"q" after ctrl+w must not be swallowed');
      expect(r2.inserted, 'q');
    });

    test('three rapid IME updates for ctrl+w should not leave modifiedInput stuck', () {
      // The device log shows processInput called 3 times for the same ctrl+w,
      // all with ctrl=transient. This suggests the IME fires multiple updates
      // before the state settles. After all three, modifiedInput must be false
      // so the next key ("q") is not eaten.
      processor.ctrlState = ModifierState.transient;

      // First IME update
      final r1 = processor.processInput('', 'w');
      // At minimum, one of these calls should have produced ctrl+w
      // After this, ctrl should be cleared and modifiedInput set

      // Second IME update (ctrl re-reported as transient by framework)
      processor.ctrlState = ModifierState.transient;
      final r2 = processor.processInput('', 'w');

      // Third IME update
      processor.ctrlState = ModifierState.transient;
      final r3 = processor.processInput('', 'w');

      // At least one of the three must have produced ctrl+w
      final allModified = [r1.modified, r2.modified, r3.modified];
      expect(allModified, contains(String.fromCharCode(0x17)),
          reason: 'At least one IME update for ctrl+w must produce \\x17');

      // After all three, modifiedInput must be clear so next key works
      // (The processor should not have modifiedInput=true at this point)
      expect(processor.modifiedInput, false,
          reason: 'modifiedInput must be clear after processing completes');

      // Next normal key must work
      final r4 = processor.processInput('', 'q');
      expect(r4.modified, 'q',
          reason: '"q" after ctrl+w must not be swallowed');
    });
  });

  group('PWD mode (no commitEditingState)', () {
    test('modifiedInput is cleared by processInput, not stuck forever', () {
      // In PWD mode, commitEditingState is never called.
      // After ctrl+w via key event path, modifiedInput becomes true.
      // The next processInput must clear it so subsequent input works.
      processor.ctrlState = ModifierState.transient;
      processor.clearModifiers();
      expect(processor.modifiedInput, true);

      // First IME update — skipped, modifiedInput consumed
      final result1 = processor.processInput('', 'w');
      expect(result1.inserted, '');
      expect(result1.modified, '');
      expect(processor.modifiedInput, false);

      // Next normal input should work
      final result2 = processor.processInput('', 'hello');
      expect(result2.inserted, 'hello');
      expect(result2.modified, 'hello');
    });

    test('repeated ctrl+w in PWD mode does not accumulate stale flags', () {
      for (int i = 0; i < 3; i++) {
        processor.ctrlState = ModifierState.transient;
        processor.clearModifiers();
        expect(processor.modifiedInput, true);

        final result = processor.processInput('', 'w');
        expect(result.inserted, '');
        expect(result.modified, '');
        expect(processor.modifiedInput, false);
      }

      // Normal input still works after repeated ctrl+w
      final result = processor.processInput('', 'test');
      expect(result.inserted, 'test');
      expect(result.modified, 'test');
    });
  });
}
