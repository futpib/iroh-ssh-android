import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:iroh_ssh_app/models/connection_type.dart';
import 'package:iroh_ssh_app/screens/connect_screen.dart';
import 'package:iroh_ssh_app/services/connection_storage.dart';
import 'package:iroh_ssh_app/services/identity_selection.dart';
import 'package:iroh_ssh_app/services/key_storage.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Android connection offers only its ordered identities', (
    tester,
  ) async {
    final nonce = DateTime.now().microsecondsSinceEpoch;
    final firstName = 'e2e-identity-first-$nonce';
    final secondName = 'e2e-identity-second-$nonce';
    final target = 'alice@e2e-$nonce.invalid';
    final storage = KeyStorage.instance;
    final connections = ConnectionStorage.instance;
    try {
      await storage.generateKey(firstName);
      await storage.generateKey(secondName);
      await connections.save(
        SavedConnection(
          target: target,
          connectionType: ConnectionType.ssh,
          identityIds: [
            localIdentityId(firstName),
            localIdentityId(secondName),
          ],
        ),
      );

      await tester.pumpWidget(const MaterialApp(home: ConnectScreen()));
      await tester.pumpAndSettle();
      await tester.tap(find.text('SSH'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, target);
      await tester.pumpAndSettle();
      expect(find.text('$firstName, $secondName'), findsOneWidget);

      await tester.tap(find.text('SSH authentication'));
      await tester.pumpAndSettle();
      expect(find.text('1. $firstName'), findsOneWidget);
      expect(find.text('2. $secondName'), findsOneWidget);
      await tester.ensureVisible(find.byTooltip('Move key up'));
      await tester.tap(find.byTooltip('Move key up'));
      await tester.pumpAndSettle();
      expect(find.text('1. $secondName'), findsOneWidget);
      expect(find.text('2. $firstName'), findsOneWidget);

      await tester.enterText(
        find.byType(TextField).first,
        'alice@other-$nonce.invalid',
      );
      await tester.pumpAndSettle();
      expect(find.text('Password / no SSH key'), findsOneWidget);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await connections.delete(target);
      await storage.deleteKey(firstName);
      await storage.deleteKey(secondName);
    }
  });
}
