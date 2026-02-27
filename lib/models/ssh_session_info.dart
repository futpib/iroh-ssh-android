class SshSessionInfo {
  final String sessionId;
  final String host;
  final int port;
  final String username;
  final List<String> keyNames;
  final String displayName;

  const SshSessionInfo({
    required this.sessionId,
    required this.host,
    required this.port,
    required this.username,
    this.keyNames = const [],
    required this.displayName,
  });

  Map<String, dynamic> toJson() => {
        'sessionId': sessionId,
        'host': host,
        'port': port,
        'username': username,
        'keyNames': keyNames,
        'displayName': displayName,
      };

  factory SshSessionInfo.fromJson(Map<String, dynamic> json) => SshSessionInfo(
        sessionId: json['sessionId'] as String,
        host: json['host'] as String? ?? 'localhost',
        port: json['port'] as int,
        username: json['username'] as String,
        keyNames: (json['keyNames'] as List?)?.cast<String>() ?? [],
        displayName: json['displayName'] as String,
      );
}
