import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:iroh_ssh_app/services/settings_storage.dart';

class UpdateChecker {
  static final instance = UpdateChecker();
  static const channel = MethodChannel('iroh_ssh/updates');
  static final latestRelease = Uri.https(
    'api.github.com',
    '/repos/futpib/iroh-ssh-android/releases/latest',
  );

  UpdateChecker({HttpClient Function()? clientFactory})
    : _clientFactory = clientFactory ?? HttpClient.new;

  final HttpClient Function() _clientFactory;

  Future<Map<String, dynamic>> appInfo() async =>
      await channel.invokeMapMethod<String, dynamic>('appInfo') ?? {};

  static bool defaultEnabled(String? installer) => !const {
    'dev.imranr.obtainium',
    'dev.imranr.obtainium.fdroid',
  }.contains(installer);

  Future<bool> isEnabled() async {
    final settings = await SettingsStorage.instance.load();
    if (settings.automaticUpdateChecks != null) {
      return settings.automaticUpdateChecks!;
    }
    try {
      return defaultEnabled((await appInfo())['installer'] as String?);
    } catch (_) {
      return true;
    }
  }

  // Compare version names, not Android version codes: split APKs have ABI
  // offsets. Releases use YY.MM.DD.HH.MM+build; local builds can use 1.0.0.
  static bool isNewer(String release, String installed) {
    List<int>? parse(String value) {
      final match = RegExp(r'^v?(\d+(?:\.\d+)*)(?:\+\d+)?$').firstMatch(value);
      return match?[1]?.split('.').map(int.parse).toList();
    }

    final a = parse(release);
    final b = parse(installed);
    if (a == null || b == null) throw const FormatException('Invalid version');
    for (var i = 0; i < a.length || i < b.length; i++) {
      final left = i < a.length ? a[i] : 0;
      final right = i < b.length ? b[i] : 0;
      if (left != right) return left > right;
    }
    return false;
  }

  /// Returns a newer release tag, or null when already current.
  /// Manual calls ignore the automatic-check preference.
  Future<String?> check() async {
    final installed = (await appInfo())['version'] as String?;
    if (installed == null) throw const FormatException('Missing app version');
    final client = _clientFactory();
    client.connectionTimeout = const Duration(seconds: 10);
    try {
      return await (() async {
        final request = await client.getUrl(latestRelease);
        request.headers.set(
          HttpHeaders.acceptHeader,
          'application/vnd.github+json',
        );
        request.headers.set(HttpHeaders.userAgentHeader, 'iroh-ssh-android');
        final response = await request.close();
        if (response.statusCode != HttpStatus.ok) {
          throw HttpException('Update server returned ${response.statusCode}');
        }
        final body = StringBuffer();
        await for (final chunk in response.transform(utf8.decoder)) {
          body.write(chunk);
          if (body.length > 1024 * 1024) {
            throw const FormatException('Release response too large');
          }
        }
        final release = jsonDecode(body.toString()) as Map<String, dynamic>;
        if (release['draft'] != false || release['prerelease'] != false) {
          throw const FormatException('Expected a stable release');
        }
        final tag = release['tag_name'] as String;
        final assets = release['assets'] as List;
        if (!assets.any(
          (asset) =>
              asset is Map &&
              asset['name'] is String &&
              (asset['name'] as String).endsWith('.apk'),
        )) {
          throw const FormatException('Release has no APKs');
        }
        return isNewer(tag, installed) ? tag : null;
      })().timeout(const Duration(seconds: 15));
    } finally {
      client.close(force: true);
    }
  }

  Future<void> openRelease() => channel.invokeMethod<void>('openRelease');
}
