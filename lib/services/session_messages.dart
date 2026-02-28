import 'dart:convert';

import 'package:iroh_ssh_app/models/connection_type.dart';

// ---------------------------------------------------------------------------
// UI → Service messages
// ---------------------------------------------------------------------------

sealed class ServiceCommand {
  Map<String, dynamic> toJson();

  String encode() => jsonEncode(toJson());

  static ServiceCommand decode(String raw) {
    final json = jsonDecode(raw) as Map<String, dynamic>;
    return switch (json['type'] as String) {
      'connect' => ConnectCommand.fromJson(json),
      'disconnect' => DisconnectCommand.fromJson(json),
      'input' => InputCommand.fromJson(json),
      'resize' => ResizeCommand.fromJson(json),
      'attach' => AttachCommand.fromJson(json),
      'detach' => DetachCommand.fromJson(json),
      'list_sessions' => ListSessionsCommand(),
      'auth_response' => AuthResponseCommand.fromJson(json),
      'reconnect' => ReconnectCommand.fromJson(json),
      _ => throw ArgumentError('Unknown command type: ${json['type']}'),
    };
  }
}

class ConnectCommand extends ServiceCommand {
  final ConnectionType connectionType;
  final String? endpointId;
  final String username;
  final String displayName;
  final List<String> keyNames;
  final List<String> relayUrls;
  final List<String> extraRelayUrls;
  final int? maxRemoteNatTraversalAddresses;
  final String? host;
  final int? sshPort;

  ConnectCommand({
    this.connectionType = ConnectionType.iroh,
    this.endpointId,
    required this.username,
    required this.displayName,
    required this.keyNames,
    required this.relayUrls,
    required this.extraRelayUrls,
    this.maxRemoteNatTraversalAddresses,
    this.host,
    this.sshPort,
  });

  @override
  Map<String, dynamic> toJson() => {
        'type': 'connect',
        'connectionType': connectionType.name,
        if (endpointId != null) 'endpointId': endpointId,
        'username': username,
        'displayName': displayName,
        'keyNames': keyNames,
        'relayUrls': relayUrls,
        'extraRelayUrls': extraRelayUrls,
        if (maxRemoteNatTraversalAddresses != null)
          'maxRemoteNatTraversalAddresses': maxRemoteNatTraversalAddresses,
        if (host != null) 'host': host,
        if (sshPort != null) 'sshPort': sshPort,
      };

  factory ConnectCommand.fromJson(Map<String, dynamic> json) => ConnectCommand(
        connectionType: _parseConnectionType(json['connectionType'] as String?),
        endpointId: json['endpointId'] as String?,
        username: json['username'] as String,
        displayName: json['displayName'] as String,
        keyNames: (json['keyNames'] as List).cast<String>(),
        relayUrls: (json['relayUrls'] as List).cast<String>(),
        extraRelayUrls: (json['extraRelayUrls'] as List).cast<String>(),
        maxRemoteNatTraversalAddresses:
            json['maxRemoteNatTraversalAddresses'] as int?,
        host: json['host'] as String?,
        sshPort: json['sshPort'] as int?,
      );

  static ConnectionType _parseConnectionType(String? value) {
    if (value == null) return ConnectionType.iroh;
    return ConnectionType.values.where((e) => e.name == value).firstOrNull ??
        ConnectionType.iroh;
  }
}

class DisconnectCommand extends ServiceCommand {
  final String sessionId;

  DisconnectCommand({required this.sessionId});

  @override
  Map<String, dynamic> toJson() => {
        'type': 'disconnect',
        'sessionId': sessionId,
      };

  factory DisconnectCommand.fromJson(Map<String, dynamic> json) =>
      DisconnectCommand(sessionId: json['sessionId'] as String);
}

class InputCommand extends ServiceCommand {
  final String sessionId;
  final String dataBase64;

  InputCommand({required this.sessionId, required this.dataBase64});

  @override
  Map<String, dynamic> toJson() => {
        'type': 'input',
        'sessionId': sessionId,
        'data': dataBase64,
      };

  factory InputCommand.fromJson(Map<String, dynamic> json) => InputCommand(
        sessionId: json['sessionId'] as String,
        dataBase64: json['data'] as String,
      );
}

class ResizeCommand extends ServiceCommand {
  final String sessionId;
  final int width;
  final int height;

