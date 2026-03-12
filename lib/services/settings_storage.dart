import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

class AppSettings {
  final bool useDefaultRelays;
  final List<String> customRelayUrls;
  final int? maxRemoteNatTraversalAddresses;
  final double terminalFontSize;
  final String terminalTheme;
  final String barPosition;
  final String tabViewStyle;

  AppSettings({
    this.useDefaultRelays = true,
    this.customRelayUrls = const [],
    this.maxRemoteNatTraversalAddresses,
    this.terminalFontSize = 14.0,
    this.terminalTheme = 'default',
    this.barPosition = 'bottom',
    this.tabViewStyle = 'list',
  });

  Map<String, dynamic> toJson() => {
        'useDefaultRelays': useDefaultRelays,
        'customRelayUrls': customRelayUrls,
        if (maxRemoteNatTraversalAddresses != null)
          'maxRemoteNatTraversalAddresses': maxRemoteNatTraversalAddresses,
        'terminalFontSize': terminalFontSize,
        'terminalTheme': terminalTheme,
        'barPosition': barPosition,
        'tabViewStyle': tabViewStyle,
      };

  factory AppSettings.fromJson(Map<String, dynamic> json) {
    final maxNat = json['maxRemoteNatTraversalAddresses'] as int?;
    final terminalFontSize =
        (json['terminalFontSize'] as num?)?.toDouble() ?? 14.0;
    final terminalTheme = json['terminalTheme'] as String? ?? 'default';
    final barPosition = json['barPosition'] as String? ?? 'bottom';
    final tabViewStyle = json['tabViewStyle'] as String? ?? 'list';

    // Backwards compat: migrate old relayUrls/extraRelayUrls
    if (json.containsKey('useDefaultRelays')) {
      return AppSettings(
        useDefaultRelays: json['useDefaultRelays'] as bool? ?? true,
        customRelayUrls:
            (json['customRelayUrls'] as List?)?.cast<String>() ?? [],
        maxRemoteNatTraversalAddresses: maxNat,
        terminalFontSize: terminalFontSize,
        terminalTheme: terminalTheme,
        barPosition: barPosition,
        tabViewStyle: tabViewStyle,
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
        maxRemoteNatTraversalAddresses: maxNat,
        terminalFontSize: terminalFontSize,
        terminalTheme: terminalTheme,
        barPosition: barPosition,
        tabViewStyle: tabViewStyle,
      );
    }
    return AppSettings(
      useDefaultRelays: true,
      customRelayUrls: oldExtraRelayUrls,
      maxRemoteNatTraversalAddresses: maxNat,
      terminalFontSize: terminalFontSize,
      terminalTheme: terminalTheme,
      barPosition: barPosition,
    );
  }
}

class SettingsStorage {
  static SettingsStorage? _instance;
  static SettingsStorage get instance => _instance ??= SettingsStorage._();

  SettingsStorage._();

  AppSettings? _cache;

  @visibleForTesting
  set cache(AppSettings? settings) => _cache = settings;

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
