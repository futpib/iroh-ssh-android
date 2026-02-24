import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pinenacl/ed25519.dart' as ed25519;

class StoredKey {
  final String name;
  final String publicKeyString;
  final SSHKeyPair keyPair;

  StoredKey({
    required this.name,
    required this.publicKeyString,
    required this.keyPair,
  });
}

class KeyStorage {
  static KeyStorage? _instance;
  static KeyStorage get instance => _instance ??= KeyStorage._();

  KeyStorage._();

  Future<Directory> get _keyDir async {
    final appDir = await getApplicationDocumentsDirectory();
    final dir = Directory('${appDir.path}/ssh_keys');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<StoredKey> generateKey(String name) async {
    final signer = ed25519.SigningKey.generate();
    final publicKey = Uint8List.fromList(signer.verifyKey.asTypedList);
    final privateKey = Uint8List.fromList(signer.asTypedList);

    final keyPair = OpenSSHEd25519KeyPair(publicKey, privateKey, name);
    final pem = keyPair.toPem();

    final dir = await _keyDir;
    await File('${dir.path}/$name').writeAsString(pem);

    return StoredKey(
      name: name,
      publicKeyString: _formatPublicKey(publicKey, name),
      keyPair: keyPair,
    );
  }

  Future<StoredKey> importKey(String name, String pemContent) async {
    final keyPairs = SSHKeyPair.fromPem(pemContent);
    if (keyPairs.isEmpty) {
      throw Exception('No valid key found in PEM data');
    }

    final dir = await _keyDir;
    await File('${dir.path}/$name').writeAsString(pemContent);

    final keyPair = keyPairs.first;
    final publicKeyString = _publicKeyFromPair(keyPair, name);

    return StoredKey(
      name: name,
      publicKeyString: publicKeyString,
      keyPair: keyPair,
    );
  }

  Future<List<StoredKey>> listKeys() async {
    final dir = await _keyDir;
    if (!await dir.exists()) return [];

    final keys = <StoredKey>[];
    await for (final entity in dir.list()) {
      if (entity is File) {
        try {
          final name = entity.uri.pathSegments.last;
          final pem = await entity.readAsString();
          final keyPairs = SSHKeyPair.fromPem(pem);
          if (keyPairs.isNotEmpty) {
            final keyPair = keyPairs.first;
            keys.add(StoredKey(
              name: name,
              publicKeyString: _publicKeyFromPair(keyPair, name),
              keyPair: keyPair,
            ));
          }
        } catch (_) {
          // Skip invalid key files
        }
      }
    }
    return keys;
  }

  Future<void> deleteKey(String name) async {
    final dir = await _keyDir;
    final file = File('${dir.path}/$name');
    if (await file.exists()) {
      await file.delete();
    }
  }

  String _formatPublicKey(Uint8List publicKey, String comment) {
    final writer = SSHMessageWriter();
    writer.writeUtf8('ssh-ed25519');
    writer.writeString(publicKey);
    final blob = base64Encode(writer.takeBytes());
    return 'ssh-ed25519 $blob $comment';
  }

  String _publicKeyFromPair(SSHKeyPair keyPair, String comment) {
    final hostKey = keyPair.toPublicKey();
    final blob = base64Encode(hostKey.encode());
    return '${keyPair.type} $blob $comment';
  }
}

class SSHMessageWriter {
  final _data = BytesBuilder();

  void writeUint32(int value) {
    _data.add([
      (value >> 24) & 0xFF,
      (value >> 16) & 0xFF,
      (value >> 8) & 0xFF,
      value & 0xFF,
    ]);
  }

  void writeString(Uint8List data) {
    writeUint32(data.length);
    _data.add(data);
  }

  void writeUtf8(String text) {
    writeString(Uint8List.fromList(utf8.encode(text)));
  }

  Uint8List takeBytes() => _data.takeBytes();
}
