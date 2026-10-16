import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openkeychain_ssh/openkeychain_ssh.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(openKeychainChannelName);

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'OpenKeychain identity signs without exposing private key material',
    () async {
      final publicBlob = _sshFields([
        utf8.encode('ssh-ed25519'),
        List<int>.filled(32, 7),
      ]);
      final signature = _sshFields([
        utf8.encode('ssh-ed25519'),
        List<int>.filled(64, 9),
      ]);
      final key = OpenKeychainKey(
        providerPackage: 'org.example.keys',
        providerLabel: 'Example keys',
        keyId: '42',
        description: 'alice@example.com',
        publicKeyString: 'ssh-ed25519 ${base64Encode(publicBlob)} alice',
      );

      MethodCall? signingCall;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            signingCall = call;
            return signature;
          });

      final identity = key.createIdentity();
      final challenge = Uint8List.fromList([1, 2, 3]);
      final signed = await identity.sign(challenge);

      expect(identity.type, 'ssh-ed25519');
      expect(identity.shouldProbe, isTrue);
      expect(identity.toPublicKey().encode(), publicBlob);
      expect(signed.encode(), signature);
      expect(signingCall?.method, 'sign');
      expect(signingCall?.arguments, {
        'providerPackage': 'org.example.keys',
        'keyId': '42',
        'challenge': challenge,
        'hashAlgorithm': OpenKeychainClient.sha512,
      });
    },
  );

  test('RSA OpenKeychain identities request rsa-sha2-256 signatures', () async {
    final publicBlob = _sshFields([
      utf8.encode('ssh-rsa'),
      [1],
      [1],
    ]);
    final signature = _sshFields([
      utf8.encode('rsa-sha2-256'),
      [3, 4, 5],
    ]);
    final key = OpenKeychainKey(
      providerPackage: 'org.example.keys',
      providerLabel: 'Example keys',
      keyId: '7',
      description: 'RSA key',
      publicKeyString: 'ssh-rsa ${base64Encode(publicBlob)}',
    );

    MethodCall? signingCall;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          signingCall = call;
          return signature;
        });

    final identity = key.createIdentity();
    expect(identity.type, 'rsa-sha2-256');
    expect((await identity.sign(Uint8List(1))).encode(), signature);
    expect(
      (signingCall!.arguments as Map<Object?, Object?>)['hashAlgorithm'],
      OpenKeychainClient.sha256,
    );
  });

  test(
    'provider cancellation and wrong signature algorithms fail closed',
    () async {
      final key = OpenKeychainKey(
        providerPackage: 'provider',
        providerLabel: 'Provider',
        keyId: '1',
        description: 'Key',
        publicKeyString:
            'ssh-ed25519 ${base64Encode(_sshFields([utf8.encode('ssh-ed25519'), List<int>.filled(32, 1)]))}',
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (_) async {
        throw PlatformException(code: 'openkeychain_cancelled');
      });
      await expectLater(
        key.createIdentity().sign(Uint8List(1)),
        throwsA(isA<PlatformException>()),
      );
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => _sshFields([
          utf8.encode('ssh-rsa'),
          [1, 2, 3],
        ]),
      );
      await expectLater(
        key.createIdentity().sign(Uint8List(1)),
        throwsStateError,
      );
    },
  );

  test('rejects mismatched and unsupported SSH public keys', () {
    final ed25519Blob = _sshFields([
      utf8.encode('ssh-ed25519'),
      List<int>.filled(32, 1),
    ]);
    expect(
      () => parseOpenSshPublicKey('ssh-rsa ${base64Encode(ed25519Blob)}'),
      throwsFormatException,
    );

    final dsaBlob = _sshFields([
      utf8.encode('ssh-dss'),
      [1],
    ]);
    final dsa = OpenKeychainKey(
      providerPackage: 'provider',
      providerLabel: 'Provider',
      keyId: '1',
      description: 'DSA',
      publicKeyString: 'ssh-dss ${base64Encode(dsaBlob)}',
    );
    expect(dsa.createIdentity, throwsUnsupportedError);
  });

  test(
    'cancel releases a pending provider call and ignores its late reply',
    () async {
      final waiting = Completer<Object?>();
      var cancellations = 0;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'cancel') {
          cancellations++;
          return null;
        }
        if (call.method == 'selectKey') return waiting.future;
        throw StateError('Unexpected ${call.method}');
      });

      final operation = OpenKeychainOperation();
      final selection = OpenKeychainClient.instance.selectKey(
        'org.example.keys',
        operation: operation,
      );
      await operation.cancel();
      await expectLater(
        selection,
        throwsA(
          isA<PlatformException>().having(
            (error) => error.code,
            'code',
            'openkeychain_cancelled',
          ),
        ),
      );
      waiting.complete({'keyId': 'late', 'description': 'Late key'});
      await Future<void>.delayed(Duration.zero);
      expect(cancellations, 1);
      operation.dispose();
    },
  );
}

Uint8List _sshFields(List<List<int>> fields) {
  final bytes = BytesBuilder();
  for (final field in fields) {
    final length = field.length;
    bytes.add([
      (length >> 24) & 0xff,
      (length >> 16) & 0xff,
      (length >> 8) & 0xff,
      length & 0xff,
    ]);
    bytes.add(field);
  }
  return bytes.takeBytes();
}
