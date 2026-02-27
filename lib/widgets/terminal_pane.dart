import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

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
  bool _ctrlActive = false;
  bool _altActive = false;
  double? _terminalHeight;
  int? _savedViewWidth;
  int? _savedViewHeight;
  late double _currentFontSize;
  double _baseScaleFontSize = 0;
  bool _isScaling = false;
  bool _wasKeyboardOpenBeforeScale = false;
  final _activePointers = <int>{};
  final ScrollController _scrollController = ScrollController();
  bool _keyboardOpen = false;

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
      if (_ctrlActive && char >= 0x61 && char <= 0x7a) {
        buf.writeCharCode(char - 0x60);
      } else if (_ctrlActive && char >= 0x41 && char <= 0x5a) {
        buf.writeCharCode(char - 0x40);
      } else if (_altActive) {
        buf.writeCharCode(0x1b);
        buf.writeCharCode(char);
      } else {
        buf.writeCharCode(char);
      }
    }
    return buf.toString();
  }

  bool get ctrlActive => _ctrlActive;
  bool get altActive => _altActive;

  void clearModifiers() {
    if (_ctrlActive) setState(() => _ctrlActive = false);
    if (_altActive) setState(() => _altActive = false);
  }

  void _sendKey(TerminalKey key) {
    widget.terminal.keyInput(key, ctrl: _ctrlActive, alt: _altActive);
    if (_ctrlActive) setState(() => _ctrlActive = false);
    if (_altActive) setState(() => _altActive = false);
  }

  static const double _toolbarHeight = 64;

  void _sendChar(String char) {
    widget.terminal.textInput(char);
  }

  Widget _buildToolbar() {
    return Container(
      color: const Color(0xFF1E1E1E),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              _toolbarButton('ESC', () => _sendKey(TerminalKey.escape)),
              _toolbarButton('/', () => _sendChar('/')),
              _toolbarButton('-', () => _sendChar('-')),
              _toolbarButton('HOME', () => _sendKey(TerminalKey.home)),
              _toolbarButton('↑', () => _sendKey(TerminalKey.arrowUp)),
              _toolbarButton('END', () => _sendKey(TerminalKey.end)),
              _toolbarButton('PGUP', () => _sendKey(TerminalKey.pageUp)),
            ],
          ),
          Row(
            children: [
              _toolbarButton('TAB', () => _sendKey(TerminalKey.tab)),
              _toolbarToggle('CTRL', _ctrlActive, () {
                setState(() => _ctrlActive = !_ctrlActive);
              }),
              _toolbarToggle('ALT', _altActive, () {
                setState(() => _altActive = !_altActive);
              }),
              _toolbarButton('←', () => _sendKey(TerminalKey.arrowLeft)),
              _toolbarButton('↓', () => _sendKey(TerminalKey.arrowDown)),
              _toolbarButton('→', () => _sendKey(TerminalKey.arrowRight)),
              _toolbarButton('PGDN', () => _sendKey(TerminalKey.pageDown)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _toolbarButton(String label, VoidCallback onPressed) {
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

  Widget _toolbarToggle(String label, bool active, VoidCallback onPressed) {
    return Expanded(
      child: SizedBox(
        height: 32,
        child: MaterialButton(
          minWidth: 0,
          height: 32,
          padding: EdgeInsets.zero,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          shape: const RoundedRectangleBorder(),
          color: active ? Colors.blueGrey : const Color(0xFF2D2D2D),
          elevation: 0,
          onPressed: onPressed,
          child: Text(
            label,
            style: TextStyle(
              color: active ? Colors.white : Colors.white70,
              fontSize: 12,
              fontWeight: active ? FontWeight.bold : FontWeight.normal,
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
          _savedViewWidth = widget.terminal.viewWidth;
          _savedViewHeight = widget.terminal.viewHeight;
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
