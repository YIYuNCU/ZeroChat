import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:zerochat/services/local_storage_service.dart';

void main() {
  late Directory workspace;
  late Directory documentsDirectory;
  late LocalStorageService storageService;

  setUp(() async {
    workspace = await Directory.systemTemp.createTemp('zerochat_storage_test_');
    documentsDirectory = Directory(path.join(workspace.path, 'documents'));
    await documentsDirectory.create(recursive: true);
    storageService = LocalStorageService(
      documentsDirectoryProvider: () async => documentsDirectory,
      temporaryDirectoryProvider: () async => workspace,
    );
  });

  tearDown(() async {
    if (await workspace.exists()) {
      await workspace.delete(recursive: true);
    }
  });

  test('reports an absent storage directory as empty', () async {
    final info = await storageService.getCategoryInfo(
      LocalStorageCategory.avatarCache,
    );

    expect(info.isEmpty, isTrue);
    expect(info.fileCount, 0);
    expect(info.totalBytes, 0);
  });

  test('summarizes nested files and exports relative paths to zip', () async {
    final archiveDirectory = Directory(
      path.join(documentsDirectory.path, 'message_archives', 'nested'),
    );
    await archiveDirectory.create(recursive: true);
    final first = File(path.join(archiveDirectory.path, 'first.jsonl'));
    final second = File(
      path.join(documentsDirectory.path, 'message_archives', 'second.jsonl'),
    );
    await first.writeAsString('first');
    await second.writeAsString('second file');

    final info = await storageService.getCategoryInfo(
      LocalStorageCategory.chatArchives,
    );

    expect(info.fileCount, 2);
    expect(info.totalBytes, 'first'.length + 'second file'.length);
    expect(
      info.files.map((file) => file.relativePath),
      containsAll([path.join('nested', 'first.jsonl'), 'second.jsonl']),
    );

    final exported = await storageService.exportCategory(
      LocalStorageCategory.chatArchives,
    );
    final zip = ZipDecoder().decodeBytes(await exported.readAsBytes());
    expect(
      zip.files.map((file) => file.name),
      containsAll(['nested/first.jsonl', 'second.jsonl']),
    );
  });
}
