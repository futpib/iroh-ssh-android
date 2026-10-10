import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iroh_ssh_app/models/connection_type.dart';
import 'package:iroh_ssh_app/services/background_session.dart';
import 'package:iroh_ssh_app/services/known_hosts.dart';
import 'package:iroh_ssh_app/services/session_messages.dart';

// An actual SSH handshake complements the storage/IPC tests. CI installs
// openssh-server; other platforms still run the portable tests.
void main() {
  test(
    'SSH requires consent before authentication and rejects a changed server',
    () async {
      final temp = await Directory.systemTemp.createTemp('ssh-handshake-');
      addTearDown(() => temp.delete(recursive: true));
      Future<void> key(String name) async {
        final result = await Process.run('ssh-keygen', [
          '-q',
          '-t',
          'ed25519',
          '-N',
          '',
          '-f',
          '${temp.path}/$name',
        ]);
        expect(result.exitCode, 0, reason: '${result.stderr}');
      }

      await key('host1');
      await key('host2');
      await key('identity');
      await key('rejected');
      final user = (await Process.run('id', ['-un'])).stdout.toString().trim();
      final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = socket.port;
      await socket.close();
      final identities = SSHKeyPair.fromPem(
        await File('${temp.path}/identity').readAsString(),
      );
      final hosts = KnownHosts(
        file: () async => File('${temp.path}/known_hosts.json'),
      );
      Process? server;
      addTearDown(() async {
        server?.kill();
        await server?.exitCode;
      });
      Future<void> start(String hostKey) async {
        final config = await File('${temp.path}/sshd_config').writeAsString('''
Port $port
ListenAddress 127.0.0.1
HostKey ${temp.path}/$hostKey
PidFile ${temp.path}/sshd.pid
AuthorizedKeysFile ${temp.path}/identity.pub
StrictModes no
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
LogLevel ERROR
''');
        server = await Process.start('/usr/sbin/sshd', [
          '-D',
          '-e',
          '-f',
          config.path,
        ]);
        final errors = StringBuffer();
        server!.stderr.transform(utf8.decoder).listen(errors.write);
        server!.stdout.drain<void>();
        for (var i = 0; i < 100; i++) {
          try {
            final probe = await Socket.connect('127.0.0.1', port);
            probe.destroy();
            return;
          } on SocketException {
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
        }
        fail('sshd did not start: $errors');
      }

      Future<void> connect({
        required bool approve,
        required bool expectPrompt,
        bool changed = false,
        List<SSHIdentity>? connectionIdentities,
      }) async {
        final client = BackgroundSession(
          sessionId: 'wire',
          displayName: 'test',
          username: user,
          port: port,
          identities: connectionIdentities ?? identities,
          connectionType: ConnectionType.ssh,
          sshHost: '127.0.0.1',
          sshPort: port,
          knownHosts: hosts,
        )..uiAttached = true;
        final ready = Completer<void>();
        final prompt = Completer<HostKeyRequestEvent>();
        final errors = <String>[];
        client.onSendToUi = (raw) {
          final event = ServiceEvent.decode(raw);
          if (event is HostKeyRequestEvent) prompt.complete(event);
          if (event is ShellReadyEvent) ready.complete();
          if (event is ErrorEvent) errors.add(event.message);
        };
        final connecting = client.connect();
        if (expectPrompt) {
          final request = await prompt.future.timeout(
            const Duration(seconds: 5),
          );
          expect(ready.isCompleted, isFalse);
          expect(client.state, SessionState.connecting);
          expect(request.challenge.fingerprint, startsWith('SHA256:'));
          expect(
            request.challenge.previousFingerprint,
            changed ? isNotNull : isNull,
          );
          client.handleHostKeyResponse(
            HostKeyResponseCommand(
              sessionId: 'wire',
              requestId: request.requestId,
              accepted: approve,
            ),
          );
        }
        await connecting.timeout(const Duration(seconds: 5));
        expect(ready.isCompleted, approve, reason: errors.join('\n'));
        if (!expectPrompt) expect(prompt.isCompleted, isFalse);
        if (!approve) {
          expect(errors, isNotEmpty);
          expect(client.state, SessionState.disconnected);
        }
        await client.disconnect();
      }

      await start('host1');
      await connect(approve: false, expectPrompt: true);
      await connect(approve: true, expectPrompt: true);
      await connect(approve: true, expectPrompt: false);

      final rejected = SSHKeyPair.fromPem(
        await File('${temp.path}/rejected').readAsString(),
      ).single;
      var rejectedSignatures = 0;
      var acceptedSignatures = 0;
      final externalIdentities = [
        SSHIdentity.custom(
          type: rejected.type,
          publicKey: SSHRawHostKey(rejected.toPublicKey().encode()),
          shouldProbe: true,
          signer: (challenge) async {
            rejectedSignatures++;
            return SSHRawSignature(rejected.sign(challenge).encode());
          },
        ),
        SSHIdentity.custom(
          type: identities.single.type,
          publicKey: SSHRawHostKey(identities.single.toPublicKey().encode()),
          shouldProbe: true,
          signer: (challenge) async {
            acceptedSignatures++;
            return SSHRawSignature(identities.single.sign(challenge).encode());
          },
        ),
      ];
      await connect(
        approve: true,
        expectPrompt: false,
        connectionIdentities: externalIdentities,
      );
      expect(rejectedSignatures, 0);
      expect(acceptedSignatures, 1);

      server!.kill();
      await server!.exitCode;
      await start('host2');
      await connect(approve: false, expectPrompt: true, changed: true);
      await File('${temp.path}/known_hosts.json').writeAsString('invalid json');
      await connect(approve: false, expectPrompt: false);
    },
    skip: !Platform.isLinux || !File('/usr/sbin/sshd').existsSync()
        ? 'requires Linux openssh-server'
        : false,
  );
}
