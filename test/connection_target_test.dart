import 'package:flutter_test/flutter_test.dart';
import 'package:iroh_ssh_app/models/connection_target.dart';
import 'package:iroh_ssh_app/models/connection_type.dart';

void main() {
  group('Iroh target', () {
    test('requires a username and a 64-character hexadecimal endpoint ID', () {
      final endpoint = 'A1' * 32;
      final target = ConnectionTarget.parse(
        ' alice@$endpoint ',
        ConnectionType.iroh,
      );

      expect(target.username, 'alice');
      expect(target.endpointId, endpoint.toLowerCase());
      expect(target.port, 22);
      expect(target.formatted, 'alice@${endpoint.toLowerCase()}');
    });

    for (final input in [
      '',
      'alice',
      'alice@abcd',
      'alice@${'g0' * 32}',
      'alice@@${'a0' * 32}',
    ]) {
      test('rejects $input', () {
        expect(
          () => ConnectionTarget.parse(input, ConnectionType.iroh),
          throwsFormatException,
        );
      });
    }
  });

  group('SSH target', () {
    test('parses hostnames, explicit ports, and ssh URLs', () {
      final standard = ConnectionTarget.parse(
        'alice@example.com',
        ConnectionType.ssh,
      );
      final port = ConnectionTarget.parse(
        'alice@example.com:2222',
        ConnectionType.ssh,
      );
      final uri = ConnectionTarget.parse(
        'ssh://alice@example.com:2200',
        ConnectionType.ssh,
      );

      expect(standard.formatted, 'alice@example.com');
      expect(port.host, 'example.com');
      expect(port.port, 2222);
      expect(port.formatted, 'alice@example.com:2222');
      expect(uri.formatted, 'alice@example.com:2200');
    });

    test('parses and preserves bracketed IPv6 addresses', () {
      final target = ConnectionTarget.parse(
        'alice@[2001:db8::1]:2222',
        ConnectionType.ssh,
      );

      expect(target.host, '2001:db8::1');
      expect(target.port, 2222);
      expect(target.formatted, 'alice@[2001:db8::1]:2222');
    });

    for (final input in [
      '',
      'example.com',
      '@example.com',
      'alice@',
      'alice@example.com:0',
      'alice@example.com:65536',
      'alice@example.com:not-a-port',
      'alice@2001:db8::1',
      'alice@example.com/path',
      'alice@example.com?query',
    ]) {
      test('rejects $input', () {
        expect(
          () => ConnectionTarget.parse(input, ConnectionType.ssh),
          throwsFormatException,
        );
      });
    }
  });
}
