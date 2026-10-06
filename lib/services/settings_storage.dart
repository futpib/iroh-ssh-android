import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

class AppSettings {
  /// Null uses the installer-based default; a user choice always wins.
  final bool? automaticUpdateChecks;
  final bool useDefaultRelays;
  final List<String> customRelayUrls;
  final int? maxRemoteNatTraversalAddresses;
  final double terminalFontSize;
  final String terminalTheme;
  final String barPosition;
  final String tabViewStyle;
  final String? lastConnectionType;

  AppSettings({
    this.automaticUpdateChecks,
    this.useDefaultRelays = true,
    this.customRelayUrls = const [],
    this.maxRemoteNatTraversalAddresses,
    this.terminalFontSize = 14.0,
    this.terminalTheme = 'default',
    this.barPosition = 'bottom',
    this.tabViewStyle = 'list',
    this.lastConnectionType,
  });

  AppSettings copyWith({
    bool? automaticUpdateChecks,
    bool? useDefaultRelays,
    List<String>? customRelayUrls,
    int? maxRemoteNatTraversalAddresses,
    bool clearMaxRemoteNatTraversalAddresses = false,
    double? terminalFontSize,
    String? terminalTheme,
    String? barPosition,
    String? tabViewStyle,
    String? lastConnectionType,
  }) => AppSettings(
    automaticUpdateChecks: automaticUpdateChecks ?? this.automaticUpdateChecks,
    useDefaultRelays: useDefaultRelays ?? this.useDefaultRelays,
    customRelayUrls: customRelayUrls ?? this.customRelayUrls,
    maxRemoteNatTraversalAddresses: clearMaxRemoteNatTraversalAddresses
        ? null
        : maxRemoteNatTraversalAddresses ?? this.maxRemoteNatTraversalAddresses,
    terminalFontSize: terminalFontSize ?? this.terminalFontSize,
    terminalTheme: terminalTheme ?? this.terminalTheme,
    barPosition: barPosition ?? this.barPosition,
    tabViewStyle: tabViewStyle ?? this.tabViewStyle,
    lastConnectionType: lastConnectionType ?? this.lastConnectionType,
  );

  Map<String, dynamic> toJson() => {
    if (automaticUpdateChecks != null)
      'automaticUpdateChecks': automaticUpdateChecks,
    'useDefaultRelays': useDefaultRelays,
    'customRelayUrls': customRelayUrls,
    if (maxRemoteNatTraversalAddresses != null)
      'maxRemoteNatTraversalAddresses': maxRemoteNatTraversalAddresses,
    'terminalFontSize': terminalFontSize,
    'terminalTheme': terminalTheme,
    'barPosition': barPosition,
    'tabViewStyle': tabViewStyle,
    if (lastConnectionType != null) 'lastConnectionType': lastConnectionType,
  };

  factory AppSettings.fromJson(Map<String, dynamic> json) {
    final maxNat = json['maxRemoteNatTraversalAddresses'] as int?;
    final terminalFontSize =
        (json['terminalFontSize'] as num?)?.toDouble() ?? 14.0;
    final terminalTheme = json['terminalTheme'] as String? ?? 'default';
    final barPosition = json['barPosition'] as String? ?? 'bottom';
    final tabViewStyle = json['tabViewStyle'] as String? ?? 'list';
    final lastConnectionType = json['lastConnectionType'] as String?;

    // Backwards compat: migrate old relayUrls/extraRelayUrls
    if (json.containsKey('useDefaultRelays')) {
      return AppSettings(
        automaticUpdateChecks: json['automaticUpdateChecks'] as bool?,
        useDefaultRelays: json['useDefaultRelays'] as bool? ?? true,
        customRelayUrls:
            (json['customRelayUrls'] as List?)?.cast<String>() ?? [],
        maxRemoteNatTraversalAddresses: maxNat,
        terminalFontSize: terminalFontSize,
        terminalTheme: terminalTheme,
        barPosition: barPosition,
        tabViewStyle: tabViewStyle,
        lastConnectionType: lastConnectionType,
      );
    }
    final oldRelayUrls = (json['relayUrls'] as List?)?.cast<String>() ?? [];
    final oldExtraRelayUrls =
        (json['extraRelayUrls'] as List?)?.cast<String>() ?? [];
    if (oldRelayUrls.isNotEmpty) {
      return AppSettings(
        automaticUpdateChecks: json['automaticUpdateChecks'] as bool?,
        useDefaultRelays: false,
        customRelayUrls: oldRelayUrls,
        maxRemoteNatTraversalAddresses: maxNat,
        terminalFontSize: terminalFontSize,
        terminalTheme: terminalTheme,
        barPosition: barPosition,
        tabViewStyle: tabViewStyle,
        lastConnectionType: lastConnectionType,
      );
    }
    return AppSettings(
      automaticUpdateChecks: json['automaticUpdateChecks'] as bool?,
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
    final f = await _file;
    await f.writeAsString(jsonEncode(settings.toJson()));
    _cache = settings;
  }
}