  ResizeCommand({
    required this.sessionId,
    required this.width,
    required this.height,
  });

  @override
  Map<String, dynamic> toJson() => {
        'type': 'resize',
        'sessionId': sessionId,
        'width': width,
        'height': height,
      };

  factory ResizeCommand.fromJson(Map<String, dynamic> json) => ResizeCommand(
        sessionId: json['sessionId'] as String,
        width: json['width'] as int,
        height: json['height'] as int,
      );
}

class AttachCommand extends ServiceCommand {
  final String sessionId;

  AttachCommand({required this.sessionId});

  @override
  Map<String, dynamic> toJson() => {
        'type': 'attach',
        'sessionId': sessionId,
      };

  factory AttachCommand.fromJson(Map<String, dynamic> json) =>
      AttachCommand(sessionId: json['sessionId'] as String);
}

class DetachCommand extends ServiceCommand {
  final String sessionId;

  DetachCommand({required this.sessionId});

  @override
  Map<String, dynamic> toJson() => {
        'type': 'detach',
        'sessionId': sessionId,
      };

  factory DetachCommand.fromJson(Map<String, dynamic> json) =>
      DetachCommand(sessionId: json['sessionId'] as String);
}

class ListSessionsCommand extends ServiceCommand {
  ListSessionsCommand();

  @override
  Map<String, dynamic> toJson() => {'type': 'list_sessions'};
}

class ReconnectCommand extends ServiceCommand {
  final String sessionId;

  ReconnectCommand({required this.sessionId});

  @override
  Map<String, dynamic> toJson() => {
        'type': 'reconnect',
        'sessionId': sessionId,
      };

  factory ReconnectCommand.fromJson(Map<String, dynamic> json) =>
      ReconnectCommand(sessionId: json['sessionId'] as String);
}

class AuthResponseCommand extends ServiceCommand {
  final String sessionId;
  final String response;

  AuthResponseCommand({required this.sessionId, required this.response});

  @override
  Map<String, dynamic> toJson() => {
        'type': 'auth_response',
        'sessionId': sessionId,
        'response': response,
      };

  factory AuthResponseCommand.fromJson(Map<String, dynamic> json) =>
      AuthResponseCommand(
        sessionId: json['sessionId'] as String,
        response: json['response'] as String,
      );
}

// ---------------------------------------------------------------------------
// Service → UI messages
// ---------------------------------------------------------------------------

sealed class ServiceEvent {
  Map<String, dynamic> toJson();

  String encode() => jsonEncode(toJson());

  static ServiceEvent decode(String raw) {
    final json = jsonDecode(raw) as Map<String, dynamic>;
    return switch (json['type'] as String) {
      'connected' => ConnectedEvent.fromJson(json),
      'disconnected' => DisconnectedEvent.fromJson(json),
      'output' => OutputEvent.fromJson(json),
      'replay' => ReplayEvent.fromJson(json),
      'session_list' => SessionListEvent.fromJson(json),
      'auth_prompt' => AuthPromptEvent.fromJson(json),
      'error' => ErrorEvent.fromJson(json),
      'status' => StatusEvent.fromJson(json),
      _ => throw ArgumentError('Unknown event type: ${json['type']}'),
    };
  }
}

class ConnectedEvent extends ServiceEvent {
  final String sessionId;
  final String displayName;
  final String username;
  final int port;
  final ConnectionType connectionType;
  final String? host;

  ConnectedEvent({
    required this.sessionId,
    required this.displayName,
    required this.username,
    required this.port,
    this.connectionType = ConnectionType.iroh,
    this.host,
  });

  @override
  Map<String, dynamic> toJson() => {
        'type': 'connected',
        'sessionId': sessionId,
        'displayName': displayName,
        'username': username,
        'port': port,
        'connectionType': connectionType.name,
        if (host != null) 'host': host,
      };

  factory ConnectedEvent.fromJson(Map<String, dynamic> json) => ConnectedEvent(
        sessionId: json['sessionId'] as String,
        displayName: json['displayName'] as String,
        username: json['username'] as String,
        port: json['port'] as int,
        connectionType: _parseConnectionType(json['connectionType'] as String?),
        host: json['host'] as String?,
      );

  static ConnectionType _parseConnectionType(String? value) {
    if (value == null) return ConnectionType.iroh;
    return ConnectionType.values.where((e) => e.name == value).firstOrNull ??
        ConnectionType.iroh;
  }
}

