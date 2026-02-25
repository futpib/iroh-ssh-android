import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:iroh_ssh_app/screens/qr_scanner_screen.dart';

String? validateRelayUrl(String url) {
  final trimmed = url.trim();
  if (trimmed.isEmpty) return 'URL cannot be empty';

  final uri = Uri.tryParse(trimmed);
  if (uri == null) return 'Invalid URL';
  if (!uri.hasScheme) return 'URL must start with http://, https://, ws://, or wss://';
  const validSchemes = {'http', 'https', 'ws', 'wss'};
  if (!validSchemes.contains(uri.scheme)) {
    return 'URL scheme must be http, https, ws, or wss';
  }
  if (uri.host.isEmpty) return 'URL must have a hostname';

  return null;
}

class RelayUrlListEditor extends StatefulWidget {
  final List<String> urls;
  final ValueChanged<List<String>> onChanged;
  final String label;
  final String helperText;

  const RelayUrlListEditor({
    super.key,
    required this.urls,
    required this.onChanged,
    required this.label,
    required this.helperText,
  });

  @override
  State<RelayUrlListEditor> createState() => _RelayUrlListEditorState();
}

class _RelayUrlListEditorState extends State<RelayUrlListEditor> {
  Future<void> _addUrl() async {
    final url = await _showAddDialog();
    if (url == null) return;

    final updated = [...widget.urls, url];
    widget.onChanged(updated);
  }

  void _removeUrl(int index) {
    final updated = [...widget.urls]..removeAt(index);
    widget.onChanged(updated);
  }

  Future<String?> _showAddDialog() {
    final controller = TextEditingController();
    String? error;

    return showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text('Add ${widget.label}'),
          content: TextField(
            controller: controller,
            decoration: InputDecoration(
              hintText: 'https://relay.example.com.',
              border: const OutlineInputBorder(),
              errorText: error,
              suffixIcon: Platform.isAndroid
                  ? IconButton(
                      icon: const Icon(Icons.qr_code_scanner),
                      tooltip: 'Scan QR code',
                      onPressed: () async {
                        final result =
                            await Navigator.of(ctx).push<String>(
                          MaterialPageRoute(
                            builder: (_) => const QrScannerScreen(),
                          ),
                        );
                        if (result != null) {
                          controller.text = result;
                        }
                      },
                    )
                  : null,
            ),
            style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
            autocorrect: false,
            enableSuggestions: false,
            autofocus: true,
            onSubmitted: (value) {
              final err = validateRelayUrl(value);
              if (err != null) {
                setDialogState(() => error = err);
              } else {
                Navigator.pop(ctx, value.trim());
              }
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () {
                final err = validateRelayUrl(controller.text);
                if (err != null) {
                  setDialogState(() => error = err);
                } else {
                  Navigator.pop(ctx, controller.text.trim());
                }
              },
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                widget.label,
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            IconButton(
              icon: const Icon(Icons.add, size: 20),
              onPressed: _addUrl,
              tooltip: 'Add URL',
              visualDensity: VisualDensity.compact,
            ),
          ],
        ),
        Text(
          widget.helperText,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
        if (widget.urls.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              'None',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          )
        else
          ...widget.urls.asMap().entries.map((entry) => ListTile(
                contentPadding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                title: Text(
                  entry.value,
                  style:
                      const TextStyle(fontFamily: 'monospace', fontSize: 12),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: IconButton(
                  icon: const Icon(Icons.remove_circle_outline, size: 20),
                  onPressed: () => _removeUrl(entry.key),
                  visualDensity: VisualDensity.compact,
                ),
              )),
      ],
    );
  }
}
