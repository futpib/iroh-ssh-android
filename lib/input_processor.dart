import 'package:flutter/material.dart';

enum ModifierState { off, transient, locked }

class InputResult {
  final int deletions;
  final String inserted;
  final String modified;

  const InputResult({
    required this.deletions,
    required this.inserted,
    required this.modified,
  });
}

class InputProcessor {
  ModifierState ctrlState = ModifierState.off;
  ModifierState altState = ModifierState.off;
  ModifierState shiftState = ModifierState.off;
  bool modifiedInput = false;
  bool _rejectCommit = false;

  static const int maxRetainedLength = 50;

  bool get ctrlActive =>
      ctrlState == ModifierState.transient ||
      ctrlState == ModifierState.locked;

  bool get altActive =>
      altState == ModifierState.transient ||
      altState == ModifierState.locked;

  bool get shiftActive =>
      shiftState == ModifierState.transient ||
      shiftState == ModifierState.locked;

  String applyModifiers(String data) {
    final buf = StringBuffer();
    for (final char in data.codeUnits) {
      if (ctrlActive && char >= 0x61 && char <= 0x7a) {
        buf.writeCharCode(char - 0x60);
      } else if (ctrlActive && char >= 0x41 && char <= 0x5a) {
        buf.writeCharCode(char - 0x40);
      } else if (altActive) {
        buf.writeCharCode(0x1b);
        if (shiftActive) {
          buf.writeCharCode(
            (char >= 0x61 && char <= 0x7a) ? char - 0x20 : char,
          );
        } else {
          buf.writeCharCode(char);
        }
      } else if (shiftActive) {
        buf.writeCharCode(
          (char >= 0x61 && char <= 0x7a) ? char - 0x20 : char,
        );
      } else {
        buf.writeCharCode(char);
      }
    }
    return buf.toString();
  }

  void _resetTransientModifiers() {
    if (ctrlState == ModifierState.transient) {
      ctrlState = ModifierState.off;
    }
    if (altState == ModifierState.transient) {
      altState = ModifierState.off;
    }
    if (shiftState == ModifierState.transient) {
      shiftState = ModifierState.off;
    }
  }

  void clearModifiers() {
    if (ctrlState == ModifierState.transient ||
        altState == ModifierState.transient) {
      modifiedInput = true;
    }
    _resetTransientModifiers();
  }

  void cycleModifier(
    ModifierState current,
    void Function(ModifierState) setter,
  ) {
    switch (current) {
      case ModifierState.off:
        setter(ModifierState.transient);
      case ModifierState.transient:
        setter(ModifierState.locked);
      case ModifierState.locked:
        setter(ModifierState.off);
    }
  }

  static const _emptyResult = InputResult(
    deletions: 0,
    inserted: '',
    modified: '',
  );

  InputResult processInput(String baseText, String currentText) {
    if (modifiedInput) {
      // The key event path already handled this input (e.g. ctrl+w was
      // sent via terminal.keyInput). Ignore the IME update to avoid
      // sending duplicate input.
      modifiedInput = false;
      return _emptyResult;
    }
    if (ctrlActive || altActive) {
      // When ctrl/alt is active, ignore the IME diff and extract only the
      // key the user actually pressed. Gboard may prepend auto-space or
      // other context that should not be sent as modified input.
      // Look at the last character of currentText as the key pressed,
      // regardless of base length (handles stale base case).
      final key = currentText.isNotEmpty
          ? currentText[currentText.length - 1]
          : '';
      final modified = key.isNotEmpty ? applyModifiers(key) : '';
      if (modified.isNotEmpty) {
        // processInput handled the modified key itself, so just reset
        // transient modifiers without setting modifiedInput. The
        // modifiedInput flag is only for the key-event path (external
        // to processInput) to signal "I already sent this, skip IME".
        _resetTransientModifiers();
        _rejectCommit = true;
      }
      return InputResult(
        deletions: 0,
        inserted: key,
        modified: modified,
      );
    }
    int common = 0;
    while (common < baseText.length &&
        common < currentText.length &&
        baseText[common] == currentText[common]) {
      common++;
    }
    final deletions = baseText.length - common;
    final inserted =
        currentText.length > common ? currentText.substring(common) : '';
    final modified = inserted.isNotEmpty ? applyModifiers(inserted) : '';
    if (modified.isNotEmpty) {
      _resetTransientModifiers();
    }
    return InputResult(
      deletions: deletions,
      inserted: inserted,
      modified: modified,
    );
  }

  TextEditingValue? commitEditingState(TextEditingValue committed) {
    if (ctrlActive || altActive || modifiedInput || _rejectCommit) {
      modifiedInput = false;
      _rejectCommit = false;
      return null;
    }
    var text = committed.text;
    if (text.length > maxRetainedLength) {
      final lastSpace = text.lastIndexOf(' ', text.length - 1);
      if (lastSpace > text.length - maxRetainedLength) {
        text = text.substring(lastSpace + 1);
      } else {
        text = text.substring(text.length - maxRetainedLength);
      }
    }
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }
}
