import 'package:flutter_test/flutter_test.dart';
import 'package:iroh_ssh_app/services/fs/upload_naming.dart';
import 'package:path/path.dart' as p;

void main() {
  group('disambiguateFileName', () {
    test('inserts " (n)" before a simple extension', () {
      expect(disambiguateFileName('report.txt', 1), 'report (1).txt');
      expect(disambiguateFileName('report.txt', 2), 'report (2).txt');
    });

    test('splits on the last dot (compound extension)', () {
      expect(disambiguateFileName('archive.tar.gz', 1), 'archive.tar (1).gz');
      expect(disambiguateFileName('a.b.c', 3), 'a.b (3).c');
    });

    test('appends when there is no extension', () {
      expect(disambiguateFileName('README', 1), 'README (1)');
    });

    test('treats a leading-dot dotfile as having no extension', () {
      expect(disambiguateFileName('.bashrc', 1), '.bashrc (1)');
    });

    test('treats a trailing dot as having no extension', () {
      expect(disambiguateFileName('name.', 1), 'name. (1)');
    });
  });

  group('resolveUploadTarget', () {
    Future<String> resolve(String name, Set<String> existing) =>
        resolveUploadTarget(
          dir: '/d',
          name: name,
          join: p.posix.join,
          listNames: (_) async => existing.toList(),
        );

    test('uses the plain name when nothing collides', () async {
      expect(await resolve('x.txt', {}), '/d/x.txt');
      expect(await resolve('x.txt', {'other.txt'}), '/d/x.txt');
    });

    test('appends (1) on a single collision', () async {
      expect(await resolve('x.txt', {'x.txt'}), '/d/x (1).txt');
    });

    test('walks to the first free suffix', () async {
      expect(await resolve('x.txt', {'x.txt', 'x (1).txt'}), '/d/x (2).txt');
      expect(
        await resolve('x.txt', {'x.txt', 'x (1).txt', 'x (2).txt'}),
        '/d/x (3).txt',
      );
    });

    test('a free original beats existing suffixed names', () async {
      // "x (1).txt" exists but "x.txt" itself does not — keep the original.
      expect(await resolve('x.txt', {'x (1).txt'}), '/d/x.txt');
    });

    test('disambiguates extensionless and dotfile names', () async {
      expect(await resolve('README', {'README'}), '/d/README (1)');
      expect(await resolve('.env', {'.env'}), '/d/.env (1)');
    });

    test('falls back to the plain target when listing fails', () async {
      final path = await resolveUploadTarget(
        dir: '/d',
        name: 'x.txt',
        join: p.posix.join,
        listNames: (_) async => throw Exception('cannot list'),
      );
      expect(path, '/d/x.txt');
    });
  });
}
