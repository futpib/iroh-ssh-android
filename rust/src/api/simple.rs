use std::str::FromStr;
use std::sync::OnceLock;

use flutter_rust_bridge::frb;
use iroh::{Endpoint, EndpointId};
use tokio::net::TcpListener;
use tokio::sync::{Mutex, watch};

const ALPN: &[u8] = b"/iroh/ssh";

struct ProxyState {
    _endpoint: Endpoint,
    local_port: u16,
    shutdown: watch::Sender<bool>,
}

static INSTANCE: OnceLock<Mutex<Option<ProxyState>>> = OnceLock::new();

fn instance() -> &'static Mutex<Option<ProxyState>> {
    INSTANCE.get_or_init(|| Mutex::new(None))
}

#[frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}

/// Connect to a remote iroh-ssh endpoint.
/// Returns the local TCP port to connect an SSH client to.
pub async fn connect_iroh(endpoint_id: String) -> anyhow::Result<u16> {
    let mut guard = instance().lock().await;
    if guard.is_some() {
        anyhow::bail!("already connected");
    }

    let endpoint = Endpoint::builder().bind().await?;

    let parsed_id = EndpointId::from_str(&endpoint_id)?;

    let listener = TcpListener::bind("127.0.0.1:0").await?;
    let local_port = listener.local_addr()?.port();

    let (shutdown_tx, mut shutdown_rx) = watch::channel(false);

    let ep = endpoint.clone();
    tokio::spawn(async move {
        loop {
            tokio::select! {
                accept = listener.accept() => {
                    match accept {
                        Ok((tcp_stream, _)) => {
                            let ep = ep.clone();
                            let eid = parsed_id;
                            tokio::spawn(async move {
                                if let Err(e) = proxy_connection(tcp_stream, &ep, eid).await {
                                    eprintln!("proxy error: {e}");
                                }
                            });
                        }
                        Err(e) => {
                            eprintln!("accept error: {e}");
                            break;
                        }
                    }
                }
                _ = shutdown_rx.changed() => {
                    break;
                }
            }
        }
    });

    *guard = Some(ProxyState {
        _endpoint: endpoint,
        local_port,
        shutdown: shutdown_tx,
    });

    Ok(local_port)
}

/// Disconnect and clean up.
pub async fn disconnect_iroh() -> anyhow::Result<()> {
    let mut guard = instance().lock().await;
    if let Some(state) = guard.take() {
        let _ = state.shutdown.send(true);
    }
    Ok(())
}

/// Check if currently connected. Returns the local proxy port if connected.
#[frb(sync)]
pub fn get_proxy_port() -> Option<u16> {
    let guard = instance().try_lock().ok()?;
    guard.as_ref().map(|s| s.local_port)
}

async fn proxy_connection(
    mut tcp_stream: tokio::net::TcpStream,
    endpoint: &Endpoint,
    endpoint_id: EndpointId,
) -> anyhow::Result<()> {
    let conn = endpoint.connect(endpoint_id, ALPN).await?;
    let (mut iroh_send, mut iroh_recv) = conn.open_bi().await?;
    let (mut tcp_read, mut tcp_write) = tcp_stream.split();

    tokio::select! {
        r = tokio::io::copy(&mut tcp_read, &mut iroh_send) => { r?; }
        r = tokio::io::copy(&mut iroh_recv, &mut tcp_write) => { r?; }
    };

    Ok(())
}
