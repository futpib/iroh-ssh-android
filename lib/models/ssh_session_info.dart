import 'package:dartssh2/dartssh2.dart';

class SshSessionInfo {
  final String host;
  final int port;
  final String username;
  final List<SSHKeyPair> identities;
  final String displayName;

  const SshSessionInfo({
    required this.host,
    required this.port,
    required this.username,
    this.identities = const [],
    required this.displayName,
  });
}
