import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:iroh_ssh_app/input_processor.dart';
import 'package:xterm/xterm.dart';

class ScaleAwareScrollPhysics extends ScrollPhysics {
  final ValueNotifier<bool> scaling;

  const ScaleAwareScrollPhysics(this.scaling, {super.parent});

  @override
  ScaleAwareScrollPhysics applyTo(ScrollPhysics? ancestor) {
    return ScaleAwareScrollPhysics(scaling, parent: buildParent(ancestor));
  }

  @override
  bool get allowUserScrolling => !scaling.value;
}

class TerminalPane extends StatefulWidget {
  final Terminal terminal;
  final FocusNode? focusNode;
  final bool autofocus;
  final double fontSize;
  final TerminalTheme theme;
  final ValueChanged<double>? onFontSizeChanged;
  final ValueChanged<bool>? onScalingChanged;
  final ValueChanged<double>? onVerticalScrollDelta;

  const TerminalPane({
    super.key,
    required this.terminal,
    this.focusNode,
    this.autofocus = false,
    this.fontSize = 14.0,
    this.theme = TerminalThemes.defaultTheme,
    this.onFontSizeChanged,
    this.onScalingChanged,
    this.onVerticalScrollDelta,
  });

  @override
  State<TerminalPane> createState() => TerminalPaneState();
}

