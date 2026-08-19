import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../core/message_store.dart';
import 'avatar_cache_service.dart';
import 'emoji_transfer_service.dart';
import 'media_cache_service.dart';

enum LocalStorageCategory { chatArchives, emojiCache, avatarCache }

extension LocalStorageCategoryDetails on LocalStorageCategory {
  String get label => switch (this) {
    LocalStorageCategory.chatArchives => '聊天记录',
    LocalStorageCategory.emojiCache => '下载表情缓存',
    LocalStorageCategory.avatarCache => '头像缓存',
  };

  String get directoryName => switch (this) {
    LocalStorageCategory.chatArchives => 'message_archives',
    LocalStorageCategory.emojiCache => 'emoji_cache',
    LocalStorageCategory.avatarCache => 'avatar_cache',
  };

  String get emptyMessage => switch (this) {
    LocalStorageCategory.chatArchives => '暂无本地聊天记录',
    LocalStorageCategory.emojiCache => '暂无下载表情缓存',
    LocalStorageCategory.avatarCache => '暂无头像缓存',
  };
}

class LocalStorageFileInfo {
  const LocalStorageFileInfo({
    required this.file,
    required this.relativePath,
    required this.sizeBytes,
    required this.modifiedAt,
  });

  final File file;
  final String relativePath;
  final int sizeBytes;
  final DateTime modifiedAt;
}

class LocalStorageCategoryInfo {
  const LocalStorageCategoryInfo({
    required this.category,
    required this.directory,
    required this.files,
    required this.totalBytes,
    this.latestModifiedAt,
  });

  final LocalStorageCategory category;
  final Directory directory;
  final List<LocalStorageFileInfo> files;
  final int totalBytes;
  final DateTime? latestModifiedAt;

  int get fileCount => files.length;
  bool get isEmpty => files.isEmpty;
}

/// Inspects and manages only disposable local data. User-created stickers,
/// settings, tasks, and secure credentials deliberately do not appear here.
class LocalStorageService {
  LocalStorageService({
    Future<Directory> Function()? documentsDirectoryProvider,
    Future<Directory> Function()? temporaryDirectoryProvider,
  }) : _documentsDirectoryProvider =
           documentsDirectoryProvider ?? getApplicationDocumentsDirectory,
       _temporaryDirectoryProvider =
           temporaryDirectoryProvider ?? getTemporaryDirectory;

  static final instance = LocalStorageService();

  final Future<Directory> Function() _documentsDirectoryProvider;
  final Future<Directory> Function() _temporaryDirectoryProvider;

  Future<List<LocalStorageCategoryInfo>> listCategories() {
    return Future.wait(LocalStorageCategory.values.map(getCategoryInfo));
  }

  Future<LocalStorageCategoryInfo> getCategoryInfo(
    LocalStorageCategory category,
  ) async {
    final directory = await _directoryFor(category);
    return inspectDirectory(category, directory);
  }

  Future<File> exportCategory(LocalStorageCategory category) async {
    final info = await getCategoryInfo(category);
    if (info.isEmpty) {
      throw StateError('${category.label}没有可导出的文件');
    }

    final temporaryDirectory = await _temporaryDirectoryProvider();
    final output = File(
      path.join(
        temporaryDirectory.path,
        'zerochat_${category.directoryName}_${DateTime.now().millisecondsSinceEpoch}.zip',
      ),
    );
    final encoder = ZipFileEncoder();
    encoder.create(output.path);
    try {
      for (final item in info.files) {
        await encoder.addFile(item.file, item.relativePath);
      }
    } finally {
      encoder.close();
    }
    return output;
  }

  Future<void> deleteCategory(LocalStorageCategory category) async {
    switch (category) {
      case LocalStorageCategory.chatArchives:
        await MessageStore.instance.clearAllLocalChatData();
      case LocalStorageCategory.emojiCache:
        await EmojiTransferService.clearCache();
      case LocalStorageCategory.avatarCache:
        await AvatarCacheService.clearAll();
        MediaCacheService.clearInMemoryImageCache();
    }
  }

  Future<Directory> _directoryFor(LocalStorageCategory category) async {
    final documentsDirectory = await _documentsDirectoryProvider();
    return Directory(
      path.join(documentsDirectory.path, category.directoryName),
    );
  }

  static Future<LocalStorageCategoryInfo> inspectDirectory(
    LocalStorageCategory category,
    Directory directory,
  ) async {
    if (!await directory.exists()) {
      return LocalStorageCategoryInfo(
        category: category,
        directory: directory,
        files: const [],
        totalBytes: 0,
      );
    }

    final files = <LocalStorageFileInfo>[];
    await for (final entity in directory.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File) continue;
      try {
        final stat = await entity.stat();
        files.add(
          LocalStorageFileInfo(
            file: entity,
            relativePath: path.relative(entity.path, from: directory.path),
            sizeBytes: stat.size,
            modifiedAt: stat.modified,
          ),
        );
      } on FileSystemException {
        // A concurrent cache cleanup can remove a file while it is inspected.
      }
    }
    files.sort((a, b) => b.modifiedAt.compareTo(a.modifiedAt));
    final latestModifiedAt = files.isEmpty ? null : files.first.modifiedAt;
    return LocalStorageCategoryInfo(
      category: category,
      directory: directory,
      files: List.unmodifiable(files),
      totalBytes: files.fold(0, (total, item) => total + item.sizeBytes),
      latestModifiedAt: latestModifiedAt,
    );
  }
}
