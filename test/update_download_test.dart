import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:iroh_ssh_app/services/update_downloader.dart';
import 'package:iroh_ssh_app/services/update_release.dart';

class RealHttp extends HttpOverrides {}

class RoutedClient extends Fake implements HttpClient {
  RoutedClient(this.endpoint);
  final Uri endpoint;
  final HttpClient client = RealHttp().createHttpClient(null);
  @override
  set connectionTimeout(Duration? value) => client.connectionTimeout = value;
  @override
  Future<HttpClientRequest> getUrl(Uri url) => client.getUrl(endpoint);
  @override
  void close({bool force = false}) => client.close(force: force);
}

void main() {
  final tag = '26.10.07.01.02+30';
  Map<String, dynamic> asset(String name) => {
    'name': name,
    'size': 5,
    'digest': 'sha256:${'a' * 64}',
    'browser_download_url':
        'https://github.com/futpib/iroh-ssh-android/releases/download/$tag/$name',
  };
  Map<String, dynamic> release(List<Map<String, dynamic>> assets) => {
    'tag_name': tag,
    'draft': false,
    'prerelease': false,
    'assets': assets,
  };

  test('selects exactly the installed asset across all eight variants', () {
    final names = [
      for (final abi in ['', '-arm64-v8a', '-armeabi-v7a', '-x86_64'])
        for (final scanner in ['', '-fdroid']) 'app$abi-release$scanner.apk',
    ];
    final json = release(names.reversed.map(asset).toList());
    for (final name in names) {
      final update = UpdateRelease.fromJson(json, name);
      expect(update.assetName, name);
      expect(update.version, '26.10.07.01.02');
      expect(update.baseCode, 30);
    }
    expect(
      () => UpdateRelease.fromJson(json, 'other.apk'),
      throwsFormatException,
    );
    expect(
      () => UpdateRelease.fromJson(
        release([asset(names[0]), asset(names[0])]),
        names[0],
      ),
      throwsFormatException,
    );
  });

  test('rejects unverifiable, wrong-repository, insecure and oversized assets', () {
    const name = 'app-release.apk';
    for (final patch in [
      {'digest': null},
      {'digest': 'sha256:bad'},
      {'size': 0},
      {'size': 600 * 1024 * 1024},
      {
        'browser_download_url':
            'http://github.com/futpib/iroh-ssh-android/releases/download/$tag/$name',
      },
      {
        'browser_download_url':
            'https://github.com/other/repo/releases/download/$tag/$name',
      },
      {
        'browser_download_url':
            'https://github.com/futpib/iroh-ssh-android/releases/download/wrong/$name',
      },
    ]) {
      expect(
        () => UpdateRelease.fromJson(
          release([
            {...asset(name), ...patch},
          ]),
          name,
        ),
        throwsFormatException,
      );
    }
    expect(
      UpdateDownloader.allowedUrl(
        Uri.parse('https://release-assets.githubusercontent.com/file'),
      ),
      isTrue,
    );
    expect(
      UpdateDownloader.allowedUrl(
        Uri.parse('http://release-assets.githubusercontent.com/file'),
      ),
      isFalse,
    );
    expect(
      UpdateDownloader.allowedUrl(Uri.parse('https://example.com/file')),
      isFalse,
    );
  });

  test(
    'download completion, truncation, HTTP errors, redirect rejection and cancellation cleanup',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final dir = await Directory.systemTemp.createTemp('update-download-');
      final target = File('${dir.path}/update.apk');
      var mode = 'ok';
      final started = Completer<void>();
      server.listen((request) async {
        if (mode == 'error') request.response.statusCode = 503;
        if (mode == 'redirect') {
          request.response.statusCode = 302;
          request.response.headers.set('location', 'http://example.com/apk');
        } else if (mode == 'waiting') {
          request.response.headers.contentType = ContentType.binary;
          request.response.write('a');
          await request.response.flush();
          if (!started.isCompleted) started.complete();
          return;
        } else {
          request.response.write(mode == 'short' ? 'a' : 'hello');
        }
        await request.response.close();
      });
      final downloader = UpdateDownloader(
        clientFactory: () =>
            RoutedClient(Uri.parse('http://127.0.0.1:${server.port}')),
      );
      final update = UpdateRelease.fromJson(
        release([asset('app-release.apk')]),
        'app-release.apk',
      );
      try {
        var received = 0;
        await downloader.download(update, target, (bytes) => received = bytes);
        expect(await target.readAsString(), 'hello');
        expect(received, 5);
        await target.delete();
        for (final scenario in ['short', 'error', 'redirect']) {
          mode = scenario;
          await expectLater(
            downloader.download(update, target, (_) {}),
            throwsA(isA<Exception>()),
          );
          expect(await target.exists(), isFalse);
          expect(await File('${target.path}.part').exists(), isFalse);
        }
        mode = 'waiting';
        final pending = downloader.download(update, target, (_) {});
        final assertion = expectLater(
          pending,
          throwsA(isA<UpdateDownloadCancelled>()),
        );
        await started.future;
        downloader.cancel();
        await assertion;
        expect(await File('${target.path}.part').exists(), isFalse);
        mode = 'ok';
        await downloader.download(update, target, (_) {});
        expect(await target.readAsString(), 'hello');
      } finally {
        await server.close(force: true);
        await dir.delete(recursive: true);
      }
    },
  );
}
