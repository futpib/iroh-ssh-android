import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:iroh_ssh_app/services/media_store.dart';
import 'package:path_provider/path_provider.dart';

/// On-device check that downloads land in the device's PUBLIC Downloads via the
/// native MediaStore channel (the code path the analyzer / widget tests can't
/// reach). Run on a booted Android emulator/device:
///   `fvm flutter test integration_test/mediastore_test.dart -d DEVICE_ID`
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('saveToDownloads publishes a file into public Downloads',
      (tester) async {
    // Stage a small source file in the app cache (mirrors the real download).
    final cache = await getTemporaryDirectory();
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final name = 'iroh_probe_$stamp.txt';
    final src = File('${cache.path}/$name');
    await src.writeAsString('iroh-mediastore-probe-$stamp');

    final saved = await MediaStore.saveToDownloads(
      sourcePath: src.path,
      displayName: name,
      mimeType: 'text/plain',
    );

    // On Android 10+ the native MediaStore insert must succeed and report a
    // public Downloads path. (Null would mean it fell back / isn't wired.)
    expect(saved, isNotNull,
        reason: 'MediaStore.saveToDownloads returned null on-device');
    expect(saved, contains('Downloads/'));
    expect(saved, contains(name));

    // Print the name so an external `adb` check can confirm it really landed.
    // ignore: avoid_print
    print('MEDIASTORE_PROBE_NAME=$name');
  });
}
