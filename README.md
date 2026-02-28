# iroh-ssh

An Android SSH client powered by [iroh](https://iroh.computer/) for peer-to-peer connections.

[<img src="https://raw.githubusercontent.com/ImranR98/Obtainium/main/assets/graphics/badge_obtainium.png" height="80" alt="Get it on Obtainium">](https://apps.obtainium.imranr.dev/redirect.html?r=obtainium://add/https://github.com/futpib/iroh-ssh-android)

## Overview

iroh-ssh lets you open SSH sessions to remote hosts over the iroh peer-to-peer network.
Instead of requiring a routable IP address or VPN, it uses iroh's relay-assisted NAT traversal so you can reach machines behind firewalls or dynamic IPs — as long as both sides run an iroh-ssh endpoint.

The app is built with Flutter and bridges to a Rust core ([iroh-ssh](https://github.com/futpib/iroh-ssh)) via [flutter\_rust\_bridge](https://cjycode.com/flutter_rust_bridge/).

## Features

- **P2P SSH connections** — connect using `user@<endpoint-id>` without a public IP
- **Direct SSH connections** — connect to any host directly via `user@host` or `user@host:port`
- **Local shell** — open a local terminal session on the device
- **Multiple sessions** — manage several concurrent sessions in tabs
- **Terminal emulator** — full xterm-compatible terminal with configurable font size and colour theme
- **SSH key management** — generate Ed25519 keys, import existing keys (PEM), copy/export public keys, and export private keys (protected by biometric authentication on Android)
- **QR code scanning** — on Android, scan a connection target from a QR code; import a private key from a QR code on all platforms
- **Saved connections** — quickly reconnect to previously used hosts
- **Background sessions** — on Android, sessions run in a foreground service so they survive app backgrounding
- **Configurable relay servers** — use iroh's default relays, add custom relay URLs, or disable relays entirely
- **Cross-platform** — primarily Android; also runs on Linux and macOS (no foreground service)

## Usage

### iroh P2P connection

1. On the server side, expose an SSH server through [iroh-ssh](https://github.com/futpib/iroh-ssh) and note the endpoint ID it prints.
2. Open the app, select the **Iroh** tab, and type (or scan on Android) the connection target in the form `user@<endpoint-id>`.
3. Tap **Connect**.

The app will establish a peer-to-peer tunnel and open an interactive terminal session.

### Direct SSH connection

1. Select the **SSH** tab and enter a target in the form `user@host` or `user@host:port`.
2. Tap **Connect**.

### Local shell

Select the **Local** tab and tap **Open Shell** to start a local terminal session on the device.

## Building

Prerequisites:
- [Flutter](https://docs.flutter.dev/get-started/install) (see `.fvmrc` for the Flutter channel tracked via [fvm](https://fvm.app/))
- [Rust](https://rustup.rs/) with the Android NDK targets (for Android builds)
- [flutter\_rust\_bridge\_codegen](https://cjycode.com/flutter_rust_bridge/integrate/setup_toolchain) for regenerating the FFI bindings

```bash
# Install Flutter dependencies
flutter pub get

# Build and run (Android)
flutter run
```

## Project Structure

| Path | Description |
|------|-------------|
| `lib/` | Flutter/Dart application code |
| `lib/models/` | Data models (session info, connection types) |
| `lib/screens/` | UI screens (connect, sessions, settings, QR scanner) |
| `lib/services/` | Storage, SSH session management, foreground service IPC |
| `lib/widgets/` | Reusable UI widgets |
| `rust/` | Rust crate — thin FFI bridge to `iroh-ssh` |
| `rust_builder/` | Flutter plugin that compiles the Rust crate |
| `android/` | Android-specific configuration |
