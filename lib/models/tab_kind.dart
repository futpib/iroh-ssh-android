/// What a session tab shows: an interactive terminal or a file manager.
///
/// Both kinds reuse the same connection plumbing (iroh / ssh / local); the kind
/// only decides whether the post-auth channel is a shell or an SFTP client.
enum TabKind {
  terminal,
  files;

  String get label => switch (this) {
        TabKind.terminal => 'Terminal',
        TabKind.files => 'Files',
      };

  /// Parse defensively — older persisted/serialized data has no `kind`.
  static TabKind parse(String? value) {
    if (value == null) return TabKind.terminal;
    return TabKind.values.where((e) => e.name == value).firstOrNull ??
        TabKind.terminal;
  }
}
