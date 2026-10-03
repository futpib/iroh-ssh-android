import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:iroh_ssh_app/services/fs/local_fs.dart';

void main() {
  late Directory directory;
  late Directory root;
  late File outside;
  late LocalFs fs;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('local-boundary-');
    root = await Directory('${directory.path}/files').create();
    outside = await File(
      '${directory.path}/private-key',
    ).writeAsString('private');
    fs = LocalFs(root: root.path);
  });
  tearDown(() => directory.delete(recursive: true));

  test(
    'Up stops at the root and service rejects parent paths before initialDir',
    () async {
      expect(fs.parentOf(root.path), root.path);
      expect(fs.parentOf('${root.path}/sub'), root.path);
      await expectLater(
        fs.list(directory.path),
        throwsA(isA<FileSystemException>()),
      );
      await expectLater(
        fs.stat('${root.path}/../private-key'),
        throwsA(isA<FileSystemException>()),
      );
      await expectLater(
        fs.mkdir('${root.path}/../new'),
        throwsA(isA<FileSystemException>()),
      );
    },
  );

  test(
    'file imports and exports work but cannot read or overwrite a sibling',
    () async {
      final inside = '${root.path}/copy';
      await fs.upload(outside.path, inside).drain<void>();
      final exported = '${directory.path}/export';
      await fs.download(inside, exported).drain<void>();
      expect(await File(exported).readAsString(), 'private');
      await expectLater(
        fs.download(outside.path, '${root.path}/stolen').drain<void>(),
        throwsA(isA<FileSystemException>()),
      );
      await expectLater(
        fs.upload(inside, outside.path).drain<void>(),
        throwsA(isA<FileSystemException>()),
      );
      await expectLater(
        fs.rename(inside, outside.path),
        throwsA(isA<FileSystemException>()),
      );
      await expectLater(
        fs.remove(root.path, recursive: true),
        throwsA(isA<FileSystemException>()),
      );
      expect(await outside.readAsString(), 'private');
    },
  );

  test(
    'symlink targets outside the root cannot be browsed, read or overwritten',
    () async {
      final link = await Link('${root.path}/escape').create(directory.path);
      await expectLater(
        fs.list(link.path),
        throwsA(isA<FileSystemException>()),
      );
      await expectLater(
        fs.stat('${link.path}/private-key'),
        throwsA(isA<FileSystemException>()),
      );
      await expectLater(
        fs.mkdir('${link.path}/new'),
        throwsA(isA<FileSystemException>()),
      );
      await expectLater(
        fs.upload(outside.path, '${link.path}/private-key').drain<void>(),
        throwsA(isA<FileSystemException>()),
      );
      // Unlinking a link is safe: it must not delete or traverse the target.
      await fs.remove(link.path, recursive: true);
      expect(await outside.readAsString(), 'private');
      expect(await link.exists(), isFalse);
    },
  );

  test('links within the root remain usable', () async {
    final sub = await Directory('${root.path}/sub').create();
    await File('${sub.path}/note').writeAsString('hello');
    final link = await Link('${root.path}/alias').create(sub.path);
    expect((await fs.list(link.path)).single.name, 'note');
  });
}
