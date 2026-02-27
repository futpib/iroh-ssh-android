import 'dart:convert';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:iroh_ssh_app/services/background_session.dart';
import 'package:iroh_ssh_app/services/key_storage.dart';
import 'package:iroh_ssh_app/services/session_messages.dart';
import 'package:iroh_ssh_app/src/rust/api/simple.dart';
import 'package:iroh_ssh_app/src/rust/frb_generated.dart';

@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(SshSessionService());
}

class SshSessionService extends TaskHandler {
  final Map<String, BackgroundSession> _sessions = {};
  int _sessionCounter = 0;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    await RustLib.init();
  }

  @override
  void onReceiveData(Object data) {
    if (data is! String) return;
    try {
      final command = ServiceCommand.decode(data);
      _handleCommand(command);
    } catch (e) {
      _sendToUi(ErrorEvent(message: 'Failed to parse command: $e').encode());
    }
  }

  void _handleCommand(ServiceCommand command) {
    switch (command) {
      case ConnectCommand():
        _handleConnect(command);
      case DisconnectCommand():
        _handleDisconnect(command);
      case InputCommand():
        _handleInput(command);
      case ResizeCommand():
        _handleResize(command);
      case AttachCommand():
        _handleAttach(command);
      case DetachCommand():
        _handleDetach(command);
      case ListSessionsCommand():
        _handleListSessions();
      case AuthResponseCommand():
        _handleAuthResponse(command);
    }
  }

  Future<void> _handleConnect(ConnectCommand command) async {
    final sessionId = 'session_${_sessionCounter++}';

    try {
      final keys = await KeyStorage.instance.listKeys();
      final requestedKeyNames = command.keyNames.toSet();
      final identities = keys
          .where((k) => requestedKeyNames.isEmpty || requestedKeyNames.contains(k.name))
          .map((k) => k.keyPair)
          .toList();

      final port = await connectIroh(
        endpointId: command.endpointId,
        relayUrls: command.relayUrls,
        extraRelayUrls: command.extraRelayUrls,
        maxRemoteNatTraversalAddresses: command.maxRemoteNatTraversalAddresses,
      );

      final session = BackgroundSession(
        sessionId: sessionId,
        displayName: command.displayName,
        username: command.username,
        port: port,
        identities: identities,
      );

      session.onSendToUi = _sendToUi;
      session.uiAttached = true;
      _sessions[sessionId] = session;

      _sendToUi(ConnectedEvent(
        sessionId: sessionId,
        displayName: command.displayName,
        username: command.username,
        port: port,
      ).encode());

      _updateNotification();

      // Start SSH connection asynchronously
      session.connect().then((_) {
        // Connection completed (or failed) — check if we should clean up
        if (session.state == SessionState.disconnected) {
          _removeSession(sessionId);
        }
      });
    } catch (e) {
      _sendToUi(ErrorEvent(
        sessionId: sessionId,
        message: e.toString(),
      ).encode());
    }
  }

  void _handleDisconnect(DisconnectCommand command) {
    final session = _sessions[command.sessionId];
    if (session == null) return;
    session.disconnect();
    _removeSession(command.sessionId);
  }

  void _handleInput(InputCommand command) {
    final session = _sessions[command.sessionId];
    if (session == null) return;
    final bytes = base64Decode(command.dataBase64);
    session.handleInput(bytes);
  }

  void _handleResize(ResizeCommand command) {
    final session = _sessions[command.sessionId];
    if (session == null) return;
    session.handleResize(command.width, command.height);
  }

  void _handleAttach(AttachCommand command) {
    final session = _sessions[command.sessionId];
    if (session == null) return;
    session.onAttach();

    // Send replay data
    final replayData = session.replayBuffer.read();
    if (replayData.isNotEmpty) {
      _sendToUi(ReplayEvent(
        sessionId: command.sessionId,
        dataBase64: base64Encode(replayData),
      ).encode());
    }
  }

  void _handleDetach(DetachCommand command) {
    final session = _sessions[command.sessionId];
    if (session == null) return;
    session.onDetach();
  }

  void _handleListSessions() {
    final summaries = _sessions.values.map((s) => SessionSummary(
          sessionId: s.sessionId,
          displayName: s.displayName,
          username: s.username,
          port: s.port,
          state: s.state.name,
        )).toList();
    _sendToUi(SessionListEvent(sessions: summaries).encode());
  }

  void _handleAuthResponse(AuthResponseCommand command) {
    final session = _sessions[command.sessionId];
    if (session == null) return;
    session.handleAuthResponse(command.response);
  }

  void _removeSession(String sessionId) {
    _sessions.remove(sessionId);
    _updateNotification();
    if (_sessions.isEmpty) {
      FlutterForegroundTask.stopService();
    }
  }

  void _updateNotification() {
    final count = _sessions.length;
    if (count > 0) {
      FlutterForegroundTask.updateService(
        notificationTitle: 'iroh-ssh',
        notificationText: '$count active session${count > 1 ? 's' : ''}',
      );
    }
  }

  void _sendToUi(String data) {
    FlutterForegroundTask.sendDataToMain(data);
  }

  @override
  void onNotificationButtonPressed(String id) {
    if (id == 'disconnect_all') {
      _disconnectAllAndStop();
    }
  }

  Future<void> _disconnectAllAndStop() async {
    for (final session in _sessions.values.toList()) {
      await session.disconnect();
    }
    _sessions.clear();
    FlutterForegroundTask.stopService();
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    for (final session in _sessions.values.toList()) {
      await session.disconnect();
    }
    _sessions.clear();
    try {
      await disconnectAll();
    } catch (_) {}
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    // Not used — eventAction is set to nothing()
  }
}
