import 'package:flutter/services.dart';

/// Drives the native per-transfer progress notifications (real progress bar +
/// Cancel action) over the `iroh_ssh/transfer` channel. Lives in the
/// foreground-service isolate, where transfers run — never the UI isolate.
///
/// The native side (registered on the service engine via FgtEngineListener)
/// posts/updates/cancels the notifications, and calls back `onCancel` when the
/// user taps the notification's Cancel action.
class TransferNotifications {
  static const _channel = MethodChannel('iroh_ssh/transfer');

  /// Invoked (with the transfer's requestId) when the user taps Cancel on a
  /// transfer notification.
  void Function(String requestId)? onCancel;

  TransferNotifications() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onCancel') {
        onCancel?.call(call.arguments as String);
      }
    });
  }

  /// Show or update a transfer notification. [max]/[progress] drive the bar;
  /// pass [indeterminate] when the total size is unknown. [ongoing] true makes
  /// it non-swipeable (while transferring); set false for a final state.
  Future<void> show({
    required String requestId,
    required String title,
    required String text,
    required bool isUpload,
    int? max,
    int progress = 0,
    bool indeterminate = false,
    bool ongoing = true,
    bool showCancel = true,
  }) async {
    try {
      await _channel.invokeMethod('show', {
        'requestId': requestId,
        'title': title,
        'text': text,
        'isUpload': isUpload,
        'max': max ?? 0,
        'progress': progress,
        'indeterminate': indeterminate,
        'ongoing': ongoing,
        'showCancel': showCancel,
      });
    } catch (_) {
      // Notifications are best-effort; never let them break a transfer.
    }
  }

  /// Remove a transfer notification entirely (used on user-cancel).
  Future<void> cancel(String requestId) async {
    try {
      await _channel.invokeMethod('cancel', {'requestId': requestId});
    } catch (_) {}
  }
}
