import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iroh_ssh_app/services/settings_storage.dart';
import 'package:iroh_ssh_app/services/update_controller.dart';
import 'package:iroh_ssh_app/services/update_checker.dart';
import 'package:iroh_ssh_app/services/update_downloader.dart';
import 'package:iroh_ssh_app/services/update_release.dart';

class CompletedDownload extends UpdateDownloader {
  @override
  Future<void> download(
    UpdateRelease release,
    File file,
    void Function(int) progress,
  ) async {
    progress(release.size);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late UpdateController controller;
  late List<String> calls;
  late Map<String, dynamic> state;
  bool reject = false;
  bool permission = false;
  String installer = 'dev.imranr.obtainium';
  setUp(() {
    calls = [];
    state = {};
    reject = permission = false;
    installer = 'dev.imranr.obtainium';
    SettingsStorage.instance.cache = AppSettings(automaticUpdateChecks: false);
    controller = UpdateController(downloader: CompletedDownload());
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(UpdateChecker.channel, (call) async {
          calls.add(call.method);
          switch (call.method) {
            case 'appInfo':
              return {'installer': installer};
            case 'downloadPath':
              return '/unused/update.apk';
            case 'prepareUpdate':
              if (reject) {
                throw PlatformException(
                  code: 'UPDATE_ERROR',
                  message: 'APK signing certificate does not match this app.',
                );
              }
              state = {'ready': true, 'version': '26.10.07', 'status': 'ready'};
              return null;
            case 'updateState':
              return state;
            case 'installUpdate':
              if (!permission) state = {...state, 'status': 'installing'};
              return {'permissionRequired': permission};
            case 'discardUpdate':
              state = {};
              return null;
            default:
              return null;
          }
        });
  });
  tearDown(() {
    controller.dispose();
    SettingsStorage.instance.cache = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(UpdateChecker.channel, null);
  });
  UpdateRelease release() => UpdateRelease(
    tag: '26.10.07+31',
    assetName: 'app-release.apk',
    url: Uri.https('github.com', '/test'),
    digest: 'a' * 64,
    size: 100,
  );

  test(
    'download prepares once, cannot install before verification or double-install',
    () async {
      await controller.install();
      expect(calls, isEmpty);
      controller.offer(release());
      await controller.download();
      expect(controller.ready, isTrue);
      expect(calls.where((c) => c == 'prepareUpdate').length, 1);
      expect(calls, isNot(contains('installUpdate')));
      final first = controller.install();
      await controller.install();
      await first;
      expect(calls.where((c) => c == 'installUpdate').length, 1);
      expect(controller.installing, isTrue);
    },
  );
  test(
    'verification rejection offers retry and never invokes installer',
    () async {
      reject = true;
      controller.offer(release());
      await controller.download();
      expect(controller.ready, isFalse);
      expect(controller.busy, isFalse);
      expect(controller.message, contains('certificate'));
      await controller.install();
      expect(calls, isNot(contains('installUpdate')));
      reject = false;
      await controller.download();
      expect(controller.ready, isTrue);
    },
  );
  test(
    'permission round trip retains ready file and requires another install action',
    () async {
      controller.offer(release());
      await controller.download();
      permission = true;
      await controller.install();
      expect(calls, contains('openInstallSettings'));
      expect(controller.ready, isTrue);
      expect(controller.installing, isFalse);
      permission = false;
      await controller.refresh();
      expect(calls.where((c) => c == 'installUpdate').length, 1);
      await controller.install();
      expect(controller.installing, isTrue);
    },
  );
  test(
    'self-update preserves implicit Obtainium preference after installer changes',
    () async {
      final directory = Directory.systemTemp.createTempSync('update-default-');
      const paths = MethodChannel('plugins.flutter.io/path_provider');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(paths, (_) async => directory.path);
      try {
        SettingsStorage.instance.cache = AppSettings(terminalFontSize: 19);
        expect(await controller.checker.isEnabled(), isFalse);
        controller.offer(release());
        await controller.download();
        await controller.install();
        installer = 'com.github.futpib.iroh_ssh_app';
        SettingsStorage.instance.cache = null;
        expect(await controller.checker.isEnabled(), isFalse);
        expect((await SettingsStorage.instance.load()).terminalFontSize, 19);
      } finally {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(paths, null);
        directory.deleteSync(recursive: true);
      }
    },
  );
  test(
    'cancelled install is retryable; startup success comes from native version check',
    () async {
      state = {
        'ready': true,
        'version': '26.10.07',
        'status': 'cancelled',
        'message': 'Installation cancelled. You can retry.',
      };
      await controller.refresh();
      expect(controller.ready, isTrue);
      expect(controller.installing, isFalse);
      expect(controller.message, contains('cancelled'));
      await controller.install();
      expect(controller.installing, isTrue);
      state = {
        'ready': false,
        'status': 'installed',
        'message': 'Updated to 26.10.07.',
      };
      await controller.refresh();
      expect(controller.ready, isFalse);
      expect(controller.message, 'Updated to 26.10.07.');
      expect(calls.last, 'acknowledgeUpdate');
    },
  );
}
