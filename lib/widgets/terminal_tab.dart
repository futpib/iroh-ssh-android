import 'dart:async';
import 'dart:convert';
import 'dart:io' show File, Platform;
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:flutter_pty/flutter_pty.dart';
import 'package:iroh_ssh_app/models/connection_type.dart';
import 'package:iroh_ssh_app/models/ssh_session_info.dart';
import 'package:iroh_ssh_app/services/key_storage.dart';
import 'package:iroh_ssh_app/services/session_messages.dart';
import 'package:iroh_ssh_app/src/rust/api/simple.dart';
import 'package:iroh_ssh_app/widgets/terminal_pane.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:xterm/xterm.dart';

class TerminalTab extends StatefulWidget {
  final SshSessionInfo session;
  final VoidCallback onDisconnected;
  final double fontSize;
  final String themeName;
  final ValueChanged<bool>? onScalingChanged;
  final ValueChanged<double>? onVerticalScrollDelta;

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
    this.onVerticalScrollDelta,
  });

  @override
  State<TerminalTab> createState() => TerminalTabState();
}

class TerminalTabState extends State<TerminalTab>
    with AutomaticKeepAliveClientMixin {
  static final bool _isAndroid = Platform.isAndroid;

  static Future<void> _showToast(String message) async {
    if (!_isAndroid) return;
    await Fluttertoast.showToast(msg: message);
  }

  final _terminal = Terminal(maxLines: 10000);
  final _paneKey = GlobalKey<TerminalPaneState>();
  bool _connected = false;
  bool _authFailed = false;
  bool _shellReady = false;
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
  Completer<String>? _inputCompleter;
  StringBuffer _inputBuffer = StringBuffer();
  bool _inputEcho = true;
  static const _batchDuration = Duration(milliseconds: 2);
  final _stderrBuffer = BytesBuilder(copy: false);
  Timer? _stderrFlushTimer;

  // --- ZMODEM ---
  ZModemMux? _zmodemMux;

  @visibleForTesting
  Future<String?> Function()? directoryPickerOverride;

  // --- IPC mode ZMODEM adapters ---
  StreamController<Uint8List>? _ipcStdoutController;
  StreamController<List<int>>? _ipcStdinController;

  bool get connected => _connected;
  bool get shellReady => _shellReady;

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

    // Set up ZMODEM stream adapters for IPC mode
    _ipcStdoutController = StreamController<Uint8List>();
    _ipcStdinController = StreamController<List<int>>();
    _ipcStdinController!.stream.listen((data) {
      FlutterForegroundTask.sendDataToTask(InputCommand(
        sessionId: widget.session.sessionId,
        dataBase64: base64Encode(data),
      ).encode());
    });

    _zmodemMux = ZModemMux(
      stdin: _ipcStdinController!.sink,
      stdout: _ipcStdoutController!.stream,
    );
    _zmodemMux!.onTerminalInput = _terminal.write;
    _zmodemMux!.onFileOffer = _handleZModemFileOffer;

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
          _ipcStdoutController?.add(Uint8List.fromList(bytes));
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
        case ShellReadyEvent()
            when event.sessionId == widget.session.sessionId:
          _shellReady = true;
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

    _zmodemMux?.terminalWrite(toSend);
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
    _zmodemMux = null;
    _ipcStdoutController?.close();
    _ipcStdoutController = null;
    _ipcStdinController?.close();
    _ipcStdinController = null;
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
      _zmodemMux?.terminalWrite(modified);
      return;
    }

    _zmodemMux?.terminalWrite(data);
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

    _zmodemMux?.terminalWrite(toSend);
  }

  void _flushStderr() {
    _stderrFlushTimer = null;
    final bytes = _stderrBuffer.takeBytes();
    _terminal.write(utf8.decode(bytes, allowMalformed: true));
  }

  // =========================================================================
  // ZMODEM file transfer
  // =========================================================================

  void _handleZModemFileOffer(ZModemOffer offer) async {
    _showToast('File offered: ${offer.info.pathname}');

    final outputDir = directoryPickerOverride != null
        ? await directoryPickerOverride!()
        : await FilePicker.platform.getDirectoryPath(
            initialDirectory: (await getDownloadsDirectory())?.path,
          );

    if (outputDir == null) {
      offer.skip();
      return;
    }

    final file = File(path.join(outputDir, offer.info.pathname));

    _showToast('Downloading: ${offer.info.pathname}');

    void updateProgress(int received) {
      final length = offer.info.length;
      if (length != null) {
        _terminal.write('\r');
        _terminal.write('\x1b[K');
        _terminal.write('${offer.info.pathname}: ');
        _terminal.write((received / length * 100).toStringAsFixed(1));
        _terminal.write('%');
      }
    }

    await offer
        .accept(0)
        .cast<List<int>>()
        .transform(_WithProgress(onProgress: updateProgress))
        .pipe(file.openWrite());

    _terminal.write('\r\n');
    _terminal.write('Received ${offer.info.pathname}');
    _terminal.write('\r\n');

    _showToast('Received: ${offer.info.pathname}');
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

      _zmodemMux = ZModemMux(stdin: _session!.stdin, stdout: _session!.stdout);
      _zmodemMux!.onTerminalInput = _terminal.write;
      _zmodemMux!.onFileOffer = _handleZModemFileOffer;

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

      setState(() {
        _connected = true;
        _shellReady = true;
      });
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

      _zmodemMux = ZModemMux(
        stdin: _PtySinkAdapter(_pty!),
        stdout: _pty!.output,
      );
      _zmodemMux!.onTerminalInput = _terminal.write;
      _zmodemMux!.onFileOffer = _handleZModemFileOffer;

      _terminal.onResize = (width, height, pixelWidth, pixelHeight) {
        _pty?.resize(height, width);
      };

      _pty!.exitCode.then((_) {
        if (mounted) {
          _disconnectDirect();
        }
      });

      setState(() {
        _connected = true;
        _shellReady = true;
      });
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
    _zmodemMux = null;
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
    _zmodemMux = null;
    if (_isAndroid) {
      _ipcStdoutController?.close();
      _ipcStdoutController = null;
      _ipcStdinController?.close();
      _ipcStdinController = null;
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
      _stderrFlushTimer?.cancel();
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
          onVerticalScrollDelta: widget.onVerticalScrollDelta,
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

class _PtySinkAdapter implements StreamSink<List<int>> {
  final Pty _pty;

  _PtySinkAdapter(this._pty);

  @override
  void add(List<int> data) {
    _pty.write(Uint8List.fromList(data));
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future addStream(Stream<List<int>> stream) {
    final completer = Completer<void>();
    stream.listen(
      add,
      onError: addError,
      onDone: completer.complete,
    );
    return completer.future;
  }

  @override
  Future close() async {}

  @override
  Future get done => Future.value();
}

class _WithProgress<T> extends StreamTransformerBase<List<T>, List<T>> {
  _WithProgress({this.onProgress});

  void Function(int progress)? onProgress;

  var _progress = 0;

  @override
  Stream<List<T>> bind(Stream<List<T>> stream) {
    return stream.transform(StreamTransformer<List<T>, List<T>>.fromHandlers(
      handleData: (List<T> data, EventSink<List<T>> sink) {
        _progress += data.length;
        onProgress?.call(_progress);
        sink.add(data);
      },
    ));
  }
}
