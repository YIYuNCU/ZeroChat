import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'secure_backend_client.dart';
import 'storage_service.dart';

class AvatarCacheService {
  static const String _metaStorageKey = 'avatar_cache_meta_v1';
  static final Map<String, dynamic> _meta = {};
  static bool _initialized = false;

  static Future<void> _ensureInitialized() async {
    if (_initialized) return;
    final raw = StorageService.getString(_metaStorageKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) {
          _meta
            ..clear()
            ..addAll(decoded);
        }
      } catch (e) {
        debugPrint('AvatarCacheService: failed to parse cache meta: $e');
      }
    }
    _initialized = true;
  }

  static Future<void> _persistMeta() async {
    await StorageService.setString(_metaStorageKey, jsonEncode(_meta));
  }

  static String _normalizeUrl(String remoteUrl) {
    // Drop query params for cache identity.
    final uri = Uri.tryParse(remoteUrl);
    if (uri == null) return remoteUrl;
    return uri.replace(query: '').toString();
  }

  static String _pickExtension(String remoteUrl) {
    final uri = Uri.tryParse(remoteUrl);
    final path = (uri?.path ?? remoteUrl).toLowerCase();
    if (path.endsWith('.png')) return 'png';
    if (path.endsWith('.webp')) return 'webp';
    if (path.endsWith('.gif')) return 'gif';
    if (path.endsWith('.jpeg')) return 'jpeg';
    if (path.endsWith('.jpg')) return 'jpg';
    return 'jpg';
  }

  static Future<String?> resolveAvatarPath({
    required String cacheKey,
    required String remoteUrl,
    String? backendHash,
  }) async {
    if (remoteUrl.isEmpty) return null;

    await _ensureInitialized();
    final normalizedUrl = _normalizeUrl(remoteUrl);
    final file = await _cachedFileFor(cacheKey, normalizedUrl);
    final entry = (_meta[cacheKey] as Map?)?.cast<String, dynamic>();

    final entryPath = entry?['local_path'] as String?;
    final entryHash = entry?['backend_hash'] as String?;
    final entryUrl = entry?['remote_url'] as String?;

    final hasExistingFile =
        entryPath != null &&
        entryPath.isNotEmpty &&
        await File(entryPath).exists();

    final hashMatches =
        backendHash != null &&
        backendHash.isNotEmpty &&
        backendHash == entryHash;

    final urlMatches = entryUrl == normalizedUrl;

    final canReuse =
        hasExistingFile &&
        (hashMatches ||
            ((backendHash == null || backendHash.isEmpty) && urlMatches));

    if (canReuse) {
      // 命中缓存时刷新 updated_at，使 LRU 逐出可按最近使用排序。
      if (entry != null) {
        entry['updated_at'] = DateTime.now().toIso8601String();
        _meta[cacheKey] = entry;
        await _persistMeta();
      }
      return entryPath;
    }

    try {
      final response = await SecureBackendClient.getRaw(remoteUrl);
      if (response.statusCode >= 200 && response.statusCode < 300) {
        if (!await file.parent.exists()) {
          await file.parent.create(recursive: true);
        }
        // 扩展名变化会产生新路径，先删除旧文件避免孤儿残留。
        if (entryPath != null &&
            entryPath.isNotEmpty &&
            entryPath != file.path) {
          try {
            final oldFile = File(entryPath);
            if (await oldFile.exists()) {
              await oldFile.delete();
            }
          } catch (e) {
            debugPrint('AvatarCacheService: failed to delete stale file $entryPath: $e');
          }
        }
        await file.writeAsBytes(response.bodyBytes, flush: true);

        _meta[cacheKey] = {
          'remote_url': normalizedUrl,
          'backend_hash': backendHash ?? '',
          'local_path': file.path,
          'updated_at': DateTime.now().toIso8601String(),
        };
        await _persistMeta();
        await _enforceCacheLimit();
        return file.path;
      }
      debugPrint(
        'AvatarCacheService: download failed ${response.statusCode} -> $remoteUrl',
      );
    } catch (e) {
      debugPrint('AvatarCacheService: download error for $remoteUrl: $e');
    }

    // Download failed: fallback to old local file if it exists.
    if (hasExistingFile) {
      return entryPath;
    }
    return null;
  }

  static Future<File> _cachedFileFor(String cacheKey, String remoteUrl) async {
    final docsDir = await getApplicationDocumentsDirectory();
    final avatarsDir = Directory(
      '${docsDir.path}${Platform.pathSeparator}avatar_cache',
    );
    final ext = _pickExtension(remoteUrl);
    return File('${avatarsDir.path}${Platform.pathSeparator}$cacheKey.$ext');
  }

  /// 逐出指定缓存项：删除本地文件 + 删除 meta 条目 + 持久化。
  /// 角色删除时调用（cacheKey 约定为 `role_<id>_avatar`）。
  static Future<void> evict(String cacheKey) async {
    await _ensureInitialized();
    final entry = (_meta[cacheKey] as Map?)?.cast<String, dynamic>();
    final entryPath = entry?['local_path'] as String?;
    if (entryPath != null && entryPath.isNotEmpty) {
      try {
        final file = File(entryPath);
        if (await file.exists()) {
          await file.delete();
        }
      } catch (e) {
        debugPrint('AvatarCacheService: evict failed to delete $entryPath: $e');
      }
    }
    if (_meta.remove(cacheKey) != null) {
      await _persistMeta();
    }
  }

  /// 逐出所有以 [prefix] 开头的缓存项（如某角色的 `role_<id>_avatar`、
  /// `role_<id>_avatar_moments`、`role_<id>_avatar_moments_post` 等变体）。
  static Future<void> evictByPrefix(String prefix) async {
    await _ensureInitialized();
    final keys = _meta.keys.where((k) => k.startsWith(prefix)).toList();
    if (keys.isEmpty) return;
    var changed = false;
    for (final key in keys) {
      final entry = (_meta[key] as Map?)?.cast<String, dynamic>();
      final entryPath = entry?['local_path'] as String?;
      if (entryPath != null && entryPath.isNotEmpty) {
        try {
          final file = File(entryPath);
          if (await file.exists()) {
            await file.delete();
          }
        } catch (e) {
          debugPrint('AvatarCacheService: evictByPrefix delete failed $entryPath: $e');
        }
      }
      if (_meta.remove(key) != null) {
        changed = true;
      }
    }
    if (changed) {
      await _persistMeta();
    }
  }

  // 缓存上限：文件数与总字节数任一超出即按 LRU 逐出最旧文件。
  static const int _maxCacheFiles = 200;
  static const int _maxCacheBytes = 100 * 1024 * 1024; // 100MB

  /// 按 updated_at 升序（最旧优先）逐出，直到文件数与总大小回到上限内。
  static Future<void> _enforceCacheLimit() async {
    try {
      // 收集所有仍存在的缓存文件及其大小/时间。
      final entries = <_CacheEntry>[];
      var totalBytes = 0;
      for (final key in _meta.keys.toList()) {
        final entry = (_meta[key] as Map?)?.cast<String, dynamic>();
        final path = entry?['local_path'] as String?;
        if (path == null || path.isEmpty) continue;
        final file = File(path);
        if (!await file.exists()) {
          // meta 指向已不存在的文件：顺手清理条目。
          _meta.remove(key);
          continue;
        }
        final size = await file.length();
        final updatedAt =
            DateTime.tryParse(entry?['updated_at'] as String? ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0);
        entries.add(_CacheEntry(key: key, path: path, size: size, updatedAt: updatedAt));
        totalBytes += size;
      }

      if (entries.length <= _maxCacheFiles && totalBytes <= _maxCacheBytes) {
        return;
      }

      entries.sort((a, b) => a.updatedAt.compareTo(b.updatedAt));
      var fileCount = entries.length;
      var changed = false;
      for (final e in entries) {
        if (fileCount <= _maxCacheFiles && totalBytes <= _maxCacheBytes) {
          break;
        }
        try {
          final file = File(e.path);
          if (await file.exists()) {
            await file.delete();
          }
        } catch (err) {
          debugPrint('AvatarCacheService: LRU delete failed ${e.path}: $err');
        }
        _meta.remove(e.key);
        totalBytes -= e.size;
        fileCount -= 1;
        changed = true;
      }
      if (changed) {
        await _persistMeta();
      }
    } catch (e) {
      debugPrint('AvatarCacheService: _enforceCacheLimit error: $e');
    }
  }
}

class _CacheEntry {
  final String key;
  final String path;
  final int size;
  final DateTime updatedAt;

  _CacheEntry({
    required this.key,
    required this.path,
    required this.size,
    required this.updatedAt,
  });
}
