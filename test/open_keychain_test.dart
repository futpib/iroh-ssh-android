import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iroh_ssh_app/models/connection_type.dart';
import 'package:iroh_ssh_app/services/open_keychain.dart';
import 'package:iroh_ssh_app/services/session_messages.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('iroh_ssh/openkeychain');

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

  test('OpenKeychain key references survive foreground-service IPC', () {
    final publicBlob = _sshFields([
      utf8.encode('ssh-ed25519'),
      List<int>.filled(32, 1),
    ]);
    final key = OpenKeychainKey(
      providerPackage: 'org.sufficientlysecure.keychain',
      providerLabel: 'OpenKeychain',
      keyId: '1234',
      description: 'Test key',
      publicKeyString: 'ssh-ed25519 ${base64Encode(publicBlob)} test',
    );
    final command = ConnectCommand(
      connectionType: ConnectionType.ssh,
      username: 'alice',
      displayName: 'server',
      keyNames: const ['local'],
      openKeychainKeys: [key],
      relayUrls: const [],
      extraRelayUrls: const [],
      host: 'server.example',
      sshPort: 22,
    );

    final decoded = ServiceCommand.decode(command.encode()) as ConnectCommand;

    expect(decoded.openKeychainKeys, hasLength(1));
    expect(decoded.openKeychainKeys.single.id, key.id);
    expect(
      decoded.openKeychainKeys.single.publicKeyString,
      key.publicKeyString,
    );
  });

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
