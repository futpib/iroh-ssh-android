import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Each transfer owns a directory. Files remain available in Local files if
/// public Downloads is unavailable or publication fails.
class DownloadStorage {
  final Future<Directory> Function() _baseDirectory;

  DownloadStorage({Future<Directory> Function()? baseDirectory})
    : _baseDirectory = baseDirectory ?? getApplicationSupportDirectory;

  Future<DownloadFile> create(String name) async {
    final base = await _baseDirectory();
    final downloads = Directory(p.join(base.path, 'downloads'));
    await downloads.create(recursive: true);
    final directory = await downloads.createTemp('download-');
    final basename = p.basename(name);
    return DownloadFile(
      directory,
      p.join(
        directory.path,
        basename == '.' || basename == '..' || basename.isEmpty
            ? 'download'
            : basename,
      ),
    );
  }
}

class DownloadFile {
  final Directory directory;
  final String path;

  DownloadFile(this.directory, this.path);

  String get localDisplayPath =>
      'Local files/downloads/${p.basename(directory.path)}/${p.basename(path)}';

  Future<void> delete() async {
    try {
      await directory.delete(recursive: true);
    } on FileSystemException {
      // Cleanup must not turn a successfully published file into a failure.
    }
  }
}
