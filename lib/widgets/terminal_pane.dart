import 'dart:async';

import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

enum ModifierState { off, transient, locked }

class TerminalPane extends StatefulWidget {
  final Terminal terminal;
  final FocusNode? focusNode;
  final bool autofocus;
  final double fontSize;
  final TerminalTheme theme;
  final ValueChanged<double>? onFontSizeChanged;

  const TerminalPane({
    super.key,
    required this.terminal,
    this.focusNode,
    this.autofocus = false,
    this.fontSize = 14.0,
    this.theme = TerminalThemes.defaultTheme,
    this.onFontSizeChanged,
  });

  @override
  State<TerminalPane> createState() => TerminalPaneState();
}

class TerminalPaneState extends State<TerminalPane> {
  late FocusNode _focusNode;
  ModifierState _ctrlState = ModifierState.off;
  ModifierState _altState = ModifierState.off;
  ModifierState _shiftState = ModifierState.off;
  double? _terminalHeight;
  late double _currentFontSize;
  double _baseScaleFontSize = 0;
  bool _isScaling = false;
  bool _wasKeyboardOpenBeforeScale = false;
  final _activePointers = <int>{};
  final ScrollController _scrollController = ScrollController();
  bool _keyboardOpen = false;
  int _fnPage = 0;
  Timer? _repeatTimer;

  void requestFocus() {
    _focusNode.requestFocus();
  }

  void disableFocus() {
    _focusNode.unfocus();
    _focusNode.canRequestFocus = false;
  }

  void enableFocus() {
    _focusNode.canRequestFocus = true;
  }

  @override
  void initState() {
    super.initState();
    _currentFontSize = widget.fontSize;
    _focusNode = widget.focusNode ?? FocusNode();
    widget.terminal.addListener(_onTerminalChange);
  }

  void _onTerminalChange() {
    if (!_keyboardOpen) return;
    if (_terminalHeight == null) return;
    _scheduleScrollCorrection();
  }

