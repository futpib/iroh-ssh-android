import 'package:dartssh2/dartssh2.dart';
import 'package:iroh_ssh_app/services/key_storage.dart';
import 'package:iroh_ssh_app/services/open_keychain.dart';

String localIdentityId(String name) => 'local:$name';
String externalIdentityId(OpenKeychainKey key) => 'openkeychain:${key.id}';

class AvailableIdentity {
  const AvailableIdentity(this.id, this.label);

  final String id;
  final String label;
}

List<AvailableIdentity> availableIdentities(
  List<StoredKey> localKeys,
  List<OpenKeychainKey> externalKeys,
) => [
  for (final key in localKeys)
    AvailableIdentity(localIdentityId(key.name), key.name),
  for (final key in externalKeys)
    AvailableIdentity(
      externalIdentityId(key),
      '${key.description} · ${key.providerLabel}',
    ),
];

List<SSHIdentity> resolveIdentities(
  List<String> selectedIds,
  List<StoredKey> localKeys,
  List<OpenKeychainKey> externalKeys,
) {
  final local = {for (final key in localKeys) localIdentityId(key.name): key};
  final external = {
    for (final key in externalKeys) externalIdentityId(key): key,
  };
  final resolved = <SSHIdentity>[];
  for (final id in selectedIds) {
    if (local.containsKey(id)) {
      resolved.add(local[id]!.keyPair);
    } else if (external.containsKey(id)) {
      resolved.add(external[id]!.createIdentity());
    } else {
      throw StateError(
        'SSH key is missing. Choose another key for this connection.',
      );
    }
  }
  return resolved;
}
