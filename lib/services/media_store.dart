import 'package:flutter/services.dart';

/// Where a published download landed: a human-readable path to show the user,
/// and a `content://` URI so the completion notification can open the file.
class SavedDownload {
  /// `content://` URI of the published file (for ACTION_VIEW / "open").
  final String uri;

  /// Display path like `"Downloads/<name>"`.
  final String displayPath;

  const SavedDownload({required this.uri, required this.displayPath});

  factory SavedDownload.fromMap(Map<dynamic, dynamic> m) => SavedDownload(
        uri: m['uri'] as String,
        displayPath: m['displayPath'] as String,
      );
}

/// Saves files into the device's **public** Downloads collection via Android
/// MediaStore — so downloads are visible in the system Files app and survive
/// app uninstall, without needing any storage permission (scoped storage).
class MediaStore {
  static const _channel = MethodChannel('iroh_ssh/mediastore');

  /// Copies the file at [sourcePath] into the public `Downloads/` folder and
  /// returns its [SavedDownload] (display path + content URI). The MIME type is
  /// resolved from the file extension natively (falling back to [mimeType]), so
  /// the published file opens with the right app.
  ///
  /// Returns null when the platform can't do it (Android < 10, or non-Android
  /// where the channel isn't registered) — the caller should then fall back to
  /// an app-accessible location.
  static Future<SavedDownload?> saveToDownloads({
    required String sourcePath,
    required String displayName,
    String mimeType = 'application/octet-stream',
  }) async {
    try {
      final m = await _channel.invokeMapMethod<String, dynamic>(
        'saveToDownloads',
        {
          'sourcePath': sourcePath,
          'displayName': displayName,
          'mimeType': mimeType,
        },
      );
      return m == null ? null : SavedDownload.fromMap(m);
    } on MissingPluginException {
      return null; // non-Android (desktop / tests)
    }
  }
}
