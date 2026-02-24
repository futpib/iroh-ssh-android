use flutter_rust_bridge::frb;

#[frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}

/// Connect to a remote iroh-ssh endpoint.
/// Returns the local TCP port to connect an SSH client to.
///
/// `relay_urls` replaces the default relay servers; `extra_relay_urls` adds alongside them.
/// Pass empty vectors to use defaults.
pub async fn connect_iroh(
    endpoint_id: String,
    relay_urls: Vec<String>,
    extra_relay_urls: Vec<String>,
) -> anyhow::Result<u16> {
    iroh_ssh::bridge::connect_iroh(endpoint_id, relay_urls, extra_relay_urls).await
}

/// Disconnect a connection by its port.
pub async fn disconnect_iroh(port: u16) -> anyhow::Result<()> {
    iroh_ssh::bridge::disconnect_iroh(port).await
}

/// Disconnect all active connections.
pub async fn disconnect_all() -> anyhow::Result<()> {
    iroh_ssh::bridge::disconnect_all().await
}

/// Get the number of active connections.
pub async fn connection_count() -> usize {
    iroh_ssh::bridge::connection_count().await
}