  void _scheduleScrollCorrection() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!_keyboardOpen) return;
      if (!_scrollController.hasClients) return;
      final viewHeight = widget.terminal.viewHeight;
      if (viewHeight <= 0) return;
      final cellHeight = _terminalHeight! / viewHeight;
      final scrollBack =
          widget.terminal.buffer.lines.length - viewHeight;
      final cursorAbsY =
          widget.terminal.buffer.cursorY + (scrollBack > 0 ? scrollBack : 0);
      final viewportHeight = _scrollController.position.viewportDimension;
      final cursorBottom = (cursorAbsY + 1) * cellHeight;
      final target = (cursorBottom - viewportHeight).clamp(
        0.0,
        _scrollController.position.maxScrollExtent,
      );
      if ((_scrollController.offset - target).abs() > 1.0) {
        _scrollController.jumpTo(target);
      }
    });
  }

  @override
  void didUpdateWidget(TerminalPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.terminal != oldWidget.terminal) {
      oldWidget.terminal.removeListener(_onTerminalChange);
      widget.terminal.addListener(_onTerminalChange);
    }
    if (widget.focusNode != oldWidget.focusNode) {
      if (oldWidget.focusNode == null) {
        _focusNode.dispose();
      }
      _focusNode = widget.focusNode ?? FocusNode();
    }
    if (widget.fontSize != oldWidget.fontSize) {
      _currentFontSize = widget.fontSize;
    }
  }

  @override
  void dispose() {
    _repeatTimer?.cancel();
    widget.terminal.removeListener(_onTerminalChange);
    _scrollController.dispose();
    if (widget.focusNode == null) {
      _focusNode.dispose();
    }
    super.dispose();
  }

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

  bool get ctrlActive =>
      _ctrlState == ModifierState.transient ||
      _ctrlState == ModifierState.locked;

  bool get altActive =>
      _altState == ModifierState.transient ||
      _altState == ModifierState.locked;

  bool get shiftActive =>
      _shiftState == ModifierState.transient ||
      _shiftState == ModifierState.locked;

  void clearModifiers() {
    if (_ctrlState == ModifierState.transient) {
      setState(() => _ctrlState = ModifierState.off);
    }
    if (_altState == ModifierState.transient) {
      setState(() => _altState = ModifierState.off);
    }
    if (_shiftState == ModifierState.transient) {
      setState(() => _shiftState = ModifierState.off);
    }
  }

  void _sendKey(TerminalKey key) {
    widget.terminal.keyInput(
      key,
      ctrl: ctrlActive,
      alt: altActive,
      shift: shiftActive,
    );
    clearModifiers();
  }

  static const double _toolbarHeight = 64;
  static const int _fnPageCount = 2;

  void _cycleModifier(
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

  Widget _buildToolbar() {
    return GestureDetector(
      onVerticalDragEnd: (details) {
        if (details.primaryVelocity == null) return;
        if (details.primaryVelocity! < -100) {
          setState(() => _fnPage = (_fnPage + 1) % _fnPageCount);
        } else if (details.primaryVelocity! > 100) {
          setState(
            () => _fnPage = (_fnPage - 1 + _fnPageCount) % _fnPageCount,
          );
        }
      },
      child: Container(
        color: const Color(0xFF1E1E1E),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(children: _buildRow1()),
            Row(children: _buildRow2()),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildRow1() {
    if (_fnPage == 1) {
      return [
        _toolbarButton('F1', () => _sendKey(TerminalKey.f1)),
        _toolbarButton('F2', () => _sendKey(TerminalKey.f2)),
        _toolbarButton('F3', () => _sendKey(TerminalKey.f3)),
        _toolbarButton('F4', () => _sendKey(TerminalKey.f4)),
        _toolbarButton('F5', () => _sendKey(TerminalKey.f5)),
        _toolbarButton('F6', () => _sendKey(TerminalKey.f6)),
        _toolbarButton('', null),
        _repeatableToolbarButton('INS', () => _sendKey(TerminalKey.insert)),
      ];
    }
    return [
      _toolbarButton('ESC', () => _sendKey(TerminalKey.escape)),
      _modifierButton('SHIFT', _shiftState, () {
        setState(() => _cycleModifier(_shiftState, (s) => _shiftState = s));
      }),
      _toolbarButton('', null),
      _toolbarButton('', null),
      _repeatableToolbarButton('HOME', () => _sendKey(TerminalKey.home)),
      _repeatableToolbarButton('↑', () => _sendKey(TerminalKey.arrowUp)),
      _repeatableToolbarButton('END', () => _sendKey(TerminalKey.end)),
      _repeatableToolbarButton('PGUP', () => _sendKey(TerminalKey.pageUp)),
    ];
  }

  List<Widget> _buildRow2() {
    if (_fnPage == 1) {
      return [
        _toolbarButton('F7', () => _sendKey(TerminalKey.f7)),
        _toolbarButton('F8', () => _sendKey(TerminalKey.f8)),
        _toolbarButton('F9', () => _sendKey(TerminalKey.f9)),
        _toolbarButton('F10', () => _sendKey(TerminalKey.f10)),
        _toolbarButton('F11', () => _sendKey(TerminalKey.f11)),
        _toolbarButton('F12', () => _sendKey(TerminalKey.f12)),
        _toolbarButton('', null),
        _repeatableToolbarButton('DEL', () => _sendKey(TerminalKey.delete)),
      ];
    }
    return [
      _toolbarButton('TAB', () => _sendKey(TerminalKey.tab)),
      _modifierButton('CTRL', _ctrlState, () {
        setState(() => _cycleModifier(_ctrlState, (s) => _ctrlState = s));
      }),
      _modifierButton('ALT', _altState, () {
        setState(() => _cycleModifier(_altState, (s) => _altState = s));
      }),
      _toolbarButton('', null),
      _repeatableToolbarButton('←', () => _sendKey(TerminalKey.arrowLeft)),
      _repeatableToolbarButton('↓', () => _sendKey(TerminalKey.arrowDown)),
      _repeatableToolbarButton('→', () => _sendKey(TerminalKey.arrowRight)),
      _repeatableToolbarButton(
        'PGDN',
        () => _sendKey(TerminalKey.pageDown),
      ),
    ];
  }

  Widget _toolbarButton(String label, VoidCallback? onPressed) {
    return Expanded(
      child: SizedBox(
        height: 32,
        child: MaterialButton(
          minWidth: 0,
          height: 32,
          padding: EdgeInsets.zero,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          shape: const RoundedRectangleBorder(),
          color: const Color(0xFF2D2D2D),
          elevation: 0,
          onPressed: onPressed,
          child: Text(
            label,
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
        ),
      ),
    );
  }

  Widget _repeatableToolbarButton(String label, VoidCallback onPressed) {
    return Expanded(
      child: GestureDetector(
        onTap: onPressed,
        onLongPressStart: (_) {
          onPressed();
          _repeatTimer = Timer.periodic(
            const Duration(milliseconds: 50),
            (_) => onPressed(),
          );
        },
        onLongPressEnd: (_) {
          _repeatTimer?.cancel();
          _repeatTimer = null;
        },
        child: SizedBox(
          height: 32,
          child: Container(
            color: const Color(0xFF2D2D2D),
            alignment: Alignment.center,
            child: Text(
              label,
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ),
        ),
      ),
    );
  }

  Widget _modifierButton(
    String label,
    ModifierState state,
    VoidCallback onPressed,
  ) {
    final isActive = state != ModifierState.off;
    final isLocked = state == ModifierState.locked;
    return Expanded(
      child: SizedBox(
        height: 32,
        child: MaterialButton(
          minWidth: 0,
          height: 32,
          padding: EdgeInsets.zero,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          shape: const RoundedRectangleBorder(),
          color: isActive ? Colors.blueGrey : const Color(0xFF2D2D2D),
          elevation: 0,
          onPressed: onPressed,
          child: Text(
            label,
            style: TextStyle(
              color: isActive ? Colors.white : Colors.white70,
              fontSize: 12,
              fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
              decoration: isLocked ? TextDecoration.underline : null,
              decorationColor: Colors.white,
            ),
          ),
        ),
      ),
    );
  }


  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final keyboardHeight = mediaQuery.viewInsets.bottom;
    final keyboardOpen = keyboardHeight > 0;
    final wasKeyboardOpen = _keyboardOpen;
    _keyboardOpen = keyboardOpen;
    if (keyboardOpen) {
      if (!wasKeyboardOpen && _scrollController.hasClients) {
        _scrollController.jumpTo(0);
      }
      _scheduleScrollCorrection();
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final toolbarHeight = keyboardOpen ? _toolbarHeight : 0.0;
        if (!keyboardOpen) {
          _terminalHeight = constraints.maxHeight;
        }
        final terminalHeight = keyboardOpen
            ? constraints.maxHeight - keyboardHeight - toolbarHeight
            : (_terminalHeight ?? constraints.maxHeight);
        return Column(
          children: [
            SizedBox(
              height: terminalHeight,
              child: MediaQuery.removePadding(
                context: context,
                removeTop: true,
                removeBottom: true,
                child: Listener(
                  onPointerDown: (event) {
                    _activePointers.add(event.pointer);
                    if (_activePointers.length >= 2 && !_isScaling) {
                      _isScaling = true;
                      _wasKeyboardOpenBeforeScale = keyboardOpen;
                      _focusNode.unfocus();
                      _focusNode.canRequestFocus = false;
                    }
                  },
                  onPointerUp: (event) {
                    _activePointers.remove(event.pointer);
                    if (_activePointers.isEmpty && _isScaling) {
                      _focusNode.canRequestFocus = true;
                      if (_wasKeyboardOpenBeforeScale) {
                        _focusNode.requestFocus();
                      }
                      _isScaling = false;
                    }
                  },
                  onPointerCancel: (event) {
                    _activePointers.remove(event.pointer);
                    if (_activePointers.isEmpty && _isScaling) {
                      _focusNode.canRequestFocus = true;
                      if (_wasKeyboardOpenBeforeScale) {
                        _focusNode.requestFocus();
                      }
                      _isScaling = false;
                    }
                  },
                  child: GestureDetector(
                    onScaleStart: (_) {
                      _baseScaleFontSize = _currentFontSize;
                    },
                    onScaleUpdate: (details) {
                      if (details.pointerCount < 2) return;
                      final newSize = (_baseScaleFontSize * details.scale)
                          .clamp(8.0, 24.0)
                          .roundToDouble();
                      if (newSize != _currentFontSize) {
                        setState(() => _currentFontSize = newSize);
                        widget.onFontSizeChanged?.call(newSize);
                      }
                    },
                    child: TerminalView(
                      widget.terminal,
                      focusNode: _focusNode,
                      autofocus: widget.autofocus,
                      autoResize: !keyboardOpen,
                      scrollController: _scrollController,
                      theme: widget.theme,
                      textStyle:
                          TerminalStyle(fontSize: _currentFontSize),
                    ),
                  ),
                ),
              ),
            ),
            if (keyboardOpen) _buildToolbar(),
          ],
        );
      },
    );
  }
}
