import 'package:flutter/material.dart';
import 'package:iroh_ssh_app/services/settings_storage.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _relayUrlsController = TextEditingController();
  final _extraRelayUrlsController = TextEditingController();
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final settings = await SettingsStorage.instance.load();
    if (mounted) {
      setState(() {
        _relayUrlsController.text = settings.relayUrls.join('\n');
        _extraRelayUrlsController.text = settings.extraRelayUrls.join('\n');
        _loading = false;
      });
    }
  }

  Future<void> _save() async {
    final relayUrls = _parseLines(_relayUrlsController.text);
    final extraRelayUrls = _parseLines(_extraRelayUrlsController.text);

    await SettingsStorage.instance.save(AppSettings(
      relayUrls: relayUrls,
      extraRelayUrls: extraRelayUrls,
    ));

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Settings saved')),
      );
    }
  }

  List<String> _parseLines(String text) {
    return text
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
  }

  @override
  void dispose() {
    _relayUrlsController.dispose();
    _extraRelayUrlsController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: _relayUrlsController,
                    decoration: const InputDecoration(
                      labelText: 'Relay URLs',
                      helperText:
                          'Replaces default relay servers. One URL per line.',
                      helperMaxLines: 2,
                      border: OutlineInputBorder(),
                    ),
                    maxLines: 5,
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                    autocorrect: false,
                    enableSuggestions: false,
                  ),
                  const SizedBox(height: 24),
                  TextField(
                    controller: _extraRelayUrlsController,
                    decoration: const InputDecoration(
                      labelText: 'Extra Relay URLs',
                      helperText:
                          'Added alongside default relay servers. One URL per line.',
                      helperMaxLines: 2,
                      border: OutlineInputBorder(),
                    ),
                    maxLines: 5,
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                    autocorrect: false,
                    enableSuggestions: false,
                  ),
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: _save,
                    child: const Text('Save'),
                  ),
                ],
              ),
            ),
    );
  }
}
