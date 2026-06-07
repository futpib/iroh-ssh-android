import 'package:flutter_test/flutter_test.dart';
import 'package:iroh_ssh_app/services/transfer_notification.dart';

void main() {
  group('transferText', () {
    test('shows sizes and a percentage when the total is known', () {
      expect(transferText(256 * 1024, 1024 * 1024), '256 KB / 1.0 MB (25%)');
      expect(transferText(2048, 4096), '2.0 KB / 4.0 KB (50%)');
    });

    test('clamps the percentage to 100', () {
      expect(transferText(120, 100), contains('(100%)'));
    });

    test('omits the percentage when the total is unknown or zero', () {
      expect(transferText(4096, null), '4.0 KB');
      expect(transferText(4096, 0), '4.0 KB');
    });
  });

  group('fmtSize', () {
    test('formats bytes through terabytes', () {
      expect(fmtSize(512), '512 B');
      expect(fmtSize(1536), '1.5 KB');
      expect(fmtSize(1024 * 1024), '1.0 MB');
      expect(fmtSize(20 * 1024 * 1024), '20 MB');
    });
  });
}
