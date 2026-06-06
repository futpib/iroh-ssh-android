import 'package:iroh_ssh_app/models/fs_entry.dart';

/// A minimal virtual filesystem the file-manager UI codes against, independent
/// of transport (SFTP over iroh/ssh, or the local device filesystem) and of
/// execution mode (in-process, or proxied to the background service).
///
/// [download] and [upload] take LOCAL device paths and emit progress as a
/// stream of cumulative bytes-transferred; file contents are never returned
/// through this interface (they stay wherever the implementation runs).
/// Cancelling the returned stream's subscription aborts the transfer.
abstract class RemoteFs {
  /// The directory to open initially (home / login dir / cwd).
  Future<String> initialDir();

  /// List the immediate children of [path] (excluding `.` and `..`).
  Future<List<FsEntry>> list(String path);

  /// Stat a single path. With [followLink] true (default) symlinks are
  /// resolved, so [FsEntry.isDir] reflects the link target.
  Future<FsEntry> stat(String path, {bool followLink = true});

  /// Create a directory at [path].
  Future<void> mkdir(String path);

  /// Rename/move [from] to [to].
  Future<void> rename(String from, String to);

  /// Remove [path]. A non-empty directory requires [recursive] true.
  Future<void> remove(String path, {bool recursive = false});

  /// Copy remote [remotePath] down to local [localPath]; emits bytes transferred.
  Stream<int> download(String remotePath, String localPath);

  /// Copy local [localPath] up to remote [remotePath]; emits bytes transferred.
  Stream<int> upload(String localPath, String remotePath);

  /// Join a directory and a child name using this fs's path semantics.
  String join(String dir, String name);

  /// The parent directory of [path] (for "up" navigation).
  String parentOf(String path);

  /// Release any resources. Safe to call more than once.
  Future<void> close();
}
