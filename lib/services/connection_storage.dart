import 'dart:convert';
import 'dart:io';

import 'package:iroh_ssh_app/models/connection_type.dart';
import 'package:path_provider/path_provider.dart';

class SavedConnection {
  final String target;
  final ConnectionType connectionType;
  final bool overrideRelays;
  final bool useDefaultRelays;
  final List<String> customRelayUrls;
  final int? maxRemoteNatTraversalAddresses;

  SavedConnection({
    required this.target,
    this.connectionType = ConnectionType.iroh,
    this.overrideRelays = false,
    this.useDefaultRelays = true,
    this.customRelayUrls = const [],
    this.maxRemoteNatTraversalAddresses,
  });

  String get username {
    if (connectionType == ConnectionType.local) return '';
    return target.split('@').first;
  }

  String get endpointId {
    if (connectionType != ConnectionType.iroh) return '';
    return target.split('@').skip(1).join('@');
  }

  String get sshHost {
    if (connectionType != ConnectionType.ssh) return '';
    final afterAt = target.split('@').skip(1).join('@');
    if (afterAt.contains(':')) {
      return afterAt.split(':').first;
    }
    return afterAt;
  }

  int get sshPort {
    if (connectionType != ConnectionType.ssh) return 22;
    final afterAt = target.split('@').skip(1).join('@');
    if (afterAt.contains(':')) {
      return int.tryParse(afterAt.split(':').last) ?? 22;
    }
    return 22;
  }

  Map<String, dynamic> toJson() => {
        'target': target,
        'connectionType': connectionType.name,
        'overrideRelays': overrideRelays,
        'useDefaultRelays': useDefaultRelays,
        'customRelayUrls': customRelayUrls,
        if (maxRemoteNatTraversalAddresses != null)
          'maxRemoteNatTraversalAddresses': maxRemoteNatTraversalAddresses,
      };

  factory SavedConnection.fromJson(Map<String, dynamic> json) {
    final maxNat = json['maxRemoteNatTraversalAddresses'] as int?;
    final connectionType = _parseConnectionType(json['connectionType'] as String?);

    if (json.containsKey('useDefaultRelays')) {
      return SavedConnection(
        target: json['target'] as String,
        connectionType: connectionType,
        overrideRelays: json['overrideRelays'] as bool? ?? false,
        useDefaultRelays: json['useDefaultRelays'] as bool? ?? true,
        customRelayUrls:
            (json['customRelayUrls'] as List?)?.cast<String>() ?? [],
        maxRemoteNatTraversalAddresses: maxNat,
      );
    }
    // Backwards compat: migrate old relayUrls/extraRelayUrls
    final oldRelayUrls =
        (json['relayUrls'] as List?)?.cast<String>() ?? [];
    final oldExtraRelayUrls =
        (json['extraRelayUrls'] as List?)?.cast<String>() ?? [];
    if (oldRelayUrls.isNotEmpty) {
      return SavedConnection(
        target: json['target'] as String,
        connectionType: connectionType,
        useDefaultRelays: false,
        customRelayUrls: oldRelayUrls,
        maxRemoteNatTraversalAddresses: maxNat,
      );
    }
    return SavedConnection(
      target: json['target'] as String,
      connectionType: connectionType,
      useDefaultRelays: true,
      customRelayUrls: oldExtraRelayUrls,
      maxRemoteNatTraversalAddresses: maxNat,
    );
  }

  static ConnectionType _parseConnectionType(String? value) {
    if (value == null) return ConnectionType.iroh;
    return ConnectionType.values.where((e) => e.name == value).firstOrNull ??
        ConnectionType.iroh;
  }
}

class ConnectionStorage {
  static ConnectionStorage? _instance;
  static ConnectionStorage get instance => _instance ??= ConnectionStorage._();

  ConnectionStorage._();

  List<SavedConnection>? _cache;

  Future<File> get _file async {
    final appDir = await getApplicationDocumentsDirectory();
    return File('${appDir.path}/connections.json');
  }

  Future<List<SavedConnection>> list() async {
    if (_cache != null) return _cache!;

    final f = await _file;
    if (!await f.exists()) return [];

    final json = jsonDecode(await f.readAsString()) as List;
    _cache = json.map((e) => SavedConnection.fromJson(e)).toList();
    return _cache!;
  }

  Future<void> save(SavedConnection connection) async {
    final connections = await list();
    final existing = connections.indexWhere((c) => c.target == connection.target);
    if (existing >= 0) {
      connections[existing] = connection;
    } else {
      connections.insert(0, connection);
    }
    await _write(connections);
  }

  Future<void> delete(String target) async {
    final connections = await list();
    connections.removeWhere((c) => c.target == target);
    await _write(connections);
  }

  Future<void> _write(List<SavedConnection> connections) async {
    _cache = connections;
    final f = await _file;
    await f.writeAsString(jsonEncode(connections.map((c) => c.toJson()).toList()));
  }
}
