/// A single entry in a directory listing, transport-agnostic.
///
/// JSON-serializable so it can cross the UI <-> background-service message
/// channel unchanged. All optional fields mirror SFTP semantics, where the
/// server may omit attributes (`size`, `mtime`, `mode` can all be unknown).
class FsEntry {
  /// Bare entry name (no path separators).
  final String name;

  /// Full POSIX path (for SFTP) or platform path (for local).
  final String path;

  /// Whether the entry itself is a directory. For a symlink this is false even
  /// if it points at a directory — resolve with a follow-link stat on tap.
  final bool isDir;

  /// Whether the entry is a symbolic link.
  final bool isLink;

  /// Size in bytes, or null if unknown.
  final int? size;

  /// Modification time in epoch SECONDS (SFTP's native unit), or null.
  final int? mtime;

  /// Raw permission/type bits, or null if the server omits them.
  final int? mode;

  const FsEntry({
    required this.name,
    required this.path,
    required this.isDir,
    required this.isLink,
    this.size,
    this.mtime,
    this.mode,
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'path': path,
        'isDir': isDir,
        'isLink': isLink,
        if (size != null) 'size': size,
        if (mtime != null) 'mtime': mtime,
        if (mode != null) 'mode': mode,
      };

  factory FsEntry.fromJson(Map<String, dynamic> json) => FsEntry(
        name: json['name'] as String,
        path: json['path'] as String,
        isDir: json['isDir'] as bool,
        isLink: json['isLink'] as bool,
        size: json['size'] as int?,
        mtime: json['mtime'] as int?,
        mode: json['mode'] as int?,
      );
}
