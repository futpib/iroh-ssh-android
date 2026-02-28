import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_pty/flutter_pty.dart';
import 'package:iroh_ssh_app/models/connection_type.dart';
import 'package:iroh_ssh_app/services/session_messages.dart';
import 'package:iroh_ssh_app/services/terminal_replay_buffer.dart';
import 'package:iroh_ssh_app/src/rust/api/simple.dart';

enum SessionState { connecting, connected, disconnected }

class BackgroundSession {
  final String sessionId;
  final String displayName;
  final String username;
  int port;
  final List<SSHKeyPair> identities;
  final ConnectionType connectionType;

  /// Connection parameters needed for reconnection.
  final String? endpointId;
  final List<String> relayUrls;
  final List<String> extraRelayUrls;
  final int? maxRemoteNatTraversalAddresses;

  /// Direct SSH connection parameters.
  final String? sshHost;
  final int? sshPort;

  SSHClient? _client;
  SSHSession? _session;
  Pty? _pty;
  SessionState state = SessionState.connecting;
  final TerminalReplayBuffer replayBuffer = TerminalReplayBuffer();
  bool uiAttached = false;

  /// Callback to send events to the UI (set by the service).
  void Function(String data)? onSendToUi;

  /// Called when the session has ended and should be removed.
  void Function()? onSessionEnded;

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

  StreamSubscription? _ptyOutputSubscription;

  BackgroundSession({
    required this.sessionId,
    required this.displayName,
    required this.username,
    required this.port,
    required this.identities,
    this.connectionType = ConnectionType.iroh,
    this.endpointId,
    this.relayUrls = const [],
    this.extraRelayUrls = const [],
    this.maxRemoteNatTraversalAddresses,
    this.sshHost,
    this.sshPort,
  });

  Future<void> connect() async {
    switch (connectionType) {
      case ConnectionType.iroh:
      case ConnectionType.ssh:
        await _connectSsh();
      case ConnectionType.local:
        _connectLocalShell();
    }
  }

  Future<void> _connectSsh() async {
    state = SessionState.connecting;
    final connectHost =
        connectionType == ConnectionType.ssh ? sshHost! : 'localhost';
    final connectPort =
        connectionType == ConnectionType.ssh ? (sshPort ?? 22) : port;
    _sendStatus('Connecting to $connectHost:$connectPort...');

    try {
      final socket = await SSHSocket.connect(connectHost, connectPort);

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
      state = SessionState.disconnected;
      _sendError(e.toString());
    }
  }

  void _connectLocalShell() {
    state = SessionState.connecting;
    _sendStatus('Starting local shell...');

    try {
      final shell = Platform.environment['SHELL'] ?? 'sh';
      _pty = Pty.start(shell, columns: 80, rows: 24);

      state = SessionState.connected;

      _ptyOutputSubscription = _pty!.output.listen((data) {
        _stdoutBuffer.add(data);
        _stdoutFlushTimer ??= Timer(_batchDuration, _flushStdout);
      });

      _pty!.exitCode.then((_) {
        disconnect(reason: 'Shell exited');
      });
    } catch (e) {
      final errorMsg = '\r\nError: $e\r\n';
      final bytes = utf8.encode(errorMsg);
      replayBuffer.write(bytes);
      _forwardOutput(bytes);
      state = SessionState.disconnected;
      _sendError(e.toString());
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

  void _sendError(String message) {
    if (onSendToUi != null) {
      onSendToUi!(ErrorEvent(
        sessionId: sessionId,
        message: message,
      ).encode());
    }
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
    if (connectionType == ConnectionType.local) {
      _pty?.write(data);
    } else {
      _session?.write(data);
    }
  }

  void handleResize(int width, int height) {
    if (connectionType == ConnectionType.local) {
      _pty?.resize(height, width);
    } else {
      _session?.resizeTerminal(width, height);
    }
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

  Future<void> reconnect() async {
    // Clean up old connection
    _ptyOutputSubscription?.cancel();
    _ptyOutputSubscription = null;
    _pty?.kill();
    _pty = null;
    _session?.close();
    _client?.close();
    _session = null;
    _client = null;
    _stdoutFlushTimer?.cancel();
    _stderrFlushTimer?.cancel();
    _authCompleter?.complete('');
    _authCompleter = null;
    for (final pending in _pendingAuthPrompts) {
      pending.completer.complete('');
    }
    _pendingAuthPrompts.clear();

    if (connectionType == ConnectionType.iroh) {
      // Clean up old iroh tunnel
      try {
        await disconnectIroh(port: port);
      } catch (_) {}

      // Establish new iroh tunnel
      _sendStatus('Reconnecting...');
      port = await connectIroh(
        endpointId: endpointId!,
        relayUrls: relayUrls,
        extraRelayUrls: extraRelayUrls,
        maxRemoteNatTraversalAddresses: maxRemoteNatTraversalAddresses,
      );
    } else {
      _sendStatus('Reconnecting...');
    }

    // Start connection
    await connect();
  }

  Future<void> disconnect({String reason = 'Disconnected'}) async {
    if (state == SessionState.disconnected) return;
    state = SessionState.disconnected;
    _stdoutFlushTimer?.cancel();
    _stderrFlushTimer?.cancel();
    _ptyOutputSubscription?.cancel();
    _ptyOutputSubscription = null;
    _pty?.kill();
    _pty = null;
    _session?.close();
    _client?.close();
    if (connectionType == ConnectionType.iroh) {
      try {
        await disconnectIroh(port: port);
      } catch (_) {
        // Port may already be cleaned up
      }
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
    onSessionEnded?.call();
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
