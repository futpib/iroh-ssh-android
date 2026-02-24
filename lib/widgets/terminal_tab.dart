import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
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

  Completer<String>? _inputCompleter;
  StringBuffer _inputBuffer = StringBuffer();
  bool _inputEcho = true;

  bool get connected => _connected;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
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

    _session?.write(utf8.encode(data));
  }

  Future<void> _connectSsh() async {
    _terminal.onOutput = _handleTerminalInput;

    try {
      _terminal.write(
          'Connecting to ${widget.session.host}:${widget.session.port}...\r\n');

      final socket = await SSHSocket.connect(
          widget.session.host, widget.session.port);

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

      _session = await _client!.shell(
        pty: SSHPtyConfig(
          width: _terminal.viewWidth,
          height: _terminal.viewHeight,
        ),
      );

      _terminal.buffer.clear();
      _terminal.buffer.setCursor(0, 0);

      _session!.stdout.listen((data) {
        _terminal.write(utf8.decode(data, allowMalformed: true));
      });

      _session!.stderr.listen((data) {
        _terminal.write(utf8.decode(data, allowMalformed: true));
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
    _session?.close();
    _client?.close();
    disconnectIroh(port: widget.session.port);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Stack(
      children: [
        TerminalView(_terminal, autofocus: true),
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
