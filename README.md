# iroh-ssh

An Android SSH client powered by [iroh](https://iroh.computer/) for peer-to-peer connections.

## Overview

iroh-ssh lets you open SSH sessions to remote hosts over the iroh peer-to-peer network.
Instead of requiring a routable IP address or VPN, it uses iroh's relay-assisted NAT traversal so you can reach machines behind firewalls or dynamic IPs — as long as both sides run an iroh-ssh endpoint.

The app is built with Flutter and bridges to a Rust core ([iroh-ssh](https://github.com/futpib/iroh-ssh)) via [flutter\_rust\_bridge](https://cjycode.com/flutter_rust_bridge/).

## Features

- **P2P SSH connections** — connect using `user@<endpoint-id>` without a public IP
- **Terminal emulator** — full xterm-compatible terminal with configurable font size and colour theme
- **SSH key management** — generate Ed25519 keys, import existing keys (PEM), copy/export public keys, and export private keys (protected by biometric authentication)
- **QR code scanning** — scan a connection target or private key from a QR code
- **Saved connections** — quickly reconnect to previously used hosts
- **Background sessions** — on Android, sessions run in a foreground service so they survive app backgrounding
- **Configurable relay servers** — use iroh's default relays, add custom relay URLs, or disable relays entirely
- **Cross-platform** — primarily Android; also runs on Linux and macOS via direct Rust connection (no foreground service)

## Usage

1. On the server side, expose an SSH server through [iroh-ssh](https://github.com/futpib/iroh-ssh) and note the endpoint ID it prints.
2. Open the app and type (or scan) the connection target in the form `user@<endpoint-id>`.
3. Tap **Connect**.

The app will establish a peer-to-peer tunnel and open an interactive terminal session.

## Building

Prerequisites:
- [Flutter](https://docs.flutter.dev/get-started/install) (see `.fvmrc` for the pinned version via [fvm](https://fvm.app/))
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
| `lib/screens/` | UI screens (connect, sessions, settings, QR scanner) |
| `lib/services/` | Storage, SSH session management, foreground service IPC |
| `lib/widgets/` | Reusable UI widgets |
| `rust/` | Rust crate — thin FFI bridge to `iroh-ssh` |
| `rust_builder/` | Flutter plugin that compiles the Rust crate |
| `android/` | Android-specific configuration |