class TerminalPaneState extends State<TerminalPane> with SingleTickerProviderStateMixin {
  late FocusNode _focusNode;
  final _input = InputProcessor();
  double? _terminalHeight;
  late double _currentFontSize;
  double _baseScaleFontSize = 0;
  bool _isScaling = false;
  bool _wasKeyboardOpenBeforeScale = false;
  final _pointerPositions = <int, Offset>{};
  double? _initialPointerDistance;
  int? _scrollPointerId;
  double? _scrollPointerStartY;
  double _scrollStartOffset = 0;
  double? _lastScrollPointerY;
  VelocityTracker? _velocityTracker;
  AnimationController? _flingController;
  final ScrollController _scrollController = ScrollController();
  final ValueNotifier<bool> scalingNotifier = ValueNotifier(false);
  bool _keyboardOpen = false;
  int _fnPage = 0;
  Timer? _repeatTimer;
  bool _userTouching = false;
  Timer? _scrollCorrectionDebounce;
  int _lastCursorAbsY = -1;
  bool _glideTyping = false;

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
    _flingController = AnimationController.unbounded(vsync: this);
    _flingController!.addListener(_onFlingTick);
    widget.terminal.addListener(_onTerminalChange);
  }

  void _onFlingTick() {
    if (_scrollController.hasClients) {
      final target = _flingController!.value.clamp(
        0.0,
        _scrollController.position.maxScrollExtent,
      );
      _scrollController.jumpTo(target);
    }
  }

  void _startFling() {
    if (_velocityTracker == null || !_scrollController.hasClients) return;
    final estimate = _velocityTracker!.getVelocityEstimate();
    _velocityTracker = null;
    if (estimate == null) return;
    final pixelsPerSecond = -estimate.pixelsPerSecond.dy;
    if (pixelsPerSecond.abs() < 50) return;
    final position = _scrollController.offset;
    final simulation = ClampingScrollSimulation(
      position: position,
      velocity: pixelsPerSecond,
    );
    _flingController!.animateWith(simulation);
  }

  void _onTerminalChange() {
    if (!_keyboardOpen) return;
    if (_terminalHeight == null) return;
    if (_userTouching) return;

    final viewHeight = widget.terminal.viewHeight;
    if (viewHeight <= 0) return;
    final scrollBack = widget.terminal.buffer.lines.length - viewHeight;
    final cursorAbsY =
        widget.terminal.buffer.cursorY + (scrollBack > 0 ? scrollBack : 0);
    if (cursorAbsY == _lastCursorAbsY) return;

    _debouncedScrollCorrection();
  }

  static const _scrollCorrectionDelay = Duration(milliseconds: 16);

  void _debouncedScrollCorrection() {
    if (_scrollCorrectionDebounce == null) {
      _applyScrollCorrection();
    }
    _scrollCorrectionDebounce?.cancel();
    _scrollCorrectionDebounce = Timer(_scrollCorrectionDelay, () {
      _scrollCorrectionDebounce = null;
      _applyScrollCorrection();
    });
  }

  void _applyScrollCorrection() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!_keyboardOpen) return;
      if (_userTouching) return;
      if (!_scrollController.hasClients) return;
      final viewHeight = widget.terminal.viewHeight;
      if (viewHeight <= 0) return;
      final cellHeight = _terminalHeight! / viewHeight;
      final scrollBack =
          widget.terminal.buffer.lines.length - viewHeight;
      final cursorAbsY =
          widget.terminal.buffer.cursorY + (scrollBack > 0 ? scrollBack : 0);
      _lastCursorAbsY = cursorAbsY;
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

  void _scheduleScrollCorrection() {
    _debouncedScrollCorrection();
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
    _scrollCorrectionDebounce?.cancel();
    _flingController?.dispose();
    widget.terminal.removeListener(_onTerminalChange);
    scalingNotifier.dispose();
    _scrollController.dispose();
    if (widget.focusNode == null) {
      _focusNode.dispose();
    }
    super.dispose();
  }

  String applyModifiers(String data) => _input.applyModifiers(data);

  bool get ctrlActive => _input.ctrlActive;

  bool get altActive => _input.altActive;

  bool get shiftActive => _input.shiftActive;

  void clearModifiers() {
    _input.clearModifiers();
    setState(() {});
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

  void _onInput(TextEditingValue baseState, TextEditingValue currentState) {
    final result = _input.processInput(baseState.text, currentState.text);
    for (int i = 0; i < result.deletions; i++) {
      widget.terminal.keyInput(TerminalKey.backspace);
    }
    if (result.modified.isNotEmpty) {
      widget.terminal.textInput(result.modified);
      setState(() {});
    }
  }

  TextEditingValue? _onCommitEditingState(TextEditingValue committed) {
    return _input.commitEditingState(committed);
  }

  static const double _toolbarHeight = 64;
  static const int _fnPageCount = 2;

  void _cycleModifier(
    ModifierState current,
    void Function(ModifierState) setter,
  ) {
    _input.cycleModifier(current, setter);
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
        _repeatableToolbarButton('INS', () => _sendKey(TerminalKey.insert)),
      ];
    }
    return [
      _toolbarButton('ESC', () => _sendKey(TerminalKey.escape)),
      _modifierButton('SHIFT', _input.shiftState, () {
        setState(() => _cycleModifier(_input.shiftState, (s) => _input.shiftState = s));
      }),
      _modifierButton('PWD', _glideTyping ? ModifierState.off : ModifierState.locked, () {
        setState(() => _glideTyping = !_glideTyping);
      }),
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
        _repeatableToolbarButton('DEL', () => _sendKey(TerminalKey.delete)),
      ];
    }
    return [
      _toolbarButton('TAB', () => _sendKey(TerminalKey.tab)),
      _modifierButton('CTRL', _input.ctrlState, () {
        setState(() => _cycleModifier(_input.ctrlState, (s) => _input.ctrlState = s));
      }),
      _modifierButton('ALT', _input.altState, () {
        setState(() => _cycleModifier(_input.altState, (s) => _input.altState = s));
      }),
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
                  onPointerSignal: (event) {
                    if (event is PointerScrollEvent) {
                      final viewHeight = widget.terminal.viewHeight;
                      final cellHeight = viewHeight > 0 && _terminalHeight != null
                          ? _terminalHeight! / viewHeight
                          : _currentFontSize * 1.2;
                      final lines = 3;
                      final delta = event.scrollDelta.dy.sign * cellHeight * lines;
                      if (_scrollController.hasClients) {
                        final target =
                            (_scrollController.offset + delta).clamp(
                          0.0,
                          _scrollController.position.maxScrollExtent,
                        );
                        _scrollController.jumpTo(target);
                      }
                      widget.onVerticalScrollDelta?.call(delta);
                    }
                  },
                  onPointerDown: (event) {
                    _pointerPositions[event.pointer] = event.position;
                    _userTouching = true;
                    _flingController?.stop();
                    if (_pointerPositions.length == 1) {
                      _scrollPointerId = event.pointer;
                      _scrollPointerStartY = event.position.dy;
                      _scrollStartOffset = _scrollController.hasClients
                          ? _scrollController.offset
                          : 0;
                      _velocityTracker = VelocityTracker.withKind(event.kind);
                      _velocityTracker!.addPosition(event.timeStamp, event.position);
                      _lastScrollPointerY = event.position.dy;
                    }
                    if (_pointerPositions.length >= 2 && !_isScaling) {
                      _isScaling = true;
                      _scrollPointerId = null;
                      _velocityTracker = null;
                      _wasKeyboardOpenBeforeScale = keyboardOpen;
                      _baseScaleFontSize = _currentFontSize;
                      final positions = _pointerPositions.values.toList();
                      _initialPointerDistance = (positions[0] - positions[1]).distance;
                      scalingNotifier.value = true;
                      _focusNode.unfocus();
                      _focusNode.canRequestFocus = false;
                      widget.onScalingChanged?.call(true);
                    }
                  },
                  onPointerMove: (event) {
                    _pointerPositions[event.pointer] = event.position;
                    if (_isScaling && _pointerPositions.length >= 2 && _initialPointerDistance != null && _initialPointerDistance! > 0) {
                      final positions = _pointerPositions.values.toList();
                      final currentDistance = (positions[0] - positions[1]).distance;
                      final scale = currentDistance / _initialPointerDistance!;
                      final newSize = (_baseScaleFontSize * scale)
                          .clamp(8.0, 24.0)
                          .roundToDouble();
                      if (newSize != _currentFontSize) {
                        setState(() => _currentFontSize = newSize);
                        widget.onFontSizeChanged?.call(newSize);
                      }
                    } else if (!_isScaling && _scrollPointerId == event.pointer && _scrollPointerStartY != null) {
                      _velocityTracker?.addPosition(event.timeStamp, event.position);
                      if (_scrollController.hasClients) {
                        final dy = _scrollPointerStartY! - event.position.dy;
                        final target = (_scrollStartOffset + dy).clamp(
                          0.0,
                          _scrollController.position.maxScrollExtent,
                        );
                        _scrollController.jumpTo(target);
                      }
                      if (_lastScrollPointerY != null) {
                        final delta = _lastScrollPointerY! - event.position.dy;
                        if (delta.abs() > 1.0) {
                          widget.onVerticalScrollDelta?.call(delta);
                          _lastScrollPointerY = event.position.dy;
                        }
                      } else {
                        _lastScrollPointerY = event.position.dy;
                      }
                    }
                  },
                  onPointerUp: (event) {
                    _pointerPositions.remove(event.pointer);
                    if (_pointerPositions.isEmpty) {
                      _userTouching = false;
                    }
                    if (event.pointer == _scrollPointerId) {
                      _startFling();
                      _scrollPointerId = null;
                      _lastScrollPointerY = null;
                    }
                    if (_pointerPositions.length < 2 && _isScaling) {
                      _isScaling = false;
                      _initialPointerDistance = null;
                      scalingNotifier.value = false;
                      _focusNode.canRequestFocus = true;
                      if (_wasKeyboardOpenBeforeScale) {
                        _focusNode.requestFocus();
                      }
                      widget.onScalingChanged?.call(false);
                    }
                  },
                  onPointerCancel: (event) {
                    _pointerPositions.remove(event.pointer);
                    if (_pointerPositions.isEmpty) {
                      _userTouching = false;
                    }
                    if (event.pointer == _scrollPointerId) {
                      _scrollPointerId = null;
                    }
                    if (_pointerPositions.length < 2 && _isScaling) {
                      _isScaling = false;
                      _initialPointerDistance = null;
                      scalingNotifier.value = false;
                      _focusNode.canRequestFocus = true;
                      if (_wasKeyboardOpenBeforeScale) {
                        _focusNode.requestFocus();
                      }
                      widget.onScalingChanged?.call(false);
                    }
                  },
                  child: TerminalView(
                    widget.terminal,
                    focusNode: _focusNode,
                    autofocus: widget.autofocus,
                    autoResize: !keyboardOpen,
                    scrollOnInput: !keyboardOpen,
                    scrollController: _scrollController,
                    scrollPhysics: const NeverScrollableScrollPhysics(),
                    onCommitEditingState: _glideTyping ? _onCommitEditingState : null,
                    onInput: _onInput,
                    keyboardType: _glideTyping ? TextInputType.emailAddress : TextInputType.visiblePassword,
                    theme: widget.theme,
                    textStyle: TerminalStyle(
                      fontSize: _currentFontSize,
                      fontFamilyFallback: const [
                        'Menlo',
                        'Monaco',
                        'Consolas',
                        'Liberation Mono',
                        'Courier New',
                        'Noto Sans Mono CJK SC',
                        'Noto Sans Mono CJK TC',
                        'Noto Sans Mono CJK KR',
                        'Noto Sans Mono CJK JP',
                        'Noto Sans Mono CJK HK',
                        'Noto Color Emoji',
                        'Noto Sans Symbols',
                        'NotoSansSymbols2',
                        'monospace',
                        'sans-serif',
                      ],
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
