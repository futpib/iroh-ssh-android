import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:iroh_ssh_app/services/terminal_replay_buffer.dart';
import 'package:iroh_ssh_app/src/rust/api/simple.dart';

enum SessionState { connecting, connected, disconnected }

class BackgroundSession {
  final String sessionId;
  final String displayName;
  final String username;
  final int port;
  final List<SSHKeyPair> identities;

  SSHClient? _client;
  SSHSession? _session;
  SessionState state = SessionState.connecting;
  final TerminalReplayBuffer replayBuffer = TerminalReplayBuffer();
  bool uiAttached = false;

  /// Callback to send events to the UI (set by the service).
  void Function(String data)? onSendToUi;

  /// Pending auth prompt completer — waits for UI to respond.
  Completer<String>? _authCompleter;

  /// Queued auth prompts waiting for UI to attach.
  final List<_PendingAuthPrompt> _pendingAuthPrompts = [];

  // Stdout/stderr batching
  static const _batchDuration = Duration(milliseconds: 2);
  final _stdoutBuffer = BytesBuilder(copy: false);
  Timer? _stdoutFlushTimer;
  final _stderrBuffer = BytesBuilder(copy: false);
  Timer? _stderrFlushTimer;

  BackgroundSession({
    required this.sessionId,
    required this.displayName,
    required this.username,
    required this.port,
    required this.identities,
  });

  Future<void> connect() async {
    state = SessionState.connecting;
    _sendStatus('Connecting to localhost:$port...');

    try {
      final socket = await SSHSocket.connect('localhost', port);

      _client = SSHClient(
        socket,
        username: username,
        identities: identities,
        onPasswordRequest: () async {
          return await _requestAuth('Password: ', echo: false);
        },
        onUserInfoRequest: (request) async {
          if (request.prompts.isEmpty) return [];
          final responses = <String>[];
          for (final prompt in request.prompts) {
            final response =
                await _requestAuth(prompt.promptText, echo: prompt.echo);
            responses.add(response);
          }
          return responses;
        },
        onUserauthBanner: (banner) {
          final bytes = utf8.encode(banner.replaceAll('\n', '\r\n'));
          replayBuffer.write(bytes);
          _forwardOutput(bytes);
        },
      );

      _sendStatus('Authenticating...');

      _session = await _client!.shell(
        pty: SSHPtyConfig(width: 80, height: 24),
      );

      state = SessionState.connected;

      _session!.stdout.listen((data) {
        _stdoutBuffer.add(data);
        _stdoutFlushTimer ??= Timer(_batchDuration, _flushStdout);
      });

      _session!.stderr.listen((data) {
        _stderrBuffer.add(data);
        _stderrFlushTimer ??= Timer(_batchDuration, _flushStderr);
      });

      _session!.done.then((_) {
        disconnect(reason: 'Session ended');
      });
    } catch (e) {
      final errorMsg = '\r\nError: $e\r\n';
      final bytes = utf8.encode(errorMsg);
      replayBuffer.write(bytes);
      _forwardOutput(bytes);
      disconnect(reason: e.toString());
    }
  }

  void _flushStdout() {
    _stdoutFlushTimer = null;
    final bytes = _stdoutBuffer.takeBytes();
    replayBuffer.write(bytes);
    _forwardOutput(bytes);
  }

  void _flushStderr() {
    _stderrFlushTimer = null;
    final bytes = _stderrBuffer.takeBytes();
    replayBuffer.write(bytes);
    _forwardOutput(bytes);
  }

  void _forwardOutput(List<int> bytes) {
    if (uiAttached && onSendToUi != null) {
      final encoded = base64Encode(bytes);
      onSendToUi!('{"type":"output","sessionId":"$sessionId","data":"$encoded"}');
    }
  }

  void _sendStatus(String message) {
    final bytes = utf8.encode('$message\r\n');
    replayBuffer.write(bytes);
    _forwardOutput(bytes);
  }

  Future<String> _requestAuth(String prompt, {required bool echo}) async {
    if (uiAttached && onSendToUi != null) {
      _authCompleter = Completer<String>();
      onSendToUi!(
        '{"type":"auth_prompt","sessionId":"$sessionId",'
        '"prompt":${jsonEncode(prompt)},"echo":$echo}',
      );
      return _authCompleter!.future;
    } else {
      // Queue the prompt until UI attaches
      final completer = Completer<String>();
      _pendingAuthPrompts.add(_PendingAuthPrompt(
        prompt: prompt,
        echo: echo,
        completer: completer,
      ));
      return completer.future;
    }
  }

  void handleAuthResponse(String response) {
    if (_authCompleter != null && !_authCompleter!.isCompleted) {
      _authCompleter!.complete(response);
      _authCompleter = null;
    }
  }

  void handleInput(Uint8List data) {
    _session?.write(data);
  }

  void handleResize(int width, int height) {
    _session?.resizeTerminal(width, height);
  }

  void onAttach() {
    uiAttached = true;

    // Send any pending auth prompts
    if (_pendingAuthPrompts.isNotEmpty && onSendToUi != null) {
      final pending = _pendingAuthPrompts.removeAt(0);
      _authCompleter = pending.completer;
      onSendToUi!(
        '{"type":"auth_prompt","sessionId":"$sessionId",'
        '"prompt":${jsonEncode(pending.prompt)},"echo":${pending.echo}}',
      );
    }
  }

  void onDetach() {
    uiAttached = false;
  }

  Future<void> disconnect({String reason = 'Disconnected'}) async {
    if (state == SessionState.disconnected) return;
    state = SessionState.disconnected;
    _stdoutFlushTimer?.cancel();
    _stderrFlushTimer?.cancel();
    _session?.close();
    _client?.close();
    try {
      await disconnectIroh(port: port);
    } catch (_) {
      // Port may already be cleaned up
    }
    if (uiAttached && onSendToUi != null) {
      onSendToUi!(
        '{"type":"disconnected","sessionId":"$sessionId",'
        '"reason":${jsonEncode(reason)}}',
      );
    }
    // Complete any pending auth with empty string to unblock
    _authCompleter?.complete('');
    for (final pending in _pendingAuthPrompts) {
      pending.completer.complete('');
    }
    _pendingAuthPrompts.clear();
  }
}

class _PendingAuthPrompt {
  final String prompt;
  final bool echo;
  final Completer<String> completer;

  _PendingAuthPrompt({
    required this.prompt,
    required this.echo,
    required this.completer,
  });
}
