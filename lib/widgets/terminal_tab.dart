import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:iroh_ssh_app/models/ssh_session_info.dart';
import 'package:iroh_ssh_app/src/rust/api/simple.dart';
import 'package:iroh_ssh_app/widgets/terminal_pane.dart';
import 'package:xterm/xterm.dart';

class TerminalTab extends StatefulWidget {
  final SshSessionInfo session;
  final VoidCallback onDisconnected;
  final double fontSize;
  final String themeName;

  @visibleForTesting
  final bool connectOnInit;

  const TerminalTab({
    super.key,
    required this.session,
    required this.onDisconnected,
    this.fontSize = 14.0,
    this.themeName = 'default',
    this.connectOnInit = true,
  });

  @override
  State<TerminalTab> createState() => TerminalTabState();
}

class TerminalTabState extends State<TerminalTab>
    with AutomaticKeepAliveClientMixin {
  final _terminal = Terminal(maxLines: 10000);
  final _paneKey = GlobalKey<TerminalPaneState>();
  SSHClient? _client;
  SSHSession? _session;
  bool _connected = false;
  bool _authFailed = false;

  Completer<String>? _inputCompleter;
  StringBuffer _inputBuffer = StringBuffer();
  bool _inputEcho = true;

  // Stdout batching — flush via short timer to coalesce burst packets
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
    if (widget.connectOnInit) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _connectSsh();
      });
    }
  }

  Future<String> _readLineFromTerminal({bool echo = true}) {
    _inputCompleter = Completer<String>();
    _inputBuffer = StringBuffer();
    _inputEcho = echo;
    return _inputCompleter!.future;
  }

  void _handleTerminalInput(String data) {
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
    if (paneState != null && (paneState.ctrlActive || paneState.altActive)) {
      final modified = paneState.applyModifiers(data);
      paneState.clearModifiers();
      _session?.write(utf8.encode(modified));
      return;
    }

    _session?.write(utf8.encode(data));
  }

  int _stdoutBatchCount = 0;
  int _stdoutPacketCount = 0;

  void _flushStdout() {
    _stdoutFlushTimer = null;
    final packets = _stdoutPacketCount;
    _stdoutPacketCount = 0;
    final bytes = _stdoutBuffer.takeBytes();
    _stdoutBatchCount++;
    if (kDebugMode) {
      debugPrint(
          '[ssh-perf][batch] stdout flush #$_stdoutBatchCount: ${bytes.length} bytes ($packets packets)');
    }
    _terminal.write(utf8.decode(bytes, allowMalformed: true));
  }

  int _stderrBatchCount = 0;
  int _stderrPacketCount = 0;

  void _flushStderr() {
    _stderrFlushTimer = null;
    final packets = _stderrPacketCount;
    _stderrPacketCount = 0;
    final bytes = _stderrBuffer.takeBytes();
    _stderrBatchCount++;
    if (kDebugMode) {
      debugPrint(
          '[ssh-perf][batch] stderr flush #$_stderrBatchCount: ${bytes.length} bytes ($packets packets)');
    }
    _terminal.write(utf8.decode(bytes, allowMalformed: true));
  }

  Future<void> _connectSsh() async {
    _terminal.onOutput = _handleTerminalInput;

    try {
      _terminal.write(
          'Connecting to ${widget.session.host}:${widget.session.port}...\r\n');

      final connectSw = kDebugMode ? (Stopwatch()..start()) : null;

      final socket = await SSHSocket.connect(
          widget.session.host, widget.session.port);

      final socketMs = connectSw?.elapsedMilliseconds;

      _client = SSHClient(
        socket,
        username: widget.session.username,
        identities: widget.session.identities,
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

      final authMs = connectSw?.elapsedMilliseconds;

      _session = await _client!.shell(
        pty: SSHPtyConfig(
          width: _terminal.viewWidth,
          height: _terminal.viewHeight,
        ),
      );

      if (kDebugMode) {
        final shellMs = connectSw!.elapsedMilliseconds;
        debugPrint(
            '[ssh-perf][connect] socket: ${socketMs}ms, auth: ${authMs! - socketMs!}ms, shell: ${shellMs - authMs}ms');
      }

      _terminal.buffer.clear();
      _terminal.buffer.setCursor(0, 0);

      _session!.stdout.listen((data) {
        _stdoutBuffer.add(data);
        _stdoutPacketCount++;
        _stdoutFlushTimer ??= Timer(_batchDuration, _flushStdout);
      });

      _session!.stderr.listen((data) {
        _stderrBuffer.add(data);
        _stderrPacketCount++;
        _stderrFlushTimer ??= Timer(_batchDuration, _flushStderr);
      });

      _terminal.onResize = (width, height, pixelWidth, pixelHeight) {
        _session?.resizeTerminal(width, height);
      };

      _session!.done.then((_) {
        if (mounted) {
          _disconnect();
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
    _client?.close();
    _client = null;
    _session = null;
    _terminal.write('\r\n');
    await _connectSsh();
  }

  Future<void> disconnect() async {
    await _disconnect();
  }

  Future<void> _disconnect() async {
    _session?.close();
    _client?.close();
    await disconnectIroh(port: widget.session.port);
    if (mounted) {
      widget.onDisconnected();
    }
  }

  @override
  void dispose() {
    _stdoutFlushTimer?.cancel();
    _stderrFlushTimer?.cancel();
    _session?.close();
    _client?.close();
    if (widget.connectOnInit) {
      disconnectIroh(port: widget.session.port);
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
          fontSize: widget.fontSize,
          theme: widget.themeName == 'whiteOnBlack'
              ? TerminalThemes.whiteOnBlack
              : TerminalThemes.defaultTheme,
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