class DisconnectedEvent extends ServiceEvent {
  final String sessionId;
  final String reason;

  DisconnectedEvent({required this.sessionId, required this.reason});

  @override
  Map<String, dynamic> toJson() => {
        'type': 'disconnected',
        'sessionId': sessionId,
        'reason': reason,
      };

  factory DisconnectedEvent.fromJson(Map<String, dynamic> json) =>
      DisconnectedEvent(
        sessionId: json['sessionId'] as String,
        reason: json['reason'] as String,
      );
}

class OutputEvent extends ServiceEvent {
  final String sessionId;
  final String dataBase64;

  OutputEvent({required this.sessionId, required this.dataBase64});

  @override
  Map<String, dynamic> toJson() => {
        'type': 'output',
        'sessionId': sessionId,
        'data': dataBase64,
      };

  factory OutputEvent.fromJson(Map<String, dynamic> json) => OutputEvent(
        sessionId: json['sessionId'] as String,
        dataBase64: json['data'] as String,
      );
}

class ReplayEvent extends ServiceEvent {
  final String sessionId;
  final String dataBase64;

  ReplayEvent({required this.sessionId, required this.dataBase64});

  @override
  Map<String, dynamic> toJson() => {
        'type': 'replay',
        'sessionId': sessionId,
        'data': dataBase64,
      };

  factory ReplayEvent.fromJson(Map<String, dynamic> json) => ReplayEvent(
        sessionId: json['sessionId'] as String,
        dataBase64: json['data'] as String,
      );
}

class SessionSummary {
  final String sessionId;
  final String displayName;
  final String username;
  final int port;
  final String state;

  SessionSummary({
    required this.sessionId,
    required this.displayName,
    required this.username,
    required this.port,
    required this.state,
  });

  Map<String, dynamic> toJson() => {
        'sessionId': sessionId,
        'displayName': displayName,
        'username': username,
        'port': port,
        'state': state,
      };

  factory SessionSummary.fromJson(Map<String, dynamic> json) => SessionSummary(
        sessionId: json['sessionId'] as String,
        displayName: json['displayName'] as String,
        username: json['username'] as String,
        port: json['port'] as int,
        state: json['state'] as String,
      );
}

class SessionListEvent extends ServiceEvent {
  final List<SessionSummary> sessions;

  SessionListEvent({required this.sessions});

  @override
  Map<String, dynamic> toJson() => {
        'type': 'session_list',
        'sessions': sessions.map((s) => s.toJson()).toList(),
      };

  factory SessionListEvent.fromJson(Map<String, dynamic> json) =>
      SessionListEvent(
        sessions: (json['sessions'] as List)
            .map((s) => SessionSummary.fromJson(s as Map<String, dynamic>))
            .toList(),
      );
}

class AuthPromptEvent extends ServiceEvent {
  final String sessionId;
  final String prompt;
  final bool echo;

  AuthPromptEvent({
    required this.sessionId,
    required this.prompt,
    required this.echo,
  });

  @override
  Map<String, dynamic> toJson() => {
        'type': 'auth_prompt',
        'sessionId': sessionId,
        'prompt': prompt,
        'echo': echo,
      };

  factory AuthPromptEvent.fromJson(Map<String, dynamic> json) =>
      AuthPromptEvent(
        sessionId: json['sessionId'] as String,
        prompt: json['prompt'] as String,
        echo: json['echo'] as bool,
      );
}

class ErrorEvent extends ServiceEvent {
  final String? sessionId;
  final String message;

  ErrorEvent({this.sessionId, required this.message});

  @override
  Map<String, dynamic> toJson() => {
        'type': 'error',
        if (sessionId != null) 'sessionId': sessionId,
        'message': message,
      };

  factory ErrorEvent.fromJson(Map<String, dynamic> json) => ErrorEvent(
        sessionId: json['sessionId'] as String?,
        message: json['message'] as String,
      );
}

class StatusEvent extends ServiceEvent {
  final String sessionId;
  final String message;

  StatusEvent({required this.sessionId, required this.message});

  @override
  Map<String, dynamic> toJson() => {
        'type': 'status',
        'sessionId': sessionId,
        'message': message,
      };

  factory StatusEvent.fromJson(Map<String, dynamic> json) => StatusEvent(
        sessionId: json['sessionId'] as String,
        message: json['message'] as String,
      );
}
