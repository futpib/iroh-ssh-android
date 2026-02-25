import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/scheduler.dart';
import 'package:iroh_ssh_app/models/ssh_session_info.dart';
import 'package:iroh_ssh_app/src/rust/api/simple.dart';
import 'package:xterm/xterm.dart';

class TerminalTab extends StatefulWidget {
  final SshSessionInfo session;
  final VoidCallback onDisconnected;

  const TerminalTab({
    super.key,
    required this.session,
    required this.onDisconnected,
  });

  @override
  State<TerminalTab> createState() => TerminalTabState();
}

class TerminalTabState extends State<TerminalTab>
    with AutomaticKeepAliveClientMixin {
  final _terminal = Terminal(maxLines: 10000);
  SSHClient? _client;
  SSHSession? _session;
  bool _connected = false;
  bool _authFailed = false;
  bool _ctrlActive = false;
  bool _altActive = false;

  Completer<String>? _inputCompleter;
  StringBuffer _inputBuffer = StringBuffer();
  bool _inputEcho = true;

  // Stdout batching — flush via short timer to coalesce burst packets
  static const _batchDuration = Duration(milliseconds: 2);
  final _stdoutBuffer = BytesBuilder(copy: false);
  Timer? _stdoutFlushTimer;
  final _stderrBuffer = BytesBuilder(copy: false);
  Timer? _stderrFlushTimer;

  // Keypress-to-frame latency tracking (debug only)
  Stopwatch? _keypressSw;
  String? _keypressData;
  String? _keypressLabel;
  bool _framePending = false;

  bool get connected => _connected;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    if (kDebugMode) {
      SchedulerBinding.instance.addTimingsCallback(_onFrameTimings);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _connectSsh();
    });
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

    if (_ctrlActive || _altActive) {
      final modified = _applyModifiers(data);
      if (_ctrlActive) setState(() => _ctrlActive = false);
      if (_altActive) setState(() => _altActive = false);
      if (kDebugMode) {
        _keypressData = modified;
        final onOutputMs = _keypressSw?.elapsedMilliseconds;
        debugPrint(
            '[ssh-perf][input] keyEvent→onOutput: ${onOutputMs ?? '?'}ms');
      }
      _session?.write(utf8.encode(modified));
      return;
    }

    if (kDebugMode) {
      _keypressData = data;
      final onOutputMs = _keypressSw?.elapsedMilliseconds;
      debugPrint(
          '[ssh-perf][input] keyEvent→onOutput: ${onOutputMs ?? '?'}ms');
    }
    _session?.write(utf8.encode(data));
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
    if (event is KeyDownEvent || event is KeyRepeatEvent) {
      _keypressSw = Stopwatch()..start();
      _keypressLabel = event.logicalKey.keyLabel;
    }
    return KeyEventResult.ignored;
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
    if (kDebugMode) {
      _scheduleFrameLatencyLog('stdout', bytes.length);
    }
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
    if (kDebugMode) {
      _scheduleFrameLatencyLog('stderr', bytes.length);
    }
  }

  void _scheduleFrameLatencyLog(String channel, int bytes) {
    if (!kDebugMode || _framePending) return;
    final sw = _keypressSw;
    final input = _keypressData;
    final label = _keypressLabel;
    final recvMs = sw?.elapsedMilliseconds;
    _framePending = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _framePending = false;
      final frameMs = sw?.elapsedMilliseconds;
      if (sw != null && input != null) {
        final escaped = input.codeUnits
            .map((c) => c >= 0x20 && c < 0x7f
                ? String.fromCharCode(c)
                : '\\x${c.toRadixString(16).padLeft(2, '0')}')
            .join();
        debugPrint(
            '[ssh-perf][$channel] keyEvent→recv: ${recvMs}ms, keyEvent→frame: ${frameMs}ms, key: ${label ?? '?'}, output: "$escaped" ($bytes bytes)');
        _keypressSw = null;
        _keypressData = null;
        _keypressLabel = null;
      } else {
        debugPrint(
            '[ssh-perf][$channel] recv→frame (unsolicited, $bytes bytes)');
      }
    });
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
    if (kDebugMode) {
      SchedulerBinding.instance.removeTimingsCallback(_onFrameTimings);
    }
    _session?.close();
    _client?.close();
    disconnectIroh(port: widget.session.port);
    super.dispose();
  }

  String _applyModifiers(String data) {
    final buf = StringBuffer();
    for (final char in data.codeUnits) {
      if (_ctrlActive && char >= 0x61 && char <= 0x7a) {
        // a-z → Ctrl+letter (0x01-0x1a)
        buf.writeCharCode(char - 0x60);
      } else if (_ctrlActive && char >= 0x41 && char <= 0x5a) {
        // A-Z → Ctrl+letter (0x01-0x1a)
        buf.writeCharCode(char - 0x40);
      } else if (_altActive) {
        // Alt sends ESC prefix
        buf.writeCharCode(0x1b);
        buf.writeCharCode(char);
      } else {
        buf.writeCharCode(char);
      }
    }
    return buf.toString();
  }

  void _sendKey(TerminalKey key) {
    _terminal.keyInput(key, ctrl: _ctrlActive, alt: _altActive);
    if (_ctrlActive) setState(() => _ctrlActive = false);
    if (_altActive) setState(() => _altActive = false);
  }

  void _sendChar(String char) {
    _terminal.textInput(char);
  }

  Widget _buildToolbar() {
    return Container(
      color: const Color(0xFF1E1E1E),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
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
          const SizedBox(height: 2),
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
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 1),
        child: MaterialButton(
          minWidth: 0,
          height: 32,
          padding: EdgeInsets.zero,
          color: const Color(0xFF2D2D2D),
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
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 1),
        child: MaterialButton(
          minWidth: 0,
          height: 32,
          padding: EdgeInsets.zero,
          color: active ? Colors.blueGrey : const Color(0xFF2D2D2D),
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
    super.build(context);
    return Stack(
      children: [
        Column(
          children: [
            Expanded(
              child: TerminalView(
                _terminal,
                autofocus: true,
                onKeyEvent: kDebugMode ? _onKeyEventPerf : null,
              ),
            ),
            _buildToolbar(),
          ],
        ),
        if (_authFailed)
          Positioned(
            bottom: 16,
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
