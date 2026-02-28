import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_pty/flutter_pty.dart';
import 'package:iroh_ssh_app/models/connection_type.dart';
import 'package:iroh_ssh_app/models/ssh_session_info.dart';
import 'package:iroh_ssh_app/services/key_storage.dart';
import 'package:iroh_ssh_app/services/session_messages.dart';
import 'package:iroh_ssh_app/src/rust/api/simple.dart';
import 'package:iroh_ssh_app/widgets/terminal_pane.dart';
import 'package:xterm/xterm.dart';

class TerminalTab extends StatefulWidget {
  final SshSessionInfo session;
  final VoidCallback onDisconnected;
  final double fontSize;
  final String themeName;
  final ValueChanged<bool>? onScalingChanged;

  @visibleForTesting
  final bool connectOnInit;

  const TerminalTab({
    super.key,
    required this.session,
    required this.onDisconnected,
    this.fontSize = 14.0,
    this.themeName = 'default',
    this.connectOnInit = true,
    this.onScalingChanged,
  });

  @override
  State<TerminalTab> createState() => TerminalTabState();
}

class TerminalTabState extends State<TerminalTab>
    with AutomaticKeepAliveClientMixin {
  static final bool _isAndroid = Platform.isAndroid;

  final _terminal = Terminal(maxLines: 10000);
  final _paneKey = GlobalKey<TerminalPaneState>();
  bool _connected = false;
  bool _authFailed = false;
  late double _fontSize;

  // --- IPC mode (Android) ---
  void Function(Object)? _serviceDataCallback;
  Completer<String>? _ipcAuthCompleter;
  StringBuffer _ipcAuthBuffer = StringBuffer();
  bool _ipcAuthEcho = true;
  bool _replayReceived = false;

  // --- Direct mode (non-Android) ---
  SSHClient? _client;
  SSHSession? _session;
  Pty? _pty;
  StreamSubscription? _ptyOutputSubscription;
  Completer<String>? _inputCompleter;
  StringBuffer _inputBuffer = StringBuffer();
  bool _inputEcho = true;
  static const _batchDuration = Duration(milliseconds: 2);
  final _stdoutBuffer = BytesBuilder(copy: false);
  Timer? _stdoutFlushTimer;
  final _stderrBuffer = BytesBuilder(copy: false);
  Timer? _stderrFlushTimer;

  bool get connected => _connected;

  void requestFocus() {
    _paneKey.currentState?.requestFocus();
  }

  void disableFocus() {
    _paneKey.currentState?.disableFocus();
  }

  void enableFocus() {
    _paneKey.currentState?.enableFocus();
  }

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _fontSize = widget.fontSize;
    if (widget.connectOnInit) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_isAndroid) {
          _attachToService();
        } else {
          _connectDirect();
        }
      });
    }
  }

  @override
  void didUpdateWidget(TerminalTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.fontSize != oldWidget.fontSize) {
      _fontSize = widget.fontSize;
    }
  }

  // =========================================================================
  // IPC mode (Android) — thin client that talks to the background service
  // =========================================================================

  void _attachToService() {
    _serviceDataCallback = _onServiceData;
    FlutterForegroundTask.addTaskDataCallback(_serviceDataCallback!);

    _terminal.onOutput = _handleIpcTerminalInput;
    _terminal.onResize = (width, height, pixelWidth, pixelHeight) {
      FlutterForegroundTask.sendDataToTask(ResizeCommand(
        sessionId: widget.session.sessionId,
        width: width,
        height: height,
      ).encode());
    };

    // Request replay + live output
    FlutterForegroundTask.sendDataToTask(
      AttachCommand(sessionId: widget.session.sessionId).encode(),
    );

    setState(() => _connected = true);
  }

  void _onServiceData(Object data) {
    if (data is! String) return;
    try {
      final event = ServiceEvent.decode(data);
      switch (event) {
        case OutputEvent() when event.sessionId == widget.session.sessionId:
          final bytes = base64Decode(event.dataBase64);
          _terminal.write(utf8.decode(bytes, allowMalformed: true));
        case ReplayEvent() when event.sessionId == widget.session.sessionId:
          if (!_replayReceived) {
            _replayReceived = true;
            final bytes = base64Decode(event.dataBase64);
            _terminal.write(utf8.decode(bytes, allowMalformed: true));
          }
        case AuthPromptEvent()
            when event.sessionId == widget.session.sessionId:
          _handleIpcAuthPrompt(event.prompt, event.echo);
        case DisconnectedEvent()
            when event.sessionId == widget.session.sessionId:
          _terminal.write('\r\nDisconnected: ${event.reason}\r\n');
          if (mounted) {
            widget.onDisconnected();
          }
        case StatusEvent() when event.sessionId == widget.session.sessionId:
          _terminal.write('${event.message}\r\n');
        case ErrorEvent() when event.sessionId == widget.session.sessionId:
          _terminal.write('\r\nError: ${event.message}\r\n');
          if (mounted) {
            setState(() => _authFailed = true);
          }
        default:
          break;
      }
    } catch (_) {}
  }

  void _handleIpcTerminalInput(String data) {
    // Handle auth prompt input
    if (_ipcAuthCompleter != null && !_ipcAuthCompleter!.isCompleted) {
      for (final char in data.codeUnits) {
        if (char == 13 || char == 10) {
          _terminal.write('\r\n');
          _ipcAuthCompleter!.complete(_ipcAuthBuffer.toString());
          _ipcAuthCompleter = null;
        } else if (char == 127 || char == 8) {
          if (_ipcAuthBuffer.isNotEmpty) {
            final s = _ipcAuthBuffer.toString();
            _ipcAuthBuffer = StringBuffer(s.substring(0, s.length - 1));
            if (_ipcAuthEcho) {
              _terminal.write('\b \b');
            }
          }
        } else {
          _ipcAuthBuffer.writeCharCode(char);
          if (_ipcAuthEcho) {
            _terminal.write(String.fromCharCode(char));
          }
        }
      }
      return;
    }

    // Apply modifier keys and send to service
    final paneState = _paneKey.currentState;
    String toSend = data;
    if (paneState != null &&
        (paneState.ctrlActive ||
            paneState.altActive ||
            paneState.shiftActive)) {
      toSend = paneState.applyModifiers(data);
      paneState.clearModifiers();
    }

    FlutterForegroundTask.sendDataToTask(InputCommand(
      sessionId: widget.session.sessionId,
      dataBase64: base64Encode(utf8.encode(toSend)),
    ).encode());
  }

  void _handleIpcAuthPrompt(String prompt, bool echo) {
    _terminal.write(prompt);
    _ipcAuthCompleter = Completer<String>();
    _ipcAuthBuffer = StringBuffer();
    _ipcAuthEcho = echo;
    _ipcAuthCompleter!.future.then((response) {
      FlutterForegroundTask.sendDataToTask(AuthResponseCommand(
        sessionId: widget.session.sessionId,
        response: response,
      ).encode());
    });
  }

  void _detachFromService() {
    if (_serviceDataCallback != null) {
      FlutterForegroundTask.removeTaskDataCallback(_serviceDataCallback!);
      _serviceDataCallback = null;
    }
    FlutterForegroundTask.sendDataToTask(
      DetachCommand(sessionId: widget.session.sessionId).encode(),
    );
  }

  // =========================================================================
  // Direct mode (non-Android)
  // =========================================================================

  void _connectDirect() {
    switch (widget.session.connectionType) {
      case ConnectionType.iroh:
      case ConnectionType.ssh:
        _connectSshDirect();
      case ConnectionType.local:
        _connectLocalShellDirect();
    }
  }

  Future<String> _readLineFromTerminal({bool echo = true}) {
    _inputCompleter = Completer<String>();
    _inputBuffer = StringBuffer();
    _inputEcho = echo;
    return _inputCompleter!.future;
  }

  void _handleDirectTerminalInput(String data) {
    if (_inputCompleter != null && !_inputCompleter!.isCompleted) {
      for (final char in data.codeUnits) {
        if (char == 13 || char == 10) {
          _terminal.write('\r\n');
          _inputCompleter!.complete(_inputBuffer.toString());
          _inputCompleter = null;
        } else if (char == 127 || char == 8) {
          if (_inputBuffer.isNotEmpty) {
            final s = _inputBuffer.toString();
            _inputBuffer = StringBuffer(s.substring(0, s.length - 1));
            if (_inputEcho) {
              _terminal.write('\b \b');
            }
          }
        } else {
          _inputBuffer.writeCharCode(char);
          if (_inputEcho) {
            _terminal.write(String.fromCharCode(char));
          }
        }
      }
      return;
    }

    final paneState = _paneKey.currentState;
    if (paneState != null &&
        (paneState.ctrlActive ||
            paneState.altActive ||
            paneState.shiftActive)) {
      final modified = paneState.applyModifiers(data);
      paneState.clearModifiers();
      _session?.write(utf8.encode(modified));
      return;
    }

    _session?.write(utf8.encode(data));
  }

  void _handleLocalShellTerminalInput(String data) {
    final paneState = _paneKey.currentState;
    String toSend = data;
    if (paneState != null &&
        (paneState.ctrlActive ||
            paneState.altActive ||
            paneState.shiftActive)) {
      toSend = paneState.applyModifiers(data);
      paneState.clearModifiers();
    }

    _pty?.write(utf8.encode(toSend));
  }

  void _flushStdout() {
    _stdoutFlushTimer = null;
    final bytes = _stdoutBuffer.takeBytes();
    _terminal.write(utf8.decode(bytes, allowMalformed: true));
  }

  void _flushStderr() {
    _stderrFlushTimer = null;
    final bytes = _stderrBuffer.takeBytes();
    _terminal.write(utf8.decode(bytes, allowMalformed: true));
  }

  Future<void> _connectSshDirect() async {
    _terminal.onOutput = _handleDirectTerminalInput;

    try {
      _terminal.write(
          'Connecting to ${widget.session.host}:${widget.session.port}...\r\n');

      final keys = await KeyStorage.instance.listKeys();
      final identities = keys.map((k) => k.keyPair).toList();

      final socket = await SSHSocket.connect(
          widget.session.host, widget.session.port);

      _client = SSHClient(
        socket,
        username: widget.session.username,
        identities: identities,
        onPasswordRequest: () async {
          _terminal.write('Password: ');
          return await _readLineFromTerminal(echo: false);
        },
        onUserInfoRequest: (request) async {
          if (request.prompts.isEmpty) {
            return [];
          }
          final responses = <String>[];
          for (final prompt in request.prompts) {
            _terminal.write(prompt.promptText);
            final response =
                await _readLineFromTerminal(echo: prompt.echo);
            responses.add(response);
          }
          return responses;
        },
        onUserauthBanner: (banner) {
          _terminal.write(banner.replaceAll('\n', '\r\n'));
        },
      );

      _terminal.write('Authenticating...\r\n');

      _session = await _client!.shell(
        pty: SSHPtyConfig(
          width: _terminal.viewWidth,
          height: _terminal.viewHeight,
        ),
      );

      _terminal.buffer.clear();
      _terminal.buffer.setCursor(0, 0);

      _session!.stdout.listen((data) {
        _stdoutBuffer.add(data);
        _stdoutFlushTimer ??= Timer(_batchDuration, _flushStdout);
      });

      _session!.stderr.listen((data) {
        _stderrBuffer.add(data);
        _stderrFlushTimer ??= Timer(_batchDuration, _flushStderr);
      });

      _terminal.onResize = (width, height, pixelWidth, pixelHeight) {
        _session?.resizeTerminal(width, height);
      };

      _session!.done.then((_) {
        if (mounted) {
          _disconnectDirect();
        }
      });

      setState(() => _connected = true);
    } catch (e) {
      _terminal.write('\r\nError: $e\r\n');
      if (mounted) {
        setState(() => _authFailed = true);
      }
    }
  }

  void _connectLocalShellDirect() {
    _terminal.onOutput = _handleLocalShellTerminalInput;

    try {
      _terminal.write('Starting local shell...\r\n');

      final shell = Platform.environment['SHELL'] ?? 'sh';
      _pty = Pty.start(
        shell,
        columns: _terminal.viewWidth,
        rows: _terminal.viewHeight,
      );

      _terminal.buffer.clear();
      _terminal.buffer.setCursor(0, 0);

      _ptyOutputSubscription = _pty!.output.listen((data) {
        _stdoutBuffer.add(data);
        _stdoutFlushTimer ??= Timer(_batchDuration, _flushStdout);
      });

      _terminal.onResize = (width, height, pixelWidth, pixelHeight) {
        _pty?.resize(height, width);
      };

      _pty!.exitCode.then((_) {
        if (mounted) {
          _disconnectDirect();
        }
      });

      setState(() => _connected = true);
    } catch (e) {
      _terminal.write('\r\nError: $e\r\n');
      if (mounted) {
        setState(() => _authFailed = true);
      }
    }
  }

  Future<void> retry() async {
    setState(() => _authFailed = false);
    if (_isAndroid) {
      _terminal.write('\r\n');
      FlutterForegroundTask.sendDataToTask(ReconnectCommand(
        sessionId: widget.session.sessionId,
      ).encode());
    } else {
      _cleanupDirectConnection();
      _terminal.write('\r\n');
      _connectDirect();
    }
  }

  void _cleanupDirectConnection() {
    _ptyOutputSubscription?.cancel();
    _ptyOutputSubscription = null;
    _pty?.kill();
    _pty = null;
    _client?.close();
    _client = null;
    _session = null;
  }

  Future<void> disconnect() async {
    if (_isAndroid) {
      _detachFromService();
    } else {
      await _disconnectDirect();
    }
  }

  Future<void> _disconnectDirect() async {
    _ptyOutputSubscription?.cancel();
    _ptyOutputSubscription = null;
    _pty?.kill();
    _pty = null;
    _session?.close();
    _client?.close();
    if (widget.session.connectionType == ConnectionType.iroh) {
      await disconnectIroh(port: widget.session.port);
    }
    if (mounted) {
      widget.onDisconnected();
    }
  }

  @override
  void dispose() {
    if (_isAndroid) {
      // Detach from service (don't disconnect — session keeps running)
      if (_serviceDataCallback != null) {
        FlutterForegroundTask.removeTaskDataCallback(_serviceDataCallback!);
        _serviceDataCallback = null;
      }
      // Send detach so the service knows we're not listening
      FlutterForegroundTask.sendDataToTask(
        DetachCommand(sessionId: widget.session.sessionId).encode(),
      );
    } else {
      _stdoutFlushTimer?.cancel();
      _stderrFlushTimer?.cancel();
      _ptyOutputSubscription?.cancel();
      _pty?.kill();
      _session?.close();
      _client?.close();
      if (widget.connectOnInit && widget.session.connectionType == ConnectionType.iroh) {
        disconnectIroh(port: widget.session.port);
      }
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final mediaQuery = MediaQuery.of(context);
    final keyboardHeight = mediaQuery.viewInsets.bottom;
    return Stack(
      children: [
        TerminalPane(
          key: _paneKey,
          terminal: _terminal,
          autofocus: true,
          fontSize: _fontSize,
          theme: widget.themeName == 'whiteOnBlack'
              ? TerminalThemes.whiteOnBlack
              : TerminalThemes.defaultTheme,
          onFontSizeChanged: (newSize) {
            setState(() => _fontSize = newSize);
          },
          onScalingChanged: widget.onScalingChanged,
        ),
        if (_authFailed)
          Positioned(
            bottom: keyboardHeight + 16,
            left: 0,
            right: 0,
            child: Center(
              child: FilledButton.icon(
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
                onPressed: retry,
              ),
            ),
          ),
      ],
    );
  }
}
