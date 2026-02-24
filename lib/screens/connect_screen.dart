import 'package:flutter/material.dart';
import 'package:iroh_ssh_app/services/connection_storage.dart';
import 'package:iroh_ssh_app/services/key_storage.dart';
import 'package:iroh_ssh_app/services/settings_storage.dart';
import 'package:iroh_ssh_app/src/rust/api/simple.dart';
import 'package:iroh_ssh_app/screens/keys_screen.dart';
import 'package:iroh_ssh_app/screens/settings_screen.dart';
import 'package:iroh_ssh_app/screens/terminal_screen.dart';

class ConnectScreen extends StatefulWidget {
  const ConnectScreen({super.key});

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  final _targetController = TextEditingController();
  final _relayUrlsController = TextEditingController();
  final _extraRelayUrlsController = TextEditingController();
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
    _relayUrlsController.dispose();
    _extraRelayUrlsController.dispose();
    super.dispose();
  }

  List<String> _parseLines(String text) {
    return text
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
  }

  Future<void> _connectTo(String target,
      {List<String> relayUrls = const [],
      List<String> extraRelayUrls = const []}) async {
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

      final effectiveRelayUrls =
          relayUrls.isNotEmpty ? relayUrls : globalSettings.relayUrls;
      final effectiveExtraRelayUrls = extraRelayUrls.isNotEmpty
          ? extraRelayUrls
          : globalSettings.extraRelayUrls;

      final port = await connectIroh(
        endpointId: endpointId,
        relayUrls: effectiveRelayUrls,
        extraRelayUrls: effectiveExtraRelayUrls,
      );

      await ConnectionStorage.instance.save(SavedConnection(
        target: target,
        relayUrls: relayUrls,
        extraRelayUrls: extraRelayUrls,
      ));
      await _loadConnections();

      if (!mounted) return;

      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => TerminalScreen(
            host: 'localhost',
            port: port,
            username: username,
            identities: keys.map((k) => k.keyPair).toList(),
          ),
        ),
      );
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
    final relayUrls = _parseLines(_relayUrlsController.text);
    final extraRelayUrls = _parseLines(_extraRelayUrlsController.text);
    await _connectTo(raw,
        relayUrls: relayUrls, extraRelayUrls: extraRelayUrls);
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
    _targetController.text = conn.target;
    _relayUrlsController.text = conn.relayUrls.join('\n');
    _extraRelayUrlsController.text = conn.extraRelayUrls.join('\n');
    _connectTo(conn.target,
        relayUrls: conn.relayUrls, extraRelayUrls: conn.extraRelayUrls);
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
          IconButton(
            icon: const Icon(Icons.vpn_key),
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const KeysScreen()),
              );
            },
            tooltip: 'Manage Keys',
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
                  decoration: const InputDecoration(
                    labelText: 'Target',
                    hintText: 'user@endpoint_id',
                    border: OutlineInputBorder(),
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
                    TextField(
                      controller: _relayUrlsController,
                      decoration: const InputDecoration(
                        labelText: 'Relay URLs',
                        helperText: 'Replaces defaults. One URL per line.',
                        helperMaxLines: 2,
                        border: OutlineInputBorder(),
                      ),
                      maxLines: 3,
                      style:
                          const TextStyle(fontFamily: 'monospace', fontSize: 13),
                      autocorrect: false,
                      enableSuggestions: false,
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _extraRelayUrlsController,
                      decoration: const InputDecoration(
                        labelText: 'Extra Relay URLs',
                        helperText: 'Added alongside defaults. One URL per line.',
                        helperMaxLines: 2,
                        border: OutlineInputBorder(),
                      ),
                      maxLines: 3,
                      style:
                          const TextStyle(fontFamily: 'monospace', fontSize: 13),
                      autocorrect: false,
                      enableSuggestions: false,
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
