import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

class SavedConnection {
  final String target;
  final List<String> relayUrls;
  final List<String> extraRelayUrls;

  SavedConnection({
    required this.target,
    this.relayUrls = const [],
    this.extraRelayUrls = const [],
  });

  String get username => target.split('@').first;
  String get endpointId => target.split('@').skip(1).join('@');

  Map<String, dynamic> toJson() => {
        'target': target,
        'relayUrls': relayUrls,
        'extraRelayUrls': extraRelayUrls,
      };

  factory SavedConnection.fromJson(Map<String, dynamic> json) {
    return SavedConnection(
      target: json['target'] as String,
      relayUrls: (json['relayUrls'] as List?)?.cast<String>() ?? [],
      extraRelayUrls: (json['extraRelayUrls'] as List?)?.cast<String>() ?? [],
    );
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
