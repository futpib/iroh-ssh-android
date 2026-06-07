/// Pure (Flutter-free) helpers for the transfer progress notification text, so
/// the formatting is unit-testable without a running engine.
library;

/// The notification body for a transfer, e.g. "1.2 MB / 5.0 MB (24%)" or, when
/// the total size is unknown, just "1.2 MB".
String transferText(int transferred, int? total) {
  if (total != null && total > 0) {
    final pct = ((transferred / total) * 100).clamp(0, 100).round();
    return '${fmtSize(transferred)} / ${fmtSize(total)} ($pct%)';
  }
  return fmtSize(transferred);
}

/// Human-readable byte size (e.g. "1.2 MB").
String fmtSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  double v = bytes / 1024;
  int i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(v >= 10 ? 0 : 1)} ${units[i]}';
}
