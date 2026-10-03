import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class HostKeyChallenge {
  final String host;
  final int port;
  final String keyType;
  final String fingerprint;
  final String? previousFingerprint;

  const HostKeyChallenge({
    required this.host,
    required this.port,
    required this.keyType,
    required this.fingerprint,
    this.previousFingerprint,
  });

  Map<String, dynamic> toJson() => {
    'host': host,
    'port': port,
    'keyType': keyType,
    'fingerprint': fingerprint,
    if (previousFingerprint != null) 'previousFingerprint': previousFingerprint,
  };

  factory HostKeyChallenge.fromJson(Map<String, dynamic> json) =>
      HostKeyChallenge(
        host: json['host'] as String,
        port: json['port'] as int,
        keyType: json['keyType'] as String,
        fingerprint: json['fingerprint'] as String,
        previousFingerprint: json['previousFingerprint'] as String?,
      );
}

/// Direct SSH trust, scoped by hostname and port (not username or tab).
/// All clients in an isolate share the queue, so simultaneous first-use
/// decisions cannot overwrite one another or silently trust a different key.
class KnownHosts {
  static final instance = KnownHosts();
  final Future<File> Function() _file;
  Future<void> _pending = Future.value();

  KnownHosts({Future<File> Function()? file}) : _file = file ?? _defaultFile;

  static Future<File> _defaultFile() async => File(
    p.join((await getApplicationDocumentsDirectory()).path, 'known_hosts.json'),
  );

  Future<bool> verify({
    required String host,
    required int port,
    required String keyType,
    required List<int> fingerprint,
    required Future<bool> Function(HostKeyChallenge) confirm,
  }) {
    final result = _pending.then((_) async {
      final file = await _file();
      // Corrupt/unreadable trust storage must fail closed, not become first use.
      final hosts = await file.exists()
          ? jsonDecode(await file.readAsString()) as Map<String, dynamic>
          : <String, dynamic>{};
      final normalizedHost = host.toLowerCase();
      final address = jsonEncode([normalizedHost, port]);
      final previous = hosts[address] as Map<String, dynamic>?;
      // dartssh2 supplies an already-formatted UTF-8 SHA256 fingerprint.
      final value = utf8.decode(fingerprint);
      if (previous?['keyType'] == keyType &&
          previous?['fingerprint'] == value) {
        return true;
      }
      final accepted = await confirm(
        HostKeyChallenge(
          host: host,
          port: port,
          keyType: keyType,
          fingerprint: value,
          previousFingerprint: previous?['fingerprint'] as String?,
        ),
      );
      if (!accepted) return false;
      hosts[address] = {'keyType': keyType, 'fingerprint': value};
      await file.parent.create(recursive: true);
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(jsonEncode(hosts), flush: true);
      await temporary.rename(file.path);
      return true;
    });
    _pending = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }
}
