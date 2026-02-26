import 'package:flutter/material.dart';
import 'package:iroh_ssh_app/widgets/relay_url_list_editor.dart';

class NetworkSettings {
  final bool useDefaultRelays;
  final List<String> customRelayUrls;
  final int? maxRemoteNatTraversalAddresses;

  const NetworkSettings({
    this.useDefaultRelays = true,
    this.customRelayUrls = const [],
    this.maxRemoteNatTraversalAddresses,
  });

  NetworkSettings copyWith({
    bool? useDefaultRelays,
    List<String>? customRelayUrls,
    int? Function()? maxRemoteNatTraversalAddresses,
  }) {
    return NetworkSettings(
      useDefaultRelays: useDefaultRelays ?? this.useDefaultRelays,
      customRelayUrls: customRelayUrls ?? this.customRelayUrls,
      maxRemoteNatTraversalAddresses: maxRemoteNatTraversalAddresses != null
          ? maxRemoteNatTraversalAddresses()
          : this.maxRemoteNatTraversalAddresses,
    );
  }
}

class NetworkSettingsEditor extends StatelessWidget {
  final NetworkSettings value;
  final ValueChanged<NetworkSettings> onChanged;

  const NetworkSettingsEditor({
    super.key,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Use default relays'),
          subtitle: const Text('Include the built-in relay servers.'),
          value: value.useDefaultRelays,
          onChanged: (v) =>
              onChanged(value.copyWith(useDefaultRelays: v)),
        ),
        const SizedBox(height: 16),
        RelayUrlListEditor(
          label: 'Custom relays',
          helperText: value.useDefaultRelays
              ? 'Added alongside default relay servers.'
              : 'Replaces default relay servers.',
          urls: value.customRelayUrls,
          onChanged: (urls) =>
              onChanged(value.copyWith(customRelayUrls: urls)),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: TextEditingController(
            text: value.maxRemoteNatTraversalAddresses?.toString() ?? '',
          ),
          decoration: const InputDecoration(
            labelText: 'Max remote NAT traversal addresses',
            helperText:
                'Increase if the server has many network interfaces. Default: 12.',
            border: OutlineInputBorder(),
          ),
          keyboardType: TextInputType.number,
          onChanged: (text) {
            final parsed = int.tryParse(text);
            onChanged(value.copyWith(
              maxRemoteNatTraversalAddresses: () => parsed,
            ));
          },
        ),
      ],
    );
  }
}
