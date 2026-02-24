import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

class AppSettings {
  final List<String> relayUrls;
  final List<String> extraRelayUrls;

  AppSettings({
    this.relayUrls = const [],
    this.extraRelayUrls = const [],
  });

  Map<String, dynamic> toJson() => {
        'relayUrls': relayUrls,
        'extraRelayUrls': extraRelayUrls,
      };

  factory AppSettings.fromJson(Map<String, dynamic> json) {
    return AppSettings(
      relayUrls: (json['relayUrls'] as List?)?.cast<String>() ?? [],
      extraRelayUrls: (json['extraRelayUrls'] as List?)?.cast<String>() ?? [],
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
