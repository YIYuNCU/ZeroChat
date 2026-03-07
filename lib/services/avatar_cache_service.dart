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
      return entryPath;
    }

    try {
      final response = await SecureBackendClient.getRaw(remoteUrl);
      if (response.statusCode >= 200 && response.statusCode < 300) {
        if (!await file.parent.exists()) {
          await file.parent.create(recursive: true);
        }
        await file.writeAsBytes(response.bodyBytes, flush: true);

        _meta[cacheKey] = {
          'remote_url': normalizedUrl,
          'backend_hash': backendHash ?? '',
          'local_path': file.path,
          'updated_at': DateTime.now().toIso8601String(),
        };
        await _persistMeta();
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
    return File('${avatarsDir.path}${Platform.pathSeparator}${cacheKey}.$ext');
  }
}
