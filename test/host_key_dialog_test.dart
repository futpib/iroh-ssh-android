import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iroh_ssh_app/services/known_hosts.dart';
import 'package:iroh_ssh_app/widgets/host_key_dialog.dart';

void main() {
  for (final changed in [false, true]) {
    testWidgets(
      '${changed ? 'changed' : 'new'} host key needs an explicit trust decision',
      (tester) async {
        bool? accepted;
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  accepted = await confirmHostKey(
                    context,
                    HostKeyChallenge(
                      host: 'server',
                      port: 2222,
                      keyType: 'ssh-ed25519',
                      fingerprint: 'SHA256:new',
                      previousFingerprint: changed ? 'SHA256:old' : null,
                    ),
                  );
                },
                child: const Text('Connect'),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Connect'));
        await tester.pumpAndSettle();
        expect(accepted, isNull);
        expect(find.text('server:2222'), findsOneWidget);
        expect(find.text('SHA256:new'), findsOneWidget);
        if (changed) expect(find.text('SHA256:old'), findsOneWidget);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(accepted, isFalse);
        await tester.tap(find.text('Connect'));
        await tester.pumpAndSettle();
        await tester.tap(
          find.text(changed ? 'Trust new key' : 'Trust and connect'),
        );
        await tester.pumpAndSettle();
        expect(accepted, isTrue);
      },
    );
  }
}
