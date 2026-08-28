import 'dart:io';

import 'package:iroh_ssh_app/models/fs_entry.dart';
import 'package:iroh_ssh_app/services/fs/remote_fs.dart';
import 'package:path/path.dart' as p;

/// [RemoteFs] over the local device filesystem (`dart:io`) — used for the
/// `local` transport. Paths use the platform context.
class LocalFs implements RemoteFs {
  /// Emit progress at most once per this many bytes (local copies are fast).
  static const _progressChunk = 256 * 1024;

  String? _navigationRoot;

  @override
  String join(String dir, String name) => p.join(dir, name);

  @override
  String parentOf(String path) {
    final normalized = p.normalize(path);
    final root = _navigationRoot;
    if (root == null) return p.dirname(normalized);
    if (normalized == root || !p.isWithin(root, normalized)) return root;

    final parent = p.dirname(normalized);
    return parent == root || p.isWithin(root, parent) ? parent : root;
  }

  @override
  Future<String> initialDir() async {
    if (Platform.isAndroid) {
      // Android does not provide HOME to the Flutter process, and its process
      // working directory is `/`, which apps cannot enumerate. Keep local-file
      // browsing inside the app's durable files directory: it needs no broad
      // storage permission and avoids exposing settings and SSH keys stored in
      // app_flutter. Directory.systemTemp is the sibling cache directory.
      final filesDir = Directory(
        p.join(Directory.systemTemp.parent.path, 'files'),
      );
      await filesDir.create(recursive: true);
      _navigationRoot = p.normalize(filesDir.absolute.path);
      return _navigationRoot!;
    }

    final home = Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'];
    if (home != null && home.isNotEmpty && Directory(home).existsSync()) {
      return home;
    }
    return Directory.current.path;
  }

  @override
  Future<List<FsEntry>> list(String path) async {
    final entries = <FsEntry>[];
    await for (final entity in Directory(path).list(followLinks: false)) {
      try {
        entries.add(await _toEntry(entity));
      } catch (_) {
        // Dangling symlink or unreadable entry — surface it minimally.
        entries.add(FsEntry(
          name: p.basename(entity.path),
          path: entity.path,
          isDir: false,
          isLink: entity is Link,
        ));
      }
    }
    return entries;
  }

  @override
  Future<FsEntry> stat(String path, {bool followLink = true}) async {
    final type = await FileSystemEntity.type(path, followLinks: followLink);
    final st = await FileStat.stat(path);
    return FsEntry(
      name: p.basename(path),
      path: path,
      isDir: type == FileSystemEntityType.directory,
      isLink: type == FileSystemEntityType.link,
      size: type == FileSystemEntityType.file ? st.size : null,
      mtime: st.modified.millisecondsSinceEpoch ~/ 1000,
      mode: st.mode,
    );
  }

  @override
  Future<void> mkdir(String path) => Directory(path).create();

  @override
  Future<void> rename(String from, String to) async {
    final type = await FileSystemEntity.type(from, followLinks: false);
    if (type == FileSystemEntityType.directory) {
      await Directory(from).rename(to);
    } else if (type == FileSystemEntityType.link) {
      await Link(from).rename(to);
    } else {
      await File(from).rename(to);
    }
  }

  @override
  Future<void> remove(String path, {bool recursive = false}) async {
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type == FileSystemEntityType.directory) {
      await Directory(path).delete(recursive: recursive);
    } else if (type == FileSystemEntityType.link) {
      await Link(path).delete();
    } else {
      await File(path).delete();
    }
  }

  @override
  Stream<int> download(String remotePath, String localPath) =>
      _copy(remotePath, localPath);

  @override
  Stream<int> upload(String localPath, String remotePath) =>
      _copy(localPath, remotePath);

  @override
  Future<void> close() async {}

  /// Stream-copy [srcPath] -> [destPath], yielding cumulative bytes copied.
  Stream<int> _copy(String srcPath, String destPath) async* {
    final sink = File(destPath).openWrite();
    try {
      var transferred = 0;
      var lastEmitted = 0;
      await for (final chunk in File(srcPath).openRead()) {
        sink.add(chunk);
        transferred += chunk.length;
        if (transferred - lastEmitted >= _progressChunk) {
          lastEmitted = transferred;
          yield transferred;
        }
      }
      if (transferred != lastEmitted) yield transferred;
    } finally {
      await sink.close();
    }
  }

  Future<FsEntry> _toEntry(FileSystemEntity entity) async {
    final isLink = entity is Link;
    final st = await entity.stat(); // follows links
    final isDir = isLink
        ? st.type == FileSystemEntityType.directory
        : entity is Directory;
    return FsEntry(
      name: p.basename(entity.path),
      path: entity.path,
      isDir: isDir,
      isLink: isLink,
      size: st.type == FileSystemEntityType.file ? st.size : null,
      mtime: st.modified.millisecondsSinceEpoch ~/ 1000,
      mode: st.mode,
    );
  }
}
