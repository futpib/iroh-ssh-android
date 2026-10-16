# openkeychain_ssh

Flutter client for Android services implementing the [OpenKeychain SSH Authentication API](https://github.com/open-keychain/open-keychain/tree/master/sshauthentication-api). The provider keeps private key material; this package asks it to select a key, return its SSH public key, and sign SSH authentication challenges. It works with `dartssh2` 4.1.0 identities.

The package is Android-only. An installed provider is optional; `listProviders()` returns an empty list when none is installed. The Android plugin registers its own method channel, activity result handler, service binding, and package visibility query.

```dart
final client = OpenKeychainClient.instance;
final provider = (await client.listProviders()).first;
final selection = await client.selectKey(provider.packageName);
final publicKey = await client.getSshPublicKey(
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
final identity = key.createIdentity(); // Supply to dartssh2's SSHClient.
```

For an import flow that the user can dismiss, pass one `OpenKeychainOperation` to provider lookup, selection, and public-key lookup. Call `cancel()` when the flow closes and `dispose()` afterward. Native operations have a two-minute deadline and a bounded worker pool.

An app may persist the provider package, key ID, description, and public key. Each app chooses its own storage and must obtain its own provider approval. This package does not store private keys or connection profiles.

The [example](example/lib/main.dart) selects a provider key and displays its SSH public key. `flutter test` checks key parsing, signing, and error handling; `flutter build apk --debug` in the example checks Android compilation. A real provider and server are required to verify a complete SSH login.

The Android `SshAuthenticationApi.java`, `SshAuthenticationApiError.java`, and AIDL contract are copied from OpenKeychain's SSH authentication API under Apache-2.0. The plugin's remaining code is GPL-3.0; see [LICENSE](LICENSE).
