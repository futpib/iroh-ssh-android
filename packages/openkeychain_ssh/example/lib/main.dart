import 'package:flutter/material.dart';
import 'package:openkeychain_ssh/openkeychain_ssh.dart';

void main() => runApp(const MaterialApp(home: ProviderExample()));

class ProviderExample extends StatefulWidget {
  const ProviderExample({super.key});

  @override
  State<ProviderExample> createState() => _ProviderExampleState();
}

class _ProviderExampleState extends State<ProviderExample> {
  String result = 'Choose an SSH key provider.';

  Future<void> chooseKey() async {
    try {
      final client = OpenKeychainClient.instance;
      final providers = await client.listProviders();
      if (providers.isEmpty) {
        setState(() => result = 'No compatible provider is installed.');
        return;
      }
      final provider = providers.first;
      final selection = await client.selectKey(provider.packageName);
      final publicKey = await client.getSshPublicKey(
        providerPackage: provider.packageName,
        keyId: selection.keyId,
      );
      setState(() => result = publicKey);
    } catch (error) {
      setState(() => result = '$error');
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('OpenKeychain SSH example')),
    body: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ElevatedButton(onPressed: chooseKey, child: const Text('Choose key')),
          const SizedBox(height: 16),
          SelectableText(result),
        ],
      ),
    ),
  );
}
