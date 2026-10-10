import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

class OpenKeychainProvider {
  final String packageName;
  final String label;

  const OpenKeychainProvider({required this.packageName, required this.label});

  factory OpenKeychainProvider.fromJson(Map<Object?, Object?> json) =>
      OpenKeychainProvider(
        packageName: json['packageName']! as String,
        label: json['label']! as String,
      );
}

class OpenKeychainSelection {
  final String keyId;
  final String description;

  const OpenKeychainSelection({required this.keyId, required this.description});

  factory OpenKeychainSelection.fromJson(Map<Object?, Object?> json) =>
      OpenKeychainSelection(
        keyId: json['keyId']! as String,
        description: json['description']! as String,
      );
}

class OpenKeychainKey {
  final String providerPackage;
  final String providerLabel;
  final String keyId;
  final String description;
  final String publicKeyString;

  const OpenKeychainKey({
    required this.providerPackage,
    required this.providerLabel,
    required this.keyId,
    required this.description,
    required this.publicKeyString,
  });

  String get id => '$providerPackage:$keyId';

  Map<String, dynamic> toJson() => {
    'providerPackage': providerPackage,
    'providerLabel': providerLabel,
    'keyId': keyId,
    'description': description,
    'publicKeyString': publicKeyString,
  };

  factory OpenKeychainKey.fromJson(Map<String, dynamic> json) =>
      OpenKeychainKey(
        providerPackage: json['providerPackage'] as String,
        providerLabel: json['providerLabel'] as String,
        keyId: json['keyId'] as String,
        description: json['description'] as String,
        publicKeyString: json['publicKeyString'] as String,
      );

  SSHIdentity createIdentity({OpenKeychainClient? client}) {
    final parsed = parseOpenSshPublicKey(publicKeyString);
    final authType = switch (parsed.type) {
      'ssh-rsa' => 'rsa-sha2-256',
      'ssh-ed25519' => 'ssh-ed25519',
      'ecdsa-sha2-nistp256' => 'ecdsa-sha2-nistp256',
      'ecdsa-sha2-nistp384' => 'ecdsa-sha2-nistp384',
      'ecdsa-sha2-nistp521' => 'ecdsa-sha2-nistp521',
      _ => throw UnsupportedError(
        'OpenKeychain returned unsupported SSH key type ${parsed.type}',
      ),
    };
    final hashAlgorithm = switch (authType) {
      'rsa-sha2-256' || 'ecdsa-sha2-nistp256' => OpenKeychainClient.sha256,
      'ecdsa-sha2-nistp384' => OpenKeychainClient.sha384,
      'ssh-ed25519' || 'ecdsa-sha2-nistp521' => OpenKeychainClient.sha512,
      _ => throw StateError('No OpenKeychain hash for $authType'),
    };
    final signer = client ?? OpenKeychainClient.instance;

    return SSHIdentity.custom(
      type: authType,
      publicKey: SSHRawHostKey(Uint8List.fromList(parsed.blob)),
      shouldProbe: true,
      comment: description,
      signer: (challenge) async {
        final signature = await signer.sign(
          providerPackage: providerPackage,
          keyId: keyId,
          challenge: challenge,
          hashAlgorithm: hashAlgorithm,
        );
        final signatureType = SSHSignature.getType(signature);
        if (signatureType != authType) {
          throw StateError(
            'OpenKeychain returned $signatureType for authentication algorithm $authType',
          );
        }
        return SSHRawSignature(Uint8List.fromList(signature));
      },
    );
  }
}

class ParsedOpenSshPublicKey {
  final String type;
  final Uint8List blob;

  const ParsedOpenSshPublicKey(this.type, this.blob);
}

