import 'package:flutter/material.dart';
import 'package:iroh_ssh_app/services/known_hosts.dart';

Future<bool> confirmHostKey(
  BuildContext context,
  HostKeyChallenge challenge,
) async {
  final changed = challenge.previousFingerprint != null;
  return await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          title: Text(changed ? 'SSH host key changed' : 'Trust SSH server?'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${challenge.host}:${challenge.port}'),
                const SizedBox(height: 12),
                Text(
                  changed
                      ? 'This server has a different key. This could mean the server was replaced or someone is intercepting the connection.'
                      : 'This server is not yet trusted.',
                ),
                const SizedBox(height: 12),
                Text(
                  'Verify this fingerprint with the server administrator before trusting it.\n${challenge.keyType}',
                ),
                SelectableText(challenge.fingerprint),
                if (changed) ...[
                  const SizedBox(height: 12),
                  const Text('Previously trusted fingerprint:'),
                  SelectableText(challenge.previousFingerprint!),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(changed ? 'Trust new key' : 'Trust and connect'),
            ),
          ],
        ),
      ) ??
      false;
}
