// Build a newer debug APK with the same ABI set, serve it with metadata.json
// containing version, baseCode, assetName, digest and size. Pass the fixture
// directory URL through --dart-define=UPDATE_TEST_SERVER=http://10.0.2.2:8769.
// Grant the debug app REQUEST_INSTALL_PACKAGES via adb appops while this test
// runs, to exercise tampering checks at the install boundary. This test does
// not install the APK or terminate the test runner.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:iroh_ssh_app/services/update_checker.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const server = String.fromEnvironment('UPDATE_TEST_SERVER');
  testWidgets('native APK validation, persistent staging and rejection gates', (
    tester,
  ) async {
    const channel = UpdateChecker.channel;
    final client = HttpClient();
    Future<List<int>> fetch(String name) async {
      final response = await (await client.getUrl(
        Uri.parse('$server/$name'),
      )).close();
      return response.fold<List<int>>(
        [],
        (bytes, chunk) => bytes..addAll(chunk),
      );
    }

    Future<void> download(String name, File file) async {
      final response = await (await client.getUrl(
        Uri.parse('$server/$name'),
      )).close();
      await response.pipe(file.openWrite());
    }

    try {
      await channel.invokeMethod<void>('discardUpdate');
      final metadata =
          jsonDecode(utf8.decode(await fetch('metadata.json')))
              as Map<String, dynamic>;
      final path = (await channel.invokeMethod<String>('downloadPath'))!;
      final file = File(path);
      await file.parent.create(recursive: true);
      await download('candidate.apk', file);
      Future<void> rejected(Map<String, dynamic> args, String message) async {
        await expectLater(
          channel.invokeMethod<void>('prepareUpdate', args),
          throwsA(
            isA<PlatformException>().having(
              (e) => e.message,
              'message',
              contains(message),
            ),
          ),
        );
        final state = await channel.invokeMapMethod('updateState');
        expect(state?['ready'], isFalse);
      }

      await rejected({...metadata, 'digest': '0' * 64}, 'checksum');
      await rejected({
        ...metadata,
        'size': (metadata['size'] as int) + 1,
      }, 'incomplete');
      await rejected({...metadata, 'version': '0.0.0'}, 'version');
      await rejected({...metadata, 'assetName': 'app-release.apk'}, 'variant');
      // Optional signed negative fixtures exercise archive identity, certificate,
      // downgrade and scanner/packaging checks beyond caller metadata.
      for (final name in [
        'wrong-package',
        'wrong-signer',
        'older',
        'wrong-scanner',
        'wrong-packaging',
      ]) {
        final fixture = metadata[name];
        if (fixture is Map) {
          await download('$name.apk', file);
          await rejected(
            Map<String, dynamic>.from(fixture),
            fixture['expectedError'] as String,
          );
        }
      }
      await download('candidate.apk', file);
      await channel.invokeMethod<void>('prepareUpdate', metadata);
      expect((await channel.invokeMapMethod('updateState'))?['ready'], isTrue);
      // Tampering after preparation must be caught again at install time.
      // The permission gate is intentionally before expensive install validation.
      final state = await channel.invokeMapMethod('updateState');
      expect(
        state?['canInstall'],
        isTrue,
        reason:
            'Grant REQUEST_INSTALL_PACKAGES to the debug app during this test.',
      );
      {
        final bytes = await file.readAsBytes();
        bytes[bytes.length - 1] ^= 1;
        await file.writeAsBytes(bytes, flush: true);
        await expectLater(
          channel.invokeMethod<void>('installUpdate'),
          throwsA(
            isA<PlatformException>().having(
              (e) => e.message,
              'message',
              contains('checksum'),
            ),
          ),
        );
      }
      await channel.invokeMethod<void>('discardUpdate');
      expect(await file.exists(), isFalse);
      expect((await channel.invokeMapMethod('updateState'))?['ready'], isFalse);
    } finally {
      client.close(force: true);
    }
  }, skip: server.isEmpty);
}
