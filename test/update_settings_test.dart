import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iroh_ssh_app/services/settings_storage.dart';
import 'package:iroh_ssh_app/services/update_checker.dart';
import 'package:iroh_ssh_app/services/update_release.dart';
import 'package:iroh_ssh_app/widgets/update_settings.dart';

class FakeChecker extends UpdateChecker {
  int checks = 0;
  bool enabled = true;
  Future<UpdateRelease?> Function() result = () async => testRelease;
  @override
  Future<bool> isEnabled() async => enabled;
  @override
  Future<UpdateRelease?> check() {
    checks++;
    return result();
  }
}

final testRelease = UpdateRelease(
  tag: '26.10.06.22.00+30',
  assetName: 'app-release-fdroid.apk',
  url: Uri.https('github.com', '/test'),
  digest: 'a' * 64,
  size: 4,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SettingsStorage.instance.cache = AppSettings();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          UpdateChecker.channel,
          (call) async =>
              call.method == 'updateState' ? <String, dynamic>{} : null,
        );
  });
  tearDown(() {
    SettingsStorage.instance.cache = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(UpdateChecker.channel, null);
  });
  testWidgets(
    'startup off makes no request; enabled notice opens release once',
    (tester) async {
      final checker = FakeChecker()..enabled = false;
      Widget app(Key key) => MaterialApp(
        home: UpdateNotice(
          key: key,
          checker: checker,
          child: const Scaffold(body: Text('Terminal')),
        ),
      );
      await tester.pumpWidget(app(const ValueKey(1)));
      await tester.pumpAndSettle();
      expect(checker.checks, 0);
      checker.enabled = true;
      await tester.pumpWidget(app(const ValueKey(2)));
      await tester.pumpAndSettle();
      expect(checker.checks, 1);
      expect(find.textContaining('update available'), findsOneWidget);
      await tester.tap(find.text('Update'));
      await tester.pumpAndSettle();
      expect(find.text('Updates'), findsOneWidget);
      expect(find.textContaining('Download update'), findsOneWidget);
      expect(checker.checks, 1);
    },
  );

  testWidgets(
    'startup failure is silent and disabling during request suppresses notice',
    (tester) async {
      final checker = FakeChecker()
        ..result = () async => throw const SocketException('offline');
      Widget app(Key key) => MaterialApp(
        home: UpdateNotice(
          key: key,
          checker: checker,
          child: const Scaffold(body: Text('Terminal')),
        ),
      );
      await tester.pumpWidget(app(const ValueKey(1)));
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsNothing);
      final pending = Completer<UpdateRelease?>();
      checker.result = () => pending.future;
      await tester.pumpWidget(app(const ValueKey(2)));
      await tester.pump();
      checker.enabled = false;
      pending.complete(testRelease);
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsNothing);
    },
  );

  testWidgets(
    'manual checks while off show current, new release and retryable error',
    (tester) async {
      final checker = FakeChecker()..enabled = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: UpdateSettings(checker: checker)),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
        isFalse,
      );
      await tester.tap(find.text('Check now'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Download update'), findsOneWidget);
      checker.result = () async => null;
      await tester.tap(find.text('Check now'));
      await tester.pumpAndSettle();
      expect(find.text('You’re up to date.'), findsOneWidget);
      checker.result = () async => throw const SocketException('offline');
      await tester.tap(find.text('Check now'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Could not check'), findsOneWidget);
      expect(find.textContaining('Download update'), findsNothing);
      expect(checker.checks, 3);
    },
  );

  testWidgets(
    'toggle persists across disk reload and preserves other settings',
    (tester) async {
      final directory = Directory.systemTemp.createTempSync('update-settings-');
      const paths = MethodChannel('plugins.flutter.io/path_provider');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        paths,
        (_) async => directory.path,
      );
      SettingsStorage.instance.cache = AppSettings(
        terminalFontSize: 19,
        lastConnectionType: 'ssh',
      );
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: UpdateSettings(checker: FakeChecker())),
          ),
        );
        await tester.pumpAndSettle();
        final dynamic toggle = tester
            .widget<SwitchListTile>(find.byType(SwitchListTile))
            .onChanged;
        await tester.runAsync(() async {
          await (toggle(false) as Future<void>);
          SettingsStorage.instance.cache = null;
          final saved = await SettingsStorage.instance.load();
          expect(saved.automaticUpdateChecks, isFalse);
          expect(saved.terminalFontSize, 19);
          expect(saved.lastConnectionType, 'ssh');
        });
        await tester.pumpAndSettle();
      } finally {
        SettingsStorage.instance.cache = null;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          paths,
          null,
        );
        directory.deleteSync(recursive: true);
      }
    },
  );
}
