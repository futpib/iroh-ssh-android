import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

class AppSettings {
  final bool useDefaultRelays;
  final List<String> customRelayUrls;

  AppSettings({
    this.useDefaultRelays = true,
    this.customRelayUrls = const [],
  });

  Map<String, dynamic> toJson() => {
        'useDefaultRelays': useDefaultRelays,
        'customRelayUrls': customRelayUrls,
      };

  factory AppSettings.fromJson(Map<String, dynamic> json) {
    // Backwards compat: migrate old relayUrls/extraRelayUrls
    if (json.containsKey('useDefaultRelays')) {
      return AppSettings(
        useDefaultRelays: json['useDefaultRelays'] as bool? ?? true,
        customRelayUrls:
            (json['customRelayUrls'] as List?)?.cast<String>() ?? [],
      );
    }
    final oldRelayUrls =
        (json['relayUrls'] as List?)?.cast<String>() ?? [];
    final oldExtraRelayUrls =
        (json['extraRelayUrls'] as List?)?.cast<String>() ?? [];
    if (oldRelayUrls.isNotEmpty) {
      return AppSettings(
        useDefaultRelays: false,
        customRelayUrls: oldRelayUrls,
      );
    }
    return AppSettings(
      useDefaultRelays: true,
      customRelayUrls: oldExtraRelayUrls,
    );
  }
}

class SettingsStorage {
  static SettingsStorage? _instance;
  static SettingsStorage get instance => _instance ??= SettingsStorage._();

  SettingsStorage._();

  AppSettings? _cache;

  Future<File> get _file async {
    final appDir = await getApplicationDocumentsDirectory();
    return File('${appDir.path}/settings.json');
  }

  Future<AppSettings> load() async {
    if (_cache != null) return _cache!;

    final f = await _file;
    if (!await f.exists()) return AppSettings();

    final json = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
    _cache = AppSettings.fromJson(json);
    return _cache!;
  }

  Future<void> save(AppSettings settings) async {
    _cache = settings;
    final f = await _file;
    await f.writeAsString(jsonEncode(settings.toJson()));
  }
}
