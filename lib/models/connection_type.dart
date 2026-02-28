enum ConnectionType {
  iroh,
  ssh,
  local;

  String get label => switch (this) {
        ConnectionType.iroh => 'Iroh',
        ConnectionType.ssh => 'SSH',
        ConnectionType.local => 'Local',
      };
}
