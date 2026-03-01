import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:iroh_ssh_app/models/connection_type.dart';
import 'package:iroh_ssh_app/services/background_session.dart';
import 'package:iroh_ssh_app/services/session_messages.dart';
import 'package:iroh_ssh_app/src/rust/frb_generated.dart';
import 'package:xterm/xterm.dart';

/// Simulates the IPC path used on Android:
///   BackgroundSession (PTY + batched stdout)
///     → base64 JSON OutputEvent
///     → StreamController (simulating IPC)
///     → ZModemMux on "UI" side
///     → base64 JSON InputCommand back to BackgroundSession
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async => await RustLib.init());

  testWidgets('ZMODEM file receive via simulated IPC path', (tester) async {
    final outputDir = await Directory.systemTemp.createTemp('zmodem_ipc_test_');

    // --- "Service" side: BackgroundSession with local shell ---
    final session = BackgroundSession(
      sessionId: 'ipc_test',
      displayName: 'Local',
      username: '',
      port: 0,
      identities: [],
      connectionType: ConnectionType.local,
    );

    // --- "UI" side: ZModemMux fed by StreamControllers ---
    final uiStdoutController = StreamController<Uint8List>();
    final uiStdinController = StreamController<List<int>>();

    final terminal = Terminal(maxLines: 10000);

    final zmodemMux = ZModemMux(
      stdin: uiStdinController.sink,
      stdout: uiStdoutController.stream,
    );
    zmodemMux.onTerminalInput = terminal.write;

    // Wire: UI stdin → service input (simulating InputCommand IPC)
    uiStdinController.stream.listen((data) {
      final encoded = base64Encode(data);
      // Simulate: JSON encode → decode → base64 decode
      final command = InputCommand(sessionId: 'ipc_test', dataBase64: encoded);
      final json = jsonDecode(command.encode()) as Map<String, dynamic>;
      final decoded = InputCommand.fromJson(json);
      session.handleInput(Uint8List.fromList(base64Decode(decoded.dataBase64)));
    });

    // Wire: service output → UI stdout (simulating OutputEvent IPC)
    // Split large chunks into ~2KB pieces delivered via separate
    // Future.delayed calls. This reproduces the Android behavior where SSH
    // data arrives in multiple network-sized chunks (e.g., 2069 + 2156
    // bytes) that get batched separately by BackgroundSession._flushStdout,
    // delivered as separate SendPort messages, each arriving as a distinct
    // event loop turn in the UI isolate.
    //
    // The key issue: _handleZModem is async (it awaits file end/session
    // events), so when a second chunk arrives via a new event loop turn
    // while the first _handleZModem is suspended at an await, both run
    // concurrently on the same ZModemCore parser, corrupting state.
    const maxChunkSize = 2048;
    session.onSendToUi = (String data) {
      try {
        final json = jsonDecode(data) as Map<String, dynamic>;
        if (json['type'] == 'output') {
          final event = OutputEvent.fromJson(json);
          final bytes = base64Decode(event.dataBase64);
          // Split into sub-chunks and deliver each as a separate event
          // loop turn via Future.delayed, simulating cross-isolate
          // SendPort delivery where each message is a new event.
          var delay = 0;
          for (var offset = 0; offset < bytes.length; offset += maxChunkSize) {
            final end = (offset + maxChunkSize < bytes.length)
                ? offset + maxChunkSize
                : bytes.length;
            final subChunk = Uint8List.fromList(bytes.sublist(offset, end));
            final d = delay;
            Future.delayed(Duration(milliseconds: d), () {
              uiStdoutController.add(subChunk);
            });
            delay += 1;
          }
        }
      } catch (_) {}
    };
    session.uiAttached = true;
    session.onSessionEnded = () {};

    // File receive handler
    final receiveCompleter = Completer<void>();
    String? receivedPathname;

    zmodemMux.onFileOffer = (ZModemOffer offer) async {
      receivedPathname = offer.info.pathname;
      final file = File('${outputDir.path}/${offer.info.pathname}');
      await offer
          .accept(0)
          .cast<List<int>>()
          .pipe(file.openWrite());
      receiveCompleter.complete();
    };

    // Start the local shell
    session.connect();
    await Future.delayed(const Duration(milliseconds: 500));
    await tester.pump();

    // Send README.md (same ~4KB file used in the Android test)
    final szCommand = File('/usr/bin/lrzsz-sz').existsSync() ? 'lrzsz-sz' : 'sz';
    session.handleInput(Uint8List.fromList(
      utf8.encode('$szCommand README.md\r'),
    ));

    // Wait for transfer to complete
    var completed = false;
    try {
      await receiveCompleter.future.timeout(const Duration(seconds: 10));
      completed = true;
    } on TimeoutException {
      completed = false;
    }

    expect(completed, isTrue,
        reason: 'ZMODEM transfer should complete via IPC path');
    expect(receivedPathname, equals('README.md'));

    final receivedFile = File('${outputDir.path}/README.md');
    expect(await receivedFile.exists(), isTrue);
    final receivedContent = await receivedFile.readAsString();
    final originalContent = await File('README.md').readAsString();
    expect(receivedContent, equals(originalContent));

    // Cleanup
    await session.disconnect();
    await uiStdoutController.close();
    await uiStdinController.close();
    await outputDir.delete(recursive: true);
  });
}
