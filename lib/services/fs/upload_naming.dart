/// Helpers for choosing a non-clobbering remote name when uploading: if a file
/// already exists at the target, the upload is renamed `name (1).ext`,
/// `name (2).ext`, … (like a browser's downloads) instead of overwriting it.
library;

/// Insert a ` ($n)` disambiguator into [name], before its extension:
///   `disambiguateFileName('report.txt', 1)`     -> `report (1).txt`
///   `disambiguateFileName('archive.tar.gz', 2)` -> `archive.tar (2).gz`
///   `disambiguateFileName('README', 1)`         -> `README (1)`
///   `disambiguateFileName('.bashrc', 1)`        -> `.bashrc (1)`
/// The extension is whatever follows the LAST dot, except for a leading-dot
/// dotfile or a trailing dot (neither has a real extension to preserve).
String disambiguateFileName(String name, int n) {
  final dot = name.lastIndexOf('.');
  if (dot <= 0 || dot == name.length - 1) {
    return '$name ($n)';
  }
  final stem = name.substring(0, dot);
  final ext = name.substring(dot); // includes the dot
  return '$stem ($n)$ext';
}

/// Resolve a non-clobbering full path for uploading a file named [name] into
/// [dir]. Returns `join(dir, name)` when nothing is there; otherwise the first
/// free `name (n).ext`.
///
/// [listNames] enumerates the existing child names of [dir]. If it throws (e.g.
/// the directory can't be listed), the plain target is returned — the upload
/// then behaves as it did before (best-effort, never blocks the transfer).
Future<String> resolveUploadTarget({
  required String dir,
  required String name,
  required String Function(String dir, String name) join,
  required Future<List<String>> Function(String dir) listNames,
}) async {
  Set<String> taken;
  try {
    taken = (await listNames(dir)).toSet();
  } catch (_) {
    return join(dir, name);
  }
  if (!taken.contains(name)) return join(dir, name);
  for (var n = 1;; n++) {
    final candidate = disambiguateFileName(name, n);
    if (!taken.contains(candidate)) return join(dir, candidate);
  }
}
