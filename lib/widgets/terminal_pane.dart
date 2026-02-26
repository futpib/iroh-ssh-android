import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
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
  late double _currentFontSize;
  double _baseScaleFontSize = 0;

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
    if (kDebugMode) {
      SchedulerBinding.instance.addTimingsCallback(_onFrameTimings);
    }
  }

  @override
  void didUpdateWidget(TerminalPane oldWidget) {
    super.didUpdateWidget(oldWidget);
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
    if (kDebugMode) {
      SchedulerBinding.instance.removeTimingsCallback(_onFrameTimings);
    }
    if (widget.focusNode == null) {
      _focusNode.dispose();
    }
    super.dispose();
  }

  void _onFrameTimings(List<FrameTiming> timings) {
    for (final t in timings) {
      final buildMs = t.buildDuration.inMilliseconds;
      final rasterMs = t.rasterDuration.inMilliseconds;
      final totalMs = t.totalSpan.inMilliseconds;
      if (totalMs > 4) {
        debugPrint(
            '[ssh-perf][frame] build: ${buildMs}ms, raster: ${rasterMs}ms, total: ${totalMs}ms');
      }
    }
  }

  KeyEventResult _onKeyEventPerf(FocusNode node, KeyEvent event) {
    return KeyEventResult.ignored;
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
    return LayoutBuilder(
      builder: (context, constraints) {
        final toolbarHeight = keyboardOpen ? _toolbarHeight : 0.0;
        if (!keyboardOpen) {
          _terminalHeight = constraints.maxHeight;
        }
        final terminalHeight =
            _terminalHeight ?? constraints.maxHeight - toolbarHeight;
        if (kDebugMode) {
          debugPrint('[layout] keyboardOpen=$keyboardOpen, '
              'keyboardHeight=$keyboardHeight, '
              'constraints=${constraints.maxHeight}, '
              '_terminalHeight=$_terminalHeight, '
              'terminalHeight=$terminalHeight, '
              'toolbarHeight=$toolbarHeight, '
              'total=${terminalHeight + toolbarHeight}, '
              'viewWidth=${widget.terminal.viewWidth}, '
              'viewHeight=${widget.terminal.viewHeight}');
        }
        final slideUp = keyboardOpen
            ? keyboardHeight +
                toolbarHeight -
                (constraints.maxHeight - terminalHeight)
            : 0.0;
        return Stack(
          children: [
            Transform.translate(
              offset: Offset(0, -slideUp),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    height: terminalHeight,
                    child: MediaQuery.removePadding(
                      context: context,
                      removeTop: true,
                      removeBottom: true,
                      child: GestureDetector(
                        onScaleStart: (_) {
                          _baseScaleFontSize = _currentFontSize;
                        },
                        onScaleUpdate: (details) {
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
                          onKeyEvent: kDebugMode ? _onKeyEventPerf : null,
                          theme: widget.theme,
                          textStyle:
                              TerminalStyle(fontSize: _currentFontSize),
                        ),
                      ),
                    ),
                  ),
                  if (keyboardOpen) _buildToolbar(),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}
