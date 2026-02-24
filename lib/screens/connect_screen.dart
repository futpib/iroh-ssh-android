import 'package:flutter/material.dart';
import 'package:iroh_ssh_app/services/key_storage.dart';
import 'package:iroh_ssh_app/src/rust/api/simple.dart';
import 'package:iroh_ssh_app/screens/keys_screen.dart';
import 'package:iroh_ssh_app/screens/terminal_screen.dart';

class ConnectScreen extends StatefulWidget {
  const ConnectScreen({super.key});

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  final _targetController = TextEditingController();
  bool _connecting = false;
  String? _error;

  @override
  void dispose() {
    _targetController.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    final raw = _targetController.text.trim();
    if (raw.isEmpty) {
      setState(() => _error = 'Paste a target like user@endpoint_id');
      return;
    }

    final String username;
    final String endpointId;

    if (raw.contains('@')) {
      final parts = raw.split('@');
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
      final port = await connectIroh(endpointId: endpointId);

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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('iroh-ssh'),
        actions: [
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
      body: Padding(
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
            const SizedBox(height: 24),
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
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
