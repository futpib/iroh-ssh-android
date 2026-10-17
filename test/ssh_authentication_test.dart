import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:iroh_ssh_app/services/ssh_authentication.dart';

void main() {
  test('uses server prompts and falls back for password-only SSH', () async {
    final python = Platform.environment['SSH_AUTH_PYTHON'] ?? 'python3';
    final server = await Process.start(python, [
      'test/fixtures/ssh_auth_server.py',
    ]);
    addTearDown(() async {
      server.kill();
      await server.exitCode;
    });
    final portLine = await server.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .first
        .timeout(const Duration(seconds: 10));
    final port = (jsonDecode(portLine) as Map<String, dynamic>)['port'] as int;

    var passwordRequests = 0;
    var createdClients = 0;
    final promptNames = <String>[];
    final interactive = await connectAuthenticatedSsh(
      host: '127.0.0.1',
      port: port,
      username: 'interactive',
      identities: const [],
      onVerifyHostKey: (_, _) => true,
      onClientCreated: (_) => createdClients++,
      onPasswordRequest: () {
        passwordRequests++;
        return 'test password';
      },
      onUserInfoRequest: (request) {
        promptNames.add(request.name);
        return switch (request.name) {
          'Server sign-in' => ['test account', 'test password'],
          'Verification' => ['123456'],
          _ => null,
        };
      },
    ).timeout(const Duration(seconds: 10));
    expect(promptNames, ['Server sign-in', 'Verification']);
    expect(passwordRequests, 0);
    expect(createdClients, 1);
    interactive.close();

    final password = await connectAuthenticatedSsh(
      host: '127.0.0.1',
      port: port,
      username: 'password',
      identities: const [],
      onVerifyHostKey: (_, _) => true,
      onClientCreated: (_) => createdClients++,
      onPasswordRequest: () {
        passwordRequests++;
        return 'test password';
      },
      onUserInfoRequest: (_) => null,
    ).timeout(const Duration(seconds: 10));
    expect(passwordRequests, 1);
    expect(createdClients, 3);
    password.close();
  });
}
