import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:iroh_ssh_app/screens/qr_scanner_screen.dart';
import 'package:iroh_ssh_app/services/connection_storage.dart';
import 'package:iroh_ssh_app/services/key_storage.dart';
import 'package:iroh_ssh_app/services/settings_storage.dart';
import 'package:iroh_ssh_app/src/rust/api/simple.dart';
import 'package:iroh_ssh_app/screens/settings_screen.dart';
import 'package:iroh_ssh_app/models/ssh_session_info.dart';
import 'package:iroh_ssh_app/screens/sessions_screen.dart';
import 'package:iroh_ssh_app/widgets/relay_url_list_editor.dart';

class ConnectScreen extends StatefulWidget {
  final bool returnResult;

  const ConnectScreen({super.key, this.returnResult = false});

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  final _targetController = TextEditingController();
  bool _useDefaultRelays = true;
  List<String> _customRelayUrls = [];
  bool _connecting = false;
  String? _error;
  List<SavedConnection> _savedConnections = [];

  @override
  void initState() {
    super.initState();
    _loadConnections();
  }

  Future<void> _loadConnections() async {
    final connections = await ConnectionStorage.instance.list();
    if (mounted) {
      setState(() => _savedConnections = connections);
    }
  }

  @override
  void dispose() {
    _targetController.dispose();
    super.dispose();
  }

  Future<void> _connectTo(String target,
      {bool useDefaultRelays = true,
      List<String> customRelayUrls = const []}) async {
    final String username;
    final String endpointId;

    if (target.contains('@')) {
      final parts = target.split('@');
      username = parts.first;
      endpointId = parts.skip(1).join('@');
    } else {
      setState(() => _error = 'Expected format: user@endpoint_id');
      return;
    }

    setState(() {
      _connecting = true;
      _error = null;
    });

    try {
      final keys = await KeyStorage.instance.listKeys();
      final globalSettings = await SettingsStorage.instance.load();

      final effectiveUseDefaultRelays =
          customRelayUrls.isNotEmpty ? useDefaultRelays : globalSettings.useDefaultRelays;
      final effectiveCustomRelayUrls =
          customRelayUrls.isNotEmpty ? customRelayUrls : globalSettings.customRelayUrls;

      final List<String> relayUrls;
      final List<String> extraRelayUrls;
      if (effectiveUseDefaultRelays) {
        relayUrls = [];
        extraRelayUrls = effectiveCustomRelayUrls;
      } else {
        relayUrls = effectiveCustomRelayUrls;
        extraRelayUrls = [];
      }

      final port = await connectIroh(
        endpointId: endpointId,
        relayUrls: relayUrls,
        extraRelayUrls: extraRelayUrls,
      );

      await ConnectionStorage.instance.save(SavedConnection(
        target: target,
        useDefaultRelays: useDefaultRelays,
        customRelayUrls: customRelayUrls,
      ));
      await _loadConnections();

      if (!mounted) return;

      final sessionInfo = SshSessionInfo(
        host: 'localhost',
        port: port,
        username: username,
        identities: keys.map((k) => k.keyPair).toList(),
        displayName: target,
      );

      if (widget.returnResult) {
        Navigator.of(context).pop(sessionInfo);
      } else {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => SessionsScreen(initialSession: sessionInfo),
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) {
        setState(() => _connecting = false);
      }
    }
  }

  Future<void> _connect() async {
    final raw = _targetController.text.trim();
    if (raw.isEmpty) {
      setState(() => _error = 'Paste a target like user@endpoint_id');
      return;
    }
    await _connectTo(raw,
        useDefaultRelays: _useDefaultRelays,
        customRelayUrls: _customRelayUrls);
  }

  Future<void> _deleteConnection(SavedConnection connection) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove Connection'),
        content: Text('Remove "${connection.target}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await ConnectionStorage.instance.delete(connection.target);
      await _loadConnections();
    }
  }

  void _onSavedConnectionTap(SavedConnection conn) {
    setState(() {
      _targetController.text = conn.target;
      _useDefaultRelays = conn.useDefaultRelays;
      _customRelayUrls = List.of(conn.customRelayUrls);
    });
    _connectTo(conn.target,
        useDefaultRelays: conn.useDefaultRelays,
        customRelayUrls: conn.customRelayUrls);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('iroh-ssh'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const SettingsScreen()),
              );
            },
            tooltip: 'Settings',
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: _targetController,
                  decoration: InputDecoration(
                    labelText: 'Target',
                    hintText: 'user@endpoint_id',
                    border: const OutlineInputBorder(),
                    suffixIcon: Platform.isAndroid
                        ? IconButton(
                            icon: const Icon(Icons.qr_code_scanner),
                            tooltip: 'Scan QR code',
                            onPressed: () async {
                              final result =
                                  await Navigator.of(context).push<String>(
                                MaterialPageRoute(
                                  builder: (_) => const QrScannerScreen(),
                                ),
                              );
                              if (result != null) {
                                _targetController.text = result;
                              }
                            },
                          )
                        : null,
                  ),
                  autocorrect: false,
                  enableSuggestions: false,
                  onSubmitted: (_) => _connect(),
                ),
                const SizedBox(height: 8),
                ExpansionTile(
                  title: const Text('Advanced'),
                  tilePadding: EdgeInsets.zero,
                  childrenPadding: const EdgeInsets.only(bottom: 8),
                  children: [
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Use default relays'),
                      value: _useDefaultRelays,
                      onChanged: (value) =>
                          setState(() => _useDefaultRelays = value),
                    ),
                    const SizedBox(height: 8),
                    RelayUrlListEditor(
                      label: 'Custom relays',
                      helperText: _useDefaultRelays
                          ? 'Added alongside defaults for this connection.'
                          : 'Replaces defaults for this connection.',
                      urls: _customRelayUrls,
                      onChanged: (urls) =>
                          setState(() => _customRelayUrls = urls),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: _connecting ? null : _connect,
                  child: _connecting
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Connect'),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    _error!,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                ],
              ],
            ),
          ),
          if (_savedConnections.isNotEmpty) ...[
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                'Saved Connections',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView.builder(
                itemCount: _savedConnections.length,
                itemBuilder: (context, index) {
                  final conn = _savedConnections[index];
                  return ListTile(
                    leading: const Icon(Icons.computer),
                    title: Text(conn.username),
                    subtitle: Text(
                      conn.endpointId,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                      ),
                    ),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () => _deleteConnection(conn),
                    ),
                    onTap: _connecting
                        ? null
                        : () => _onSavedConnectionTap(conn),
                  );
                },
              ),
            ),
          ],
        ],
      ),
    );
  }
}
