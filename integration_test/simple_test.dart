import 'package:flutter_test/flutter_test.dart';
import 'package:iroh_ssh_app/main.dart';
import 'package:iroh_ssh_app/src/rust/frb_generated.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async => await RustLib.init());
  testWidgets('App renders connect screen', (WidgetTester tester) async {
    await tester.pumpWidget(const IrohSshApp());
    expect(find.text('Iroh SSH'), findsOneWidget);
  });
}