ParsedOpenSshPublicKey parseOpenSshPublicKey(String value) {
  final fields = value.trim().split(RegExp(r'\s+'));
  if (fields.length < 2) {
    throw const FormatException('Invalid OpenSSH public key');
  }
  late final Uint8List blob;
  try {
    blob = base64Decode(fields[1]);
  } on FormatException {
    throw const FormatException('Invalid OpenSSH public key encoding');
  }
  final encodedType = _readSshString(blob);
  if (fields[0] != encodedType) {
    throw FormatException(
      'OpenSSH public key type ${fields[0]} does not match $encodedType',
    );
  }
  return ParsedOpenSshPublicKey(encodedType, blob);
}

String _readSshString(Uint8List data) {
  if (data.length < 4) throw const FormatException('Invalid SSH key blob');
  final length = ByteData.sublistView(data).getUint32(0);
  if (length == 0 || length > data.length - 4) {
    throw const FormatException('Invalid SSH key blob');
  }
  try {
    return utf8.decode(data.sublist(4, 4 + length));
  } on FormatException {
    throw const FormatException('Invalid SSH key algorithm');
  }
}

class OpenKeychainClient {
  static const sha1 = 0;
  static const sha224 = 1;
  static const sha256 = 2;
  static const sha384 = 3;
  static const sha512 = 4;

  static const _channel = MethodChannel('iroh_ssh/openkeychain');
  static final instance = OpenKeychainClient._();

  OpenKeychainClient._();

  Future<List<OpenKeychainProvider>> listProviders() async {
    final values =
        await _channel.invokeListMethod<Object?>('listProviders') ??
        const <Object?>[];
    return values
        .map(
          (value) =>
              OpenKeychainProvider.fromJson((value! as Map<Object?, Object?>)),
        )
        .toList();
  }

  Future<OpenKeychainSelection> selectKey(String providerPackage) async {
    final value = await _channel.invokeMapMethod<Object?, Object?>(
      'selectKey',
      {'providerPackage': providerPackage},
    );
    if (value == null) throw StateError('OpenKeychain returned no key');
    return OpenKeychainSelection.fromJson(value);
  }

  Future<String> getSshPublicKey({
    required String providerPackage,
    required String keyId,
  }) async {
    final value = await _channel.invokeMethod<String>('getSshPublicKey', {
      'providerPackage': providerPackage,
      'keyId': keyId,
    });
    if (value == null) {
      throw StateError('OpenKeychain returned no SSH public key');
    }
    parseOpenSshPublicKey(value);
    return value;
  }

  Future<Uint8List> sign({
    required String providerPackage,
    required String keyId,
    required Uint8List challenge,
    required int hashAlgorithm,
  }) async {
    final value = await _channel.invokeMethod<Uint8List>('sign', {
      'providerPackage': providerPackage,
      'keyId': keyId,
      'challenge': challenge,
      'hashAlgorithm': hashAlgorithm,
    });
    if (value == null) throw StateError('OpenKeychain returned no signature');
    return value;
  }
}

class OpenKeychainStorage {
  static OpenKeychainStorage? _instance;
  static OpenKeychainStorage get instance =>
      _instance ??= OpenKeychainStorage._();

  OpenKeychainStorage._();

  Future<File> get _file async {
    final directory = await getApplicationDocumentsDirectory();
    return File('${directory.path}/openkeychain_keys.json');
  }

  Future<List<OpenKeychainKey>> listKeys() async {
    final file = await _file;
    if (!await file.exists()) return [];
    try {
      final decoded = jsonDecode(await file.readAsString()) as List<dynamic>;
      return decoded
          .map(
            (value) => OpenKeychainKey.fromJson(
              (value as Map<dynamic, dynamic>).cast<String, dynamic>(),
            ),
          )
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> save(OpenKeychainKey key) async {
    final keys = await listKeys();
    keys.removeWhere((existing) => existing.id == key.id);
    keys.add(key);
    await _write(keys);
  }

  Future<void> delete(String id) async {
    final keys = await listKeys();
    keys.removeWhere((key) => key.id == id);
    await _write(keys);
  }

  Future<void> _write(List<OpenKeychainKey> keys) async {
    final file = await _file;
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(
      jsonEncode(keys.map((key) => key.toJson()).toList()),
    );
    await temporary.rename(file.path);
  }
}
