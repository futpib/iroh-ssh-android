import 'package:iroh_ssh_app/models/connection_type.dart';

class ConnectionTarget {
  const ConnectionTarget({
    required this.connectionType,
    required this.username,
    required this.host,
    required this.port,
  });

  final ConnectionType connectionType;
  final String username;
  final String host;
  final int port;

  String get endpointId => connectionType == ConnectionType.iroh ? host : '';

  String get formatted {
    if (connectionType == ConnectionType.iroh) {
      return '$username@$host';
    }
    final formattedHost = host.contains(':') ? '[$host]' : host;
    final formattedPort = port == 22 ? '' : ':$port';
    return '$username@$formattedHost$formattedPort';
  }

  static ConnectionTarget parse(String input, ConnectionType connectionType) {
    final text = input.trim();
    switch (connectionType) {
      case ConnectionType.iroh:
        final match = RegExp(r'^([^\s@]+)@([a-fA-F0-9]{64})$').firstMatch(text);
        if (match == null) {
          throw const FormatException(
            'Use user@ followed by a 64-character Iroh endpoint ID.',
          );
        }
        return ConnectionTarget(
          connectionType: connectionType,
          username: match[1]!,
          host: match[2]!.toLowerCase(),
          port: 22,
        );
      case ConnectionType.ssh:
        return _parseSsh(text);
      case ConnectionType.local:
        throw const FormatException('A local shell does not use a target.');
    }
  }

  static ConnectionTarget _parseSsh(String text) {
    try {
      final address = RegExp(
        r'^(?:ssh://)?([^\s@:/]+)@(\[[^\]\s]+\]|[^\s@:/?#]+)(?::([0-9]+))?$',
      ).firstMatch(text);
      if (address == null) throw const FormatException();
      final port = address[3] == null ? 22 : int.parse(address[3]!);
      if (port < 1 || port > 65535) throw const FormatException();
      final uri = Uri.parse(text.startsWith('ssh://') ? text : 'ssh://$text');
      if (uri.scheme != 'ssh' ||
          uri.userInfo.isEmpty ||
          uri.userInfo.contains(':') ||
          uri.host.isEmpty ||
          uri.path.isNotEmpty ||
          uri.hasQuery ||
          uri.hasFragment ||
          RegExp(r'\s').hasMatch(text)) {
        throw const FormatException();
      }
      return ConnectionTarget(
        connectionType: ConnectionType.ssh,
        username: Uri.decodeComponent(uri.userInfo),
        host: uri.host,
        port: port,
      );
    } catch (_) {
      throw const FormatException(
        'Use user@host, user@host:port, or user@[IPv6]:port.',
      );
    }
  }
}
