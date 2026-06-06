import 'package:flutter/services.dart';

/// Saves files into the device's **public** Downloads collection via Android
/// MediaStore — so downloads are visible in the system Files app and survive
/// app uninstall, without needing any storage permission (scoped storage).
class MediaStore {
  static const _channel = MethodChannel('iroh_ssh/mediastore');

  /// Copies the file at [sourcePath] into the public `Downloads/` folder and
  /// returns a display path like `"Downloads/<name>"`.
  ///
  /// Returns null when the platform can't do it (Android < 10, or non-Android
  /// where the channel isn't registered) — the caller should then fall back to
  /// an app-accessible location.
  static Future<String?> saveToDownloads({
    required String sourcePath,
    required String displayName,
    String mimeType = 'application/octet-stream',
  }) async {
    try {
      return await _channel.invokeMethod<String>('saveToDownloads', {
        'sourcePath': sourcePath,
        'displayName': displayName,
        'mimeType': mimeType,
      });
    } on MissingPluginException {
      return null; // non-Android (desktop / tests)
    }
  }
}
