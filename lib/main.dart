import 'package:flutter/material.dart';
import 'package:iroh_ssh_app/src/rust/frb_generated.dart';
import 'package:iroh_ssh_app/screens/connect_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  runApp(const IrohSshApp());
}

class IrohSshApp extends StatelessWidget {
  const IrohSshApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'iroh-ssh',
      theme: ThemeData(
        colorSchemeSeed: Colors.deepPurple,
        useMaterial3: true,
        brightness: Brightness.dark,
      ),
      home: const ConnectScreen(),
    );
  }
}
