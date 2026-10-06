import 'dart:async';
import 'dart:io';

import 'package:iroh_ssh_app/services/update_release.dart';

class UpdateDownloadCancelled implements Exception {}

/// Streams to an app-private temporary file; only a complete download is renamed.
/// Cancellation closes the socket even while waiting for headers/body data.
class UpdateDownloader {
  UpdateDownloader({HttpClient Function()? clientFactory})
    : _clientFactory = clientFactory ?? HttpClient.new;
  final HttpClient Function() _clientFactory;
  HttpClient? _client;
  bool _cancelled = false;

  void cancel() {
    _cancelled = true;
    _client?.close(force: true);
  }

  static bool allowedUrl(Uri uri) =>
      uri.scheme == 'https' &&
      uri.port == 443 &&
      uri.userInfo.isEmpty &&
      const {
        'github.com',
        'release-assets.githubusercontent.com',
        'objects.githubusercontent.com',
      }.contains(uri.host);

  Future<void> download(
    UpdateRelease release,
    File destination,
    void Function(int bytes) onProgress,
  ) async {
    if (_client != null) throw StateError('A download is already running');
    _cancelled = false;
    final client = _clientFactory();
    _client = client;
    client.connectionTimeout = const Duration(seconds: 15);
    final partial = File('${destination.path}.part');
    RandomAccessFile? output;
    var complete = false;
    try {
      await partial.parent.create(recursive: true);
      output = await partial.open(mode: FileMode.write);
      var uri = release.url;
      HttpClientResponse? response;
      for (var redirects = 0; redirects <= 5; redirects++) {
        if (_cancelled) throw UpdateDownloadCancelled();
        if (!allowedUrl(uri)) {
          throw const FormatException('Untrusted download URL');
        }
        final request = await client
            .getUrl(uri)
            .timeout(const Duration(seconds: 20));
        request.followRedirects = false;
        request.headers.set(HttpHeaders.userAgentHeader, 'iroh-ssh-android');
        response = await request.close().timeout(const Duration(seconds: 20));
        if (response.isRedirect) {
          final location = response.headers.value(HttpHeaders.locationHeader);
          if (location == null || redirects == 5) {
            throw const HttpException('Invalid download redirect');
          }
          uri = uri.resolve(location);
          await response.drain<void>().timeout(const Duration(seconds: 20));
          continue;
        }
        break;
      }
      if (response == null || response.statusCode != HttpStatus.ok) {
        throw HttpException('Download returned ${response?.statusCode}');
      }
      if (response.contentLength >= 0 &&
          response.contentLength != release.size) {
        throw const FormatException('APK size does not match the release');
      }
      var received = 0;
      var reported = 0;
      await for (final chunk in response.timeout(const Duration(seconds: 30))) {
        if (_cancelled) throw UpdateDownloadCancelled();
        received += chunk.length;
        if (received > release.size) {
          throw const FormatException('APK larger than expected');
        }
        await output.writeFrom(chunk);
        if (received - reported >= 128 * 1024 || received == release.size) {
          onProgress(received);
          reported = received;
        }
      }
      if (_cancelled) throw UpdateDownloadCancelled();
      if (received != release.size) {
        throw const FormatException('Incomplete APK download');
      }
      await output.close();
      output = null;
      if (_cancelled) throw UpdateDownloadCancelled();
      await partial.rename(destination.path);
      complete = true;
    } catch (_) {
      if (_cancelled) throw UpdateDownloadCancelled();
      rethrow;
    } finally {
      client.close(force: true);
      _client = null;
      await output?.close();
      if (!complete && await partial.exists()) await partial.delete();
    }
  }
}
