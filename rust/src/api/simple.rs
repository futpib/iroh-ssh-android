use flutter_rust_bridge::frb;

pub struct IrohConnectionInfo {
    pub is_direct: bool,
    pub is_relay: bool,
    pub relay_url: Option<String>,
    pub latency_ms: Option<f64>,
}

#[frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils_with_log_level(if cfg!(debug_assertions) {
        log::LevelFilter::Trace
    } else {
        log::LevelFilter::Warn
    });
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
    max_remote_nat_traversal_addresses: Option<u8>,
) -> anyhow::Result<u16> {
    iroh_ssh::bridge::connect(
        endpoint_id,
        iroh_ssh::bridge::ConnectOptions {
            relay_urls,
            extra_relay_urls,
            max_remote_nat_traversal_addresses,
        },
    )
    .await
}

/// Disconnect a connection by its port.
pub async fn disconnect_iroh(port: u16) -> anyhow::Result<()> {
    iroh_ssh::bridge::disconnect(port).await
}

/// Disconnect all active connections.
pub async fn disconnect_all() -> anyhow::Result<()> {
    iroh_ssh::bridge::disconnect_all().await
}

/// Get the number of active connections.
pub async fn connection_count() -> usize {
    iroh_ssh::bridge::connections().await.len()
}

/// Query connection info for an active connection by its port.
/// Returns `None` if no iroh connection has been established yet.
pub async fn connection_info(port: u16) -> anyhow::Result<Option<IrohConnectionInfo>> {
    let info = iroh_ssh::bridge::connection_info(port).await?;
    Ok(info.map(|i| IrohConnectionInfo {
        is_direct: i.is_direct,
        is_relay: i.is_relay,
        relay_url: i.relay_url,
        latency_ms: i.latency_ms,
    }))
}
