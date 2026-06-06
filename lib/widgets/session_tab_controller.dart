/// The slice of a session tab's state that [SessionsScreen] drives directly.
///
/// Implemented by both `TerminalTabState` and `FileManagerTabState` so the two
/// tab kinds can share one tab list and focus/readiness handling.
abstract class SessionTabController {
  void requestFocus();
  void disableFocus();
  void enableFocus();

  /// Whether the tab's underlying connection is ready (shell or SFTP open).
  bool get shellReady;

  /// Give the tab a chance to consume the Android system back button (e.g. a
  /// file-manager tab navigating up a directory). Return true if consumed, so
  /// the host shouldn't also pop/close the session.
  bool handleBack();
}
