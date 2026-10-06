import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iroh_ssh_app/services/settings_storage.dart';
import 'package:iroh_ssh_app/services/update_checker.dart';

// Route requests to a real local HTTP server while retaining production parsing,
// headers, error handling and response-stream behavior.
class RealHttpOverrides extends HttpOverrides {}

class LocalClient extends Fake implements HttpClient {
  LocalClient(this.uri);
  final Uri uri;
  final HttpClient client = RealHttpOverrides().createHttpClient(null);
  @override
  set connectionTimeout(Duration? value) => client.connectionTimeout = value;
  @override
  Future<HttpClientRequest> getUrl(Uri url) {
    expect(url, UpdateChecker.latestRelease);
    return client.getUrl(uri);
  }

  @override
  void close({bool force = false}) => client.close(force: force);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  String? installer;
  var version = '26.10.04.02.15';
  setUp(() {
    installer = null;
    version = '26.10.04.02.15';
    SettingsStorage.instance.cache = AppSettings();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(UpdateChecker.channel, (call) async {
          expect(call.method, 'appInfo');
          return {
            'version': version,
            'installer': installer,
            'assetName': 'app-release-fdroid.apk',
            'baseCode': 29,
          };
        });
  });
  tearDown(() {
    SettingsStorage.instance.cache = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(UpdateChecker.channel, null);
  });

  test('installer default and explicit preferences', () async {
    for (final source in [
      null,
      'com.android.shell',
      'dev.imranr.obtainium',
      'dev.imranr.obtainium.fdroid',
      'org.fdroid.fdroid',
    ]) {
      installer = source;
      SettingsStorage.instance.cache = AppSettings();
      expect(
        await UpdateChecker.instance.isEnabled(),
        source != 'dev.imranr.obtainium' &&
            source != 'dev.imranr.obtainium.fdroid',
      );
      for (final choice in [true, false]) {
        SettingsStorage.instance.cache = AppSettings(
          automaticUpdateChecks: choice,
        );
        expect(await UpdateChecker.instance.isEnabled(), choice);
      }
    }
  });

  test('installer lookup failure defaults on', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(UpdateChecker.channel, (_) async {
          throw PlatformException(code: 'unavailable');
        });
    expect(await UpdateChecker.instance.isEnabled(), isTrue);
  });

  test('numeric versions ignore build/ABI codes and reject malformed tags', () {
    expect(UpdateChecker.isNewer('26.10.06.22.00+30', version), isTrue);
    expect(UpdateChecker.isNewer('v26.10.04.02.15+29', version), isFalse);
    expect(UpdateChecker.isNewer('26.09.30.23.59+9999', version), isFalse);
    expect(UpdateChecker.isNewer('26.10.10.00.00+1', version), isTrue);
    expect(UpdateChecker.isNewer('1.0.0+1', '1.0'), isFalse);
    expect(() => UpdateChecker.isNewer('oops', version), throwsFormatException);
  });

  test('settings migrations and other edits preserve explicit preference', () {
    for (final legacy in [
      <String, dynamic>{},
      {
        'relayUrls': ['https://relay'],
      },
      {'useDefaultRelays': true},
    ]) {
      expect(AppSettings.fromJson(legacy).automaticUpdateChecks, isNull);
      for (final value in [true, false]) {
        final settings = AppSettings.fromJson({
          ...legacy,
          'automaticUpdateChecks': value,
        });
        final edited = settings.copyWith(
          terminalFontSize: 18,
          lastConnectionType: 'ssh',
          tabViewStyle: 'grid',
        );
        expect(
          AppSettings.fromJson(edited.toJson()).automaticUpdateChecks,
          value,
        );
        expect(edited.lastConnectionType, 'ssh');
      }
    }
    final settings = AppSettings(
      maxRemoteNatTraversalAddresses: 5,
      automaticUpdateChecks: false,
    ).copyWith(clearMaxRemoteNatTraversalAddresses: true);
    expect(settings.maxRemoteNatTraversalAddresses, isNull);
    expect(settings.automaticUpdateChecks, isFalse);
  });

  test(
    'HTTP checks newer/equal/older releases and surface server/data errors',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var status = 200;
      Object body = {};
      server.listen((request) async {
        expect(
          request.headers.value(HttpHeaders.userAgentHeader),
          'iroh-ssh-android',
        );
        request.response.statusCode = status;
        request.response.write(body is String ? body : jsonEncode(body));
        await request.response.close();
      });
      final checker = UpdateChecker(
        clientFactory: () =>
            LocalClient(Uri.parse('http://127.0.0.1:${server.port}/release')),
      );
      Map<String, Object> release(String tag) => {
        'tag_name': tag,
        'draft': false,
        'prerelease': false,
        'assets': [
          {
            'name': 'app-release-fdroid.apk',
            'size': 4,
            'digest': 'sha256:${'a' * 64}',
            'browser_download_url':
                'https://github.com/futpib/iroh-ssh-android/releases/download/$tag/app-release-fdroid.apk',
          },
        ],
      };
      try {
        SettingsStorage.instance.cache = AppSettings(
          automaticUpdateChecks: false,
        );
        body = release('26.10.06.22.00+30');
        expect(
          (await checker.check())?.tag,
          '26.10.06.22.00+30',
        ); // Manual still works.
        body = release('$version+29');
        expect(await checker.check(), isNull);
        body = release('$version+30');
        expect((await checker.check())?.tag, '$version+30');
        body = release('26.09.01.00.00+1');
        expect(await checker.check(), isNull);
        for (final code in [403, 404, 500]) {
          status = code;
          await expectLater(checker.check(), throwsA(isA<HttpException>()));
        }
        status = 200;
        for (final invalid in [
          'bad json',
          {...release('26.10.06+30'), 'draft': true},
          {...release('26.10.06+30'), 'prerelease': true},
          {...release('26.10.06+30'), 'assets': []},
          release('invalid'),
        ]) {
          body = invalid;
          await expectLater(checker.check(), throwsFormatException);
        }
      } finally {
        await server.close(force: true);
      }
    },
  );
}
