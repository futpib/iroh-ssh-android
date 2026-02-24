import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:iroh_ssh_app/src/rust/api/simple.dart';
import 'package:xterm/xterm.dart';

class TerminalScreen extends StatefulWidget {
  final String host;
  final int port;
  final String username;

  const TerminalScreen({
    super.key,
    required this.host,
    required this.port,
    required this.username,
  });

  @override
  State<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends State<TerminalScreen> {
  final _terminal = Terminal(maxLines: 10000);
  SSHClient? _client;
  SSHSession? _session;
  bool _connected = false;

  // For interactive password input in the terminal
  Completer<String>? _inputCompleter;
  StringBuffer _inputBuffer = StringBuffer();
  bool _inputEcho = true;

  @override
  void initState() {
    super.initState();
    _connectSsh();
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
          // Enter
          _terminal.write('\r\n');
          _inputCompleter!.complete(_inputBuffer.toString());
          _inputCompleter = null;
        } else if (char == 127 || char == 8) {
          // Backspace
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

    // Normal mode: forward to SSH session
    _session?.write(utf8.encode(data));
  }

  Future<void> _connectSsh() async {
    _terminal.onOutput = _handleTerminalInput;

    try {
      _terminal.write('Connecting to ${widget.host}:${widget.port}...\r\n');

      final socket = await SSHSocket.connect(widget.host, widget.port);

      _client = SSHClient(
        socket,
        username: widget.username,
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
        _terminal.write(String.fromCharCodes(data));
      });

      _session!.stderr.listen((data) {
        _terminal.write(String.fromCharCodes(data));
      });

      _terminal.onResize = (width, height, pixelWidth, pixelHeight) {
        _session?.resizeTerminal(width, height);
      };

      _session!.done.then((_) {
        if (mounted) {
          setState(() => _connected = false);
          _terminal.write('\r\n[Session ended]\r\n');
        }
      });

      setState(() => _connected = true);
    } catch (e) {
      _terminal.write('\r\nError: $e\r\n');
    }
  }

  Future<void> _disconnect() async {
    _session?.close();
    _client?.close();
    await disconnectIroh();
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  void dispose() {
    _session?.close();
    _client?.close();
    disconnectIroh();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_connected ? 'Connected' : 'Connecting...'),
        actions: [
          IconButton(
            icon: const Icon(Icons.close),
            onPressed: _disconnect,
            tooltip: 'Disconnect',
          ),
        ],
      ),
      body: TerminalView(_terminal),
    );
  }
}
