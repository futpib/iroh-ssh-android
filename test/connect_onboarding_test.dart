import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iroh_ssh_app/screens/connect_screen.dart';
import 'package:iroh_ssh_app/services/settings_storage.dart';

void main() {
  const paths = MethodChannel('plugins.flutter.io/path_provider');

  testWidgets('first run exposes target paste without key promotion', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync(
      'connect-onboarding-',
    );
    await tester.binding.setSurfaceSize(const Size(1080, 1800));
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      paths,
      (_) async => directory.path,
    );
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.getData') {
          return {'text': ' alice@example.com:2222 '};
        }
        return null;
      },
    );
    SettingsStorage.instance.cache = AppSettings(lastConnectionType: 'iroh');

    try {
      await tester.pumpWidget(const MaterialApp(home: ConnectScreen()));
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();

      expect(find.text('Add an SSH key'), findsNothing);
      expect(
        find.textContaining('Password prompts still appear'),
        findsNothing,
      );
      expect(find.text('No saved connections'), findsOneWidget);
      expect(
        find.text('Successful connections are saved here.'),
        findsOneWidget,
      );
      expect(find.byTooltip('Paste target'), findsOneWidget);

      await tester.tap(find.text('SSH'));
      await tester.pump();
      await tester.tap(find.byTooltip('Paste target'));
      await tester.pump();

      final field = tester.widget<TextField>(find.byType(TextField).first);
      expect(field.controller!.text, 'alice@example.com:2222');

      await tester.tap(find.byTooltip('Settings'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Settings'), findsOneWidget);
      expect(find.text('Keys'), findsOneWidget);
    } finally {
      SettingsStorage.instance.cache = null;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        paths,
        null,
      );
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
      await tester.binding.setSurfaceSize(null);
      directory.deleteSync(recursive: true);
    }
  });

  testWidgets('invalid SSH target is rejected inline', (tester) async {
    final directory = Directory.systemTemp.createTempSync(
      'connect-validation-',
    );
    await tester.binding.setSurfaceSize(const Size(1080, 1800));
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      paths,
      (_) async => directory.path,
    );
    SettingsStorage.instance.cache = AppSettings(lastConnectionType: 'ssh');

    try {
      await tester.pumpWidget(const MaterialApp(home: ConnectScreen()));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).first, 'alice@2001:db8::1');
      await tester.tap(find.text('Connect'));
      await tester.pump();

      expect(
        find.text('Use user@host, user@host:port, or user@[IPv6]:port.'),
        findsOneWidget,
      );
    } finally {
      SettingsStorage.instance.cache = null;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        paths,
        null,
      );
      await tester.binding.setSurfaceSize(null);
      directory.deleteSync(recursive: true);
    }
  });
}
