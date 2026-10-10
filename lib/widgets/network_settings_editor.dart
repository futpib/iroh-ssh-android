import 'package:flutter/material.dart';
import 'package:iroh_ssh_app/widgets/relay_url_list_editor.dart';

class NetworkSettings {
  final bool useDefaultRelays;
  final List<String> customRelayUrls;

  const NetworkSettings({
    this.useDefaultRelays = true,
    this.customRelayUrls = const [],
  });

  NetworkSettings copyWith({
    bool? useDefaultRelays,
    List<String>? customRelayUrls,
  }) {
    return NetworkSettings(
      useDefaultRelays: useDefaultRelays ?? this.useDefaultRelays,
      customRelayUrls: customRelayUrls ?? this.customRelayUrls,
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
      ],
    );
  }
}
