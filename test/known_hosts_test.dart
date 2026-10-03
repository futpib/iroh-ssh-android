import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:iroh_ssh_app/models/connection_type.dart';
import 'package:iroh_ssh_app/services/background_session.dart';
import 'package:iroh_ssh_app/services/known_hosts.dart';
import 'package:iroh_ssh_app/services/session_messages.dart';

void main() {
  late Directory directory;
  late File file;
  late KnownHosts hosts;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('known-hosts-');
    file = File('${directory.path}/known_hosts.json');
    hosts = KnownHosts(file: () async => file);
  });
  tearDown(() => directory.delete(recursive: true));

  Future<bool> verify(
    String fingerprint,
    Future<bool> Function(HostKeyChallenge) confirm, {
    String host = 'server',
    int port = 22,
    KnownHosts? store,
  }) => (store ?? hosts).verify(
    host: host,
    port: port,
    keyType: 'ssh-ed25519',
    fingerprint: utf8.encode(fingerprint),
    confirm: confirm,
  );

  test(
    'first use requires consent; rejecting does not persist trust',
    () async {
      expect(
        await verify('SHA256:first', (challenge) async {
          expect(challenge.host, 'server');
          expect(challenge.fingerprint, 'SHA256:first');
          expect(challenge.previousFingerprint, isNull);
          return false;
        }),
        isFalse,
      );
      expect(await file.exists(), isFalse);
    },
  );

  test('trust survives restart and is scoped to host and port', () async {
    expect(await verify('SHA256:first', (_) async => true), isTrue);
    final restarted = KnownHosts(file: () async => file);
    expect(
      await verify(
        'SHA256:first',
        (_) async => fail('already trusted'),
        host: 'SERVER',
        store: restarted,
      ),
      isTrue,
    );
    expect(
      await verify('SHA256:first', (_) async => false, port: 2222),
      isFalse,
    );
    expect(
      await verify('SHA256:first', (_) async => false, host: 'other'),
      isFalse,
    );
  });

  test(
    'changed key requires explicit replacement and rejection retains old key',
    () async {
      await verify('SHA256:first', (_) async => true);
      expect(
        await verify('SHA256:second', (challenge) async {
          expect(challenge.previousFingerprint, 'SHA256:first');
          return false;
        }),
        isFalse,
      );
      expect(
        await verify('SHA256:first', (_) async => fail('old key lost')),
        isTrue,
      );
      expect(await verify('SHA256:second', (_) async => true), isTrue);
      expect(
        await verify('SHA256:second', (_) async => fail('not persisted')),
        isTrue,
      );
    },
  );

  test(
    'concurrent different keys cannot both be treated as first use',
    () async {
      final entered = Completer<void>();
      final accept = Completer<bool>();
      final first = verify('SHA256:first', (_) {
        entered.complete();
        return accept.future;
      });
      await entered.future;
      final second = verify('SHA256:second', (challenge) async {
        expect(challenge.previousFingerprint, 'SHA256:first');
        return false;
      });
      accept.complete(true);
      expect(await first, isTrue);
      expect(await second, isFalse);
    },
  );

  test(
    'unreadable trust data fails closed and does not poison the queue',
    () async {
      await file.writeAsString('broken json');
      await expectLater(
        verify('SHA256:first', (_) async => fail('must not prompt')),
        throwsFormatException,
      );
      await file.delete();
      expect(await verify('SHA256:first', (_) async => true), isTrue);
    },
  );

  BackgroundSession session() => BackgroundSession(
    sessionId: 's',
    displayName: 'server',
    username: 'u',
    port: 22,
    identities: [],
    connectionType: ConnectionType.ssh,
    sshHost: 'server',
    knownHosts: hosts,
  );

  test('host-key IPC replays on attach and ignores stale responses', () async {
    final client = session()..uiAttached = true;
    final firstPrompt = Completer<HostKeyRequestEvent>();
    final events = <HostKeyRequestEvent>[];
    client.onSendToUi = (raw) {
      final event = ServiceEvent.decode(raw);
      if (event is HostKeyRequestEvent) {
        events.add(event);
        if (!firstPrompt.isCompleted) firstPrompt.complete(event);
      }
    };
    final verification = client.verifyHostKey(
      'ssh-ed25519',
      utf8.encode('SHA256:first'),
    );
    final request = await firstPrompt.future;
    client.onDetach();
    client.onAttach();
    expect(events, hasLength(2));
    expect(events.last.requestId, request.requestId);
    client.handleHostKeyResponse(
      HostKeyResponseCommand(
        sessionId: 'other',
        requestId: request.requestId,
        accepted: true,
      ),
    );
    client.handleHostKeyResponse(
      HostKeyResponseCommand(
        sessionId: 's',
        requestId: 'stale',
        accepted: true,
      ),
    );
    expect(await file.exists(), isFalse);
    client.handleHostKeyResponse(
      HostKeyResponseCommand(
        sessionId: 's',
        requestId: request.requestId,
        accepted: true,
      ),
    );
    expect(await verification, isTrue);
  });

  test(
    'disconnect rejects a pending host key and never persists late approval',
    () async {
      final client = session()..uiAttached = true;
      final entered = Completer<HostKeyRequestEvent>();
      client.onSendToUi = (raw) {
        final event = ServiceEvent.decode(raw);
        if (event is HostKeyRequestEvent) entered.complete(event);
      };
      final verification = client.verifyHostKey(
        'ssh-ed25519',
        utf8.encode('SHA256:first'),
      );
      final request = await entered.future;
      await client.disconnect();
      client.handleHostKeyResponse(
        HostKeyResponseCommand(
          sessionId: 's',
          requestId: request.requestId,
          accepted: true,
        ),
      );
      expect(await verification, isFalse);
      expect(await file.exists(), isFalse);
    },
  );
}
