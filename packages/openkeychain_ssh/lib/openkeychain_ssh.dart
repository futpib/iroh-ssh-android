import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/services.dart';

const openKeychainChannelName = 'io.github.futpib.openkeychain_ssh';

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

/// One cancellable import, including provider lookup and both provider calls.
class OpenKeychainOperation {
  OpenKeychainOperation() {
    _timer = Timer(const Duration(minutes: 2), () => cancel(timedOut: true));
  }
  static int _nextId = 0;
  final String id = 'import-${++_nextId}';
  final _cancelled = Completer<void>();
  late final Timer _timer;
  bool _timedOut = false;
  Future<void>? _cleanup;

  Future<void> cancel({bool timedOut = false}) {
    if (!_cancelled.isCompleted) {
      _timedOut = timedOut;
      _timer.cancel();
      // Native cancellation removes bindings and pending interactions before
      // allowing a retry. The local deadline also handles a broken channel.
      _cleanup = OpenKeychainClient._channel
          .invokeMethod<void>('cancel', {'operationId': id})
          .timeout(const Duration(seconds: 5))
          .catchError((Object _) {});
      _cancelled.complete();
    }
    return _cleanup!;
  }

  Future<T> run<T>(Future<T> Function() work) async {
    if (_cancelled.isCompleted) return _failure<T>();
    Future<T> guarded() async {
      try {
        final value = await work();
        if (_cancelled.isCompleted) return await _failure<T>();
        return value;
      } catch (_) {
        if (_cancelled.isCompleted) return _failure<T>();
        rethrow;
      }
    }

    return Future.any([
      guarded(),
      _cancelled.future.then((_) => _failure<T>()),
    ]);
  }

  Future<T> _failure<T>() async {
    await _cleanup;
    throw PlatformException(
      code: _timedOut ? 'openkeychain_timeout' : 'openkeychain_cancelled',
      message: _timedOut
          ? 'The key provider did not respond within two minutes. Try again.'
          : 'Key import cancelled.',
    );
  }

  void dispose() {
    _timer.cancel();
  }
}

class OpenKeychainClient {
  static const sha1 = 0;
  static const sha224 = 1;
  static const sha256 = 2;
  static const sha384 = 3;
  static const sha512 = 4;

  static const _channel = MethodChannel(openKeychainChannelName);
  static final instance = OpenKeychainClient._();

  OpenKeychainClient._();
  Future<T> _run<T>(
    OpenKeychainOperation? operation,
    Future<T> Function() work,
  ) => operation == null ? work() : operation.run(work);

  Future<List<OpenKeychainProvider>> listProviders({
    OpenKeychainOperation? operation,
  }) async {
    final values =
        await _run(
          operation,
          () => _channel.invokeListMethod<Object?>('listProviders'),
        ) ??
        const <Object?>[];
    return values
        .map(
          (value) =>
              OpenKeychainProvider.fromJson((value! as Map<Object?, Object?>)),
        )
        .toList();
  }

  Future<OpenKeychainSelection> selectKey(
    String providerPackage, {
    OpenKeychainOperation? operation,
  }) async {
    final value = await _run(
      operation,
      () => _channel.invokeMapMethod<Object?, Object?>('selectKey', {
        'providerPackage': providerPackage,
        'operationId': operation?.id,
      }),
    );
    if (value == null) throw StateError('OpenKeychain returned no key');
    return OpenKeychainSelection.fromJson(value);
  }

  Future<String> getSshPublicKey({
    OpenKeychainOperation? operation,
    required String providerPackage,
    required String keyId,
  }) async {
    final value = await _run(
      operation,
      () => _channel.invokeMethod<String>('getSshPublicKey', {
        'providerPackage': providerPackage,
        'keyId': keyId,
        'operationId': operation?.id,
      }),
    );
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
