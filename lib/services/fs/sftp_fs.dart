import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:iroh_ssh_app/models/fs_entry.dart';
import 'package:iroh_ssh_app/services/fs/remote_fs.dart';
import 'package:path/path.dart' as p;

/// [RemoteFs] backed by a dartssh2 SFTP client — used for the iroh and ssh
/// transports. The SFTP channel is multiplexed over the same authenticated
/// connection as the terminal would use. All remote paths are POSIX.
class SftpFs implements RemoteFs {
  /// Emit progress at most once per this many bytes, so fast transfers don't
  /// flood the IPC channel / UI with thousands of updates.
  static const _progressChunk = 256 * 1024;

  final SftpClient _sftp;

  SftpFs(this._sftp);

  @override
  String join(String dir, String name) => p.posix.join(dir, name);

  @override
  String parentOf(String path) {
    final parent = p.posix.dirname(path);
    return parent.isEmpty ? '/' : parent;
  }

  @override
  Future<String> initialDir() async {
    try {
      // SSH_FXP_REALPATH('.') resolves the login/home directory.
      return await _sftp.absolute('.');
    } catch (_) {
      return '.';
    }
  }

  @override
  Future<List<FsEntry>> list(String path) async {
    final names = await _sftp.listdir(path);
    final entries = <FsEntry>[];
    for (final name in names) {
      if (name.filename == '.' || name.filename == '..') continue;
      entries.add(_toEntry(p.posix.join(path, name.filename), name.attr));
    }
    return entries;
  }

  @override
  Future<FsEntry> stat(String path, {bool followLink = true}) async {
    final attr = await _sftp.stat(path, followLink: followLink);
    return _toEntry(path, attr);
  }

  @override
  Future<void> mkdir(String path) => _sftp.mkdir(path);

  @override
  Future<void> rename(String from, String to) => _sftp.rename(from, to);

  @override
  Future<void> remove(String path, {bool recursive = false}) async {
    // lstat semantics: inspect the link itself, never its target, so a symlink
    // is unlinked rather than followed (avoids escaping the subtree / loops).
    final attr = await _sftp.stat(path, followLink: false);
    if (attr.isDirectory) {
      if (recursive) {
        final children = await _sftp.listdir(path);
        for (final child in children) {
          if (child.filename == '.' || child.filename == '..') continue;
          await remove(p.posix.join(path, child.filename), recursive: true);
        }
      }
      // rmdir is non-recursive; the walk above emptied it (or it was empty).
      await _sftp.rmdir(path);
    } else {
      await _sftp.remove(path);
    }
  }

  @override
  Stream<int> download(String remotePath, String localPath) async* {
    final file = await _sftp.open(remotePath); // read mode is the default
    try {
      final sink = File(localPath).openWrite();
      try {
        var transferred = 0;
        var lastEmitted = 0;
        // read() streams with windowed flow-control — never loads the whole
        // file. Cancelling our subscription breaks this loop and runs finally.
        await for (final chunk in file.read()) {
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
    } finally {
      await file.close();
    }
  }

  @override
  Stream<int> upload(String localPath, String remotePath) {
    late StreamController<int> controller;
    SftpFile? file;
    SftpFileWriter? writer;
    var cancelled = false;

    Future<void> run() async {
      try {
        final local = File(localPath);
        file = await _sftp.open(
          remotePath,
          mode: SftpFileOpenMode.create |
              SftpFileOpenMode.truncate |
              SftpFileOpenMode.write,
        );
        if (cancelled) return;
        var lastEmitted = 0;
        var lastTotal = 0;
        writer = file!.write(
          local.openRead().cast<Uint8List>(),
          onProgress: (total) {
            lastTotal = total;
            if (!controller.isClosed && total - lastEmitted >= _progressChunk) {
              lastEmitted = total;
              controller.add(total);
            }
          },
        );
        await writer!.done;
        if (!controller.isClosed && lastTotal != lastEmitted) {
          controller.add(lastTotal);
        }
      } catch (e, st) {
        if (!controller.isClosed) controller.addError(e, st);
      } finally {
        try {
          await file?.close();
        } catch (_) {}
        if (!controller.isClosed) await controller.close();
      }
    }

    controller = StreamController<int>(
      onListen: run,
      onCancel: () async {
        cancelled = true;
        try {
          await writer?.abort();
        } catch (_) {}
      },
    );
    return controller.stream;
  }

  @override
  Future<void> close() async {
    try {
      _sftp.close();
    } catch (_) {}
  }

  FsEntry _toEntry(String path, SftpFileAttrs attr) {
    // attr fields are all nullable; when `mode` is absent the type helpers all
    // return false, which we surface as a plain (non-dir, non-link) entry.
    return FsEntry(
      name: p.posix.basename(path),
      path: path,
      isDir: attr.isDirectory,
      isLink: attr.isSymbolicLink,
      size: attr.size,
      mtime: attr.modifyTime,
      mode: attr.mode?.value,
    );
  }
}
