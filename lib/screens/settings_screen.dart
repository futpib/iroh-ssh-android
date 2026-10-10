import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:file_saver/file_saver.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';
import 'package:iroh_ssh_app/screens/qr_scanner_screen.dart';
import 'package:iroh_ssh_app/services/key_storage.dart';
import 'package:iroh_ssh_app/services/open_keychain.dart';
import 'package:iroh_ssh_app/services/settings_storage.dart';
import 'package:iroh_ssh_app/widgets/network_settings_editor.dart';
import 'package:iroh_ssh_app/widgets/update_settings.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  List<StoredKey>? _keys;
  List<OpenKeychainKey>? _openKeychainKeys;
  bool _keysLoading = true;

  bool _useDefaultRelays = true;
  List<String> _customRelayUrls = [];
  bool _relaysLoading = true;

  double _terminalFontSize = 14.0;
  String _terminalTheme = 'default';
  String _barPosition = 'bottom';
  bool _terminalLoading = true;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: Platform.isAndroid ? 4 : 3,
      vsync: this,
    );
    _loadKeys();
    _loadSettings();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  // --- Keys ---

  Future<void> _loadKeys() async {
    setState(() => _keysLoading = true);
    final values = await Future.wait([
      KeyStorage.instance.listKeys(),
      if (Platform.isAndroid)
        OpenKeychainStorage.instance.listKeys()
      else
        Future.value(<OpenKeychainKey>[]),
    ]);
    final keys = values[0] as List<StoredKey>;
    final openKeychainKeys = values[1] as List<OpenKeychainKey>;
    if (mounted) {
      setState(() {
        _keys = keys;
        _openKeychainKeys = openKeychainKeys;
        _keysLoading = false;
      });
    }
  }

  Future<void> _importOpenKeychainKey() async {
    try {
      final providers = await OpenKeychainClient.instance.listProviders();
      if (!mounted) return;
      if (providers.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No OpenKeychain provider is installed'),
          ),
        );
        return;
      }

      final provider = providers.length == 1
          ? providers.single
          : await showDialog<OpenKeychainProvider>(
              context: context,
              builder: (ctx) => SimpleDialog(
                title: const Text('Choose key provider'),
                children: [
                  for (final candidate in providers)
                    SimpleDialogOption(
                      onPressed: () => Navigator.pop(ctx, candidate),
                      child: ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.security),
                        title: Text(candidate.label),
                        subtitle: Text(candidate.packageName),
                      ),
                    ),
                ],
              ),
            );
      if (provider == null) return;

      final selection = await OpenKeychainClient.instance.selectKey(
        provider.packageName,
      );
      final publicKey = await OpenKeychainClient.instance.getSshPublicKey(
        providerPackage: provider.packageName,
        keyId: selection.keyId,
      );
      final key = OpenKeychainKey(
        providerPackage: provider.packageName,
        providerLabel: provider.label,
        keyId: selection.keyId,
        description: selection.description,
        publicKeyString: publicKey,
      );
      key.createIdentity();
      await OpenKeychainStorage.instance.save(key);
      await _loadKeys();
      if (mounted) _showOpenKeychainPublicKeyDialog(key);
    } on PlatformException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.message ?? error.code)));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not add OpenKeychain key: $error')),
        );
      }
    }
  }

  Future<void> _deleteOpenKeychainKey(OpenKeychainKey key) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove OpenKeychain key'),
        content: Text(
          'Remove "${key.description}" from Iroh SSH? The key remains in ${key.providerLabel}.',
        ),
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
      await OpenKeychainStorage.instance.delete(key.id);
      await _loadKeys();
    }
  }

  void _showOpenKeychainPublicKeyDialog(OpenKeychainKey key) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(key.description),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Signing is handled by ${key.providerLabel}; the private key never enters Iroh SSH.',
              ),
              const SizedBox(height: 16),
              const Text(
                'Add this public key to your server’s authorized_keys file.',
              ),
              const SizedBox(height: 16),
              SelectableText(
                key.publicKeyString,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
          FilledButton.icon(
            icon: const Icon(Icons.copy, size: 18),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: key.publicKeyString));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Public key copied')),
              );
              Navigator.pop(ctx);
            },
            label: const Text('Copy public key'),
          ),
        ],
      ),
    );
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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error: $e')));
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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error: $e')));
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
        title: Text(key.name),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Add this public key to your server’s authorized_keys file.',
              ),
              const SizedBox(height: 16),
              SelectableText(
                key.publicKeyString,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ],
          ),
        ),
        actions: [
          if (Platform.isAndroid)
            TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                _exportPrivateKey(key);
              },
              child: const Text('Export private key'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
          FilledButton.icon(
            icon: const Icon(Icons.copy, size: 18),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: key.publicKeyString));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Public key copied')),
              );
              Navigator.pop(ctx);
            },
            label: const Text('Copy public key'),
          ),
        ],
      ),
    );
  }

  Future<void> _exportPrivateKey(StoredKey key) async {
    final localAuth = LocalAuthentication();
    try {
      final authenticated = await localAuth.authenticate(
        localizedReason: 'Authenticate to export private key',
      );
      if (!authenticated) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Authentication failed')),
          );
        }
        return;
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Authentication error: $e')));
      }
      return;
    }

    try {
      final pem = await KeyStorage.instance.readPrivateKeyPem(key.name);
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Private Key'),
          content: SelectableText(
            pem,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: pem));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Private key copied')),
                );
                Navigator.pop(ctx);
              },
              child: const Text('Copy'),
            ),
            if (Platform.isAndroid)
              TextButton(
                onPressed: () async {
                  try {
                    await FileSaver.instance.saveAs(
                      name: key.name,
                      fileExtension: '',
                      mimeType: MimeType.text,
                      bytes: utf8.encode(pem),
                    );
                  } catch (e) {
                    if (ctx.mounted) {
                      ScaffoldMessenger.of(ctx).showSnackBar(
                        SnackBar(content: Text('Error saving file: $e')),
                      );
                    }
                  }
                },
                child: const Text('Save'),
              ),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Close'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error reading key: $e')));
      }
    }
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
        title: const Text('Import Private Key'),
        content: TextField(
          controller: controller,
          decoration: InputDecoration(
            hintText: '-----BEGIN OPENSSH PRIVATE KEY-----\n...',
            border: const OutlineInputBorder(),
            suffixIcon: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.qr_code_scanner),
                  tooltip: 'Scan QR code',
                  onPressed: () async {
                    final result = await Navigator.of(ctx).push<String>(
                      MaterialPageRoute(
                        builder: (_) => const QrScannerScreen(),
                      ),
                    );
                    if (result != null) {
                      controller.text = result;
                    }
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.file_open),
                  tooltip: 'Pick file',
                  onPressed: () async {
                    final file = await FilePicker.pickFile(type: FileType.any);
                    if (file != null) {
                      controller.text = utf8.decode(await file.readAsBytes());
                    }
                  },
                ),
              ],
            ),
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

  // --- Relays ---

  Future<void> _loadSettings() async {
    final settings = await SettingsStorage.instance.load();
    if (mounted) {
      setState(() {
        _useDefaultRelays = settings.useDefaultRelays;
        _customRelayUrls = List.of(settings.customRelayUrls);
        _relaysLoading = false;
        _terminalFontSize = settings.terminalFontSize;
        _terminalTheme = settings.terminalTheme;
        _barPosition = settings.barPosition;
        _terminalLoading = false;
      });
    }
  }

  Future<void> _saveRelaySettings() async {
    final settings = await SettingsStorage.instance.load();
    await SettingsStorage.instance.save(
      settings.copyWith(
        useDefaultRelays: _useDefaultRelays,
        customRelayUrls: _customRelayUrls,
        terminalFontSize: _terminalFontSize,
        terminalTheme: _terminalTheme,
        barPosition: _barPosition,
      ),
    );
  }

  Future<void> _saveTerminalSettings() async {
    final settings = await SettingsStorage.instance.load();
    await SettingsStorage.instance.save(
      settings.copyWith(
        useDefaultRelays: _useDefaultRelays,
        customRelayUrls: _customRelayUrls,
        terminalFontSize: _terminalFontSize,
        terminalTheme: _terminalTheme,
        barPosition: _barPosition,
      ),
    );
  }

  // --- Build ---

  Widget _buildKeysTab() {
    if (_keysLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    final keys = _keys ?? [];
    final openKeychainKeys = _openKeychainKeys ?? [];
    if (keys.isEmpty && openKeychainKeys.isEmpty) {
      return ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 64, horizontal: 24),
            child: Column(
              children: [
                CircleAvatar(
                  radius: 28,
                  child: Icon(Icons.key_outlined, size: 28),
                ),
                SizedBox(height: 20),
                Text(
                  'No keys',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w500),
                ),
              ],
            ),
          ),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 12,
            runSpacing: 12,
            children: [
              FilledButton.icon(
                onPressed: _generateKey,
                icon: const Icon(Icons.add),
                label: const Text('Generate'),
              ),
              OutlinedButton.icon(
                onPressed: _importKey,
                icon: const Icon(Icons.file_download_outlined),
                label: const Text('Import'),
              ),
              if (Platform.isAndroid)
                OutlinedButton.icon(
                  onPressed: _importOpenKeychainKey,
                  icon: const Icon(Icons.security),
                  label: const Text('OpenKeychain'),
                ),
            ],
          ),
        ],
      );
    }
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            IconButton(
              onPressed: _generateKey,
              icon: const Icon(Icons.add),
              tooltip: 'Generate key',
            ),
            IconButton(
              onPressed: _importKey,
              icon: const Icon(Icons.file_download_outlined),
              tooltip: 'Import key',
            ),
            if (Platform.isAndroid)
              IconButton(
                onPressed: _importOpenKeychainKey,
                icon: const Icon(Icons.security),
                tooltip: 'Add from OpenKeychain',
              ),
          ],
        ),
        for (final key in keys)
          Card(
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 8,
              ),
              leading: const Icon(Icons.vpn_key),
              title: Text(key.name),
              subtitle: Text(
                key.publicKeyString,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
              ),
              trailing: PopupMenuButton<String>(
                tooltip: 'Key actions',
                onSelected: (_) => _deleteKey(key),
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'delete', child: Text('Delete')),
                ],
              ),
              onTap: () => _showPublicKeyDialog(key),
            ),
          ),
        for (final key in openKeychainKeys)
          Card(
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 8,
              ),
              leading: const Icon(Icons.security),
              title: Text(key.description),
              subtitle: Text(
                '${key.providerLabel}\n${key.publicKeyString}',
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
              ),
              isThreeLine: true,
              trailing: PopupMenuButton<String>(
                tooltip: 'Key actions',
                onSelected: (_) => _deleteOpenKeychainKey(key),
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'remove', child: Text('Remove')),
                ],
              ),
              onTap: () => _showOpenKeychainPublicKeyDialog(key),
            ),
          ),
      ],
    );
  }

  Widget _buildRelaysTab() {
    if (_relaysLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: NetworkSettingsEditor(
        value: NetworkSettings(
          useDefaultRelays: _useDefaultRelays,
          customRelayUrls: _customRelayUrls,
        ),
        onChanged: (settings) {
          setState(() {
            _useDefaultRelays = settings.useDefaultRelays;
            _customRelayUrls = settings.customRelayUrls;
          });
          _saveRelaySettings();
        },
      ),
    );
  }

  Widget _buildTerminalTab() {
    if (_terminalLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Font Size: ${_terminalFontSize.round()}',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          Slider(
            value: _terminalFontSize,
            min: 8,
            max: 24,
            divisions: 16,
            label: _terminalFontSize.round().toString(),
            onChanged: (value) {
              setState(() => _terminalFontSize = value.roundToDouble());
              _saveTerminalSettings();
            },
          ),
          const SizedBox(height: 24),
          Text('Theme', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          RadioGroup<String>(
            groupValue: _terminalTheme,
            onChanged: (value) {
              setState(() => _terminalTheme = value!);
              _saveTerminalSettings();
            },
            child: Column(
              children: [
                RadioListTile<String>(
                  title: const Text('Default'),
                  value: 'default',
                ),
                RadioListTile<String>(
                  title: const Text('White on Black'),
                  value: 'whiteOnBlack',
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          Text('Bar Position', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          RadioGroup<String>(
            groupValue: _barPosition,
            onChanged: (value) {
              setState(() => _barPosition = value!);
              _saveTerminalSettings();
            },
            child: Column(
              children: [
                RadioListTile<String>(
                  title: const Text('Bottom'),
                  value: 'bottom',
                ),
                RadioListTile<String>(title: const Text('Top'), value: 'top'),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        bottom: TabBar(
          controller: _tabController,
          tabs: [
            Tab(text: 'Keys'),
            Tab(text: 'Network'),
            Tab(text: 'Terminal'),
            if (Platform.isAndroid) const Tab(text: 'Updates'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildKeysTab(),
          _buildRelaysTab(),
          _buildTerminalTab(),
          if (Platform.isAndroid) const UpdateSettings(),
        ],
      ),
    );
  }
}
