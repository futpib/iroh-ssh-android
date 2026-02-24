import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:iroh_ssh_app/services/key_storage.dart';

class KeysScreen extends StatefulWidget {
  const KeysScreen({super.key});

  @override
  State<KeysScreen> createState() => _KeysScreenState();
}

class _KeysScreenState extends State<KeysScreen> {
  List<StoredKey>? _keys;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadKeys();
  }

  Future<void> _loadKeys() async {
    setState(() => _loading = true);
    final keys = await KeyStorage.instance.listKeys();
    if (mounted) {
      setState(() {
        _keys = keys;
        _loading = false;
      });
    }
  }

  Future<void> _generateKey() async {
    final name = await _showNameDialog('Generate Key', 'Key name');
    if (name == null || name.isEmpty) return;

    try {
      final key = await KeyStorage.instance.generateKey(name);
      await _loadKeys();
      if (mounted) {
        _showPublicKeyDialog(key);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }

  Future<void> _importKey() async {
    final name = await _showNameDialog('Import Key', 'Key name');
    if (name == null || name.isEmpty) return;

    final pem = await _showImportDialog();
    if (pem == null || pem.isEmpty) return;

    try {
      await KeyStorage.instance.importKey(name, pem);
      await _loadKeys();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }

  Future<void> _deleteKey(StoredKey key) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Key'),
        content: Text('Delete "${key.name}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await KeyStorage.instance.deleteKey(key.name);
      await _loadKeys();
    }
  }

  void _showPublicKeyDialog(StoredKey key) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Public Key'),
        content: SelectableText(
          key.publicKeyString,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: key.publicKeyString));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Public key copied')),
              );
              Navigator.pop(ctx);
            },
            child: const Text('Copy'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<String?> _showNameDialog(String title, String label) {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          decoration: InputDecoration(
            labelText: label,
            border: const OutlineInputBorder(),
          ),
          autofocus: true,
          onSubmitted: (value) => Navigator.pop(ctx, value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<String?> _showImportDialog() {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Paste Private Key'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            hintText: '-----BEGIN OPENSSH PRIVATE KEY-----\n...',
            border: OutlineInputBorder(),
          ),
          maxLines: 8,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Import'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Manage Keys')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _keys == null || _keys!.isEmpty
              ? const Center(
                  child: Text('No keys. Tap + to generate or import.'),
                )
              : ListView.builder(
                  itemCount: _keys!.length,
                  itemBuilder: (context, index) {
                    final key = _keys![index];
                    return ListTile(
                      leading: const Icon(Icons.vpn_key),
                      title: Text(key.name),
                      subtitle: Text(
                        key.publicKeyString,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 11,
                        ),
                      ),
                      onTap: () => _showPublicKeyDialog(key),
                      onLongPress: () => _deleteKey(key),
                    );
                  },
                ),
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FloatingActionButton.small(
            heroTag: 'import',
            onPressed: _importKey,
            tooltip: 'Import key',
            child: const Icon(Icons.file_open),
          ),
          const SizedBox(height: 8),
          FloatingActionButton(
            heroTag: 'generate',
            onPressed: _generateKey,
            tooltip: 'Generate key',
            child: const Icon(Icons.add),
          ),
        ],
      ),
    );
  }
}
