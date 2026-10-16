import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:openkeychain_ssh/openkeychain_ssh.dart';

class OpenKeychainStorage {
  static OpenKeychainStorage? _instance;
  static OpenKeychainStorage get instance =>
      _instance ??= OpenKeychainStorage._();

  OpenKeychainStorage._();

  Future<File> get _file async {
    final directory = await getApplicationDocumentsDirectory();
    return File('${directory.path}/openkeychain_keys.json');
  }

  Future<List<OpenKeychainKey>> listKeys() async {
    final file = await _file;
    if (!await file.exists()) return [];
    try {
      final decoded = jsonDecode(await file.readAsString()) as List<dynamic>;
      return decoded
          .map(
            (value) => OpenKeychainKey.fromJson(
              (value as Map<dynamic, dynamic>).cast<String, dynamic>(),
            ),
          )
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> save(OpenKeychainKey key) async {
    final keys = await listKeys();
    keys.removeWhere((existing) => existing.id == key.id);
    keys.add(key);
    await _write(keys);
  }

  Future<void> delete(String id) async {
    final keys = await listKeys();
    keys.removeWhere((key) => key.id == id);
    await _write(keys);
  }

  Future<void> _write(List<OpenKeychainKey> keys) async {
    final file = await _file;
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(
      jsonEncode(keys.map((key) => key.toJson()).toList()),
    );
    await temporary.rename(file.path);
  }
}
