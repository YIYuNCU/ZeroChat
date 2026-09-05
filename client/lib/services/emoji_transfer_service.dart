import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'secure_websocket_client.dart';
import 'settings_service.dart';
import 'storage_service.dart';

/// Downloads protected emoji assets over the encrypted WebSocket in bounded chunks.
class EmojiTransferService {
  EmojiTransferService._();

  static const int _maxFileSize = 12 * 1024 * 1024;

  /// Bounded cache budget so downloaded emoji assets never grow without limit.
  /// Applied to the whole `emoji_cache/` directory after each successful write.
  static const int _maxCacheFiles = 500;
  static const int _maxCacheBytes = 200 * 1024 * 1024;

  static final Map<String, Future<String?>> _inFlight = {};
  static final Map<String, String> _paths = {};
  static final Map<String, int> _versions = {};
  static final Map<String, DateTime> _accessTimes = {};
  static final Set<String> _activeParts = {};
  static Future<void>? _indexFuture;
  static Future<void> _mutationTail = Future<void>.value();
  static int _epoch = 0;
  static int _downloadId = 0;
  static Timer? _maintenanceTimer;
  static const _legacyOriginKey = 'emoji_cache_legacy_origin_v1';

  static Future<T> _mutate<T>(Future<T> Function() operation) {
    final next = _mutationTail.then((_) => operation());
    _mutationTail = next.then<void>(
      (_) {},
      onError: (Object e, StackTrace s) {},
    );
    return next;
  }

  static String _key(String reference, String origin) =>
      sha256.convert(utf8.encode('$origin|$reference')).toString();

  static void _scheduleMaintenance() {
    _maintenanceTimer ??= Timer(const Duration(seconds: 3), () {
      _maintenanceTimer = null;
      unawaited(trimToBudget());
    });
  }

  static bool isTransferReference(String value) =>
      value.trim().startsWith('ws-emoji://');

  static Future<String?> resolveLocalPath(
    String reference, {
    @visibleForTesting
    Future<Map<String, dynamic>> Function(String, Map<String, dynamic>)?
    request,
  }) {
    final normalized = reference.trim();
    if (!isTransferReference(normalized)) return Future.value(null);
    final origin = SettingsService.instance.backendUrl;
    final epoch = _epoch;
    final version = _versions[_key(normalized, origin)] ?? 0;
    final requestKey = '${_key(normalized, origin)}|$epoch|$version';
    return _inFlight.putIfAbsent(
      requestKey,
      () => _download(normalized, origin, epoch, version, request ?? _request)
          .whenComplete(() {
            _inFlight.remove(requestKey);
          }),
    );
  }

  static Future<Map<String, dynamic>> _request(
    String action,
    Map<String, dynamic> payload,
  ) => SecureWebSocketClient.instance.request(
    action,
    payload,
    timeout: const Duration(seconds: 20),
  );

  static Future<void> invalidate(String reference) {
    final origin = SettingsService.instance.backendUrl;
    final key = _key(reference.trim(), origin);
    _versions[key] = (_versions[key] ?? 0) + 1;
    final legacyKey = sha256.convert(utf8.encode(reference.trim())).toString();
    final paths = <String>{
      if (_paths[key] != null) _paths.remove(key)!,
      if (StorageService.getString(_legacyOriginKey) == origin &&
          _paths[legacyKey] != null)
        _paths.remove(legacyKey)!,
    };
    return _mutate(() async {
      for (final path in paths) {
        _accessTimes.remove(path);
        try {
          if (await File(path).exists()) await File(path).delete();
        } catch (_) {}
      }
    });
  }

  /// Runs bounded cache maintenance without opening an emoji transfer.
  static Future<void> trimToBudget() async {
    try {
      final root = await getApplicationDocumentsDirectory();
      final cacheDir = Directory(
        '${root.path}${Platform.pathSeparator}emoji_cache',
      );
      await _mutate(() async {
        final accesses = Map<String, DateTime>.from(_accessTimes);
        _accessTimes.clear();
        for (final entry in accesses.entries) {
          try {
            await File(entry.key).setLastModified(entry.value);
          } catch (_) {}
        }
        await _enforceCacheBudget(cacheDir);
      });
    } catch (error) {
      debugPrint('EmojiTransferService: cache maintenance failed: $error');
    }
  }

  /// Clears only downloaded transfer assets. Imported sticker files are stored
  /// elsewhere and are never affected.
  static Future<void> clearCache() {
    _epoch++;
    _versions.clear();
    _paths.clear();
    _accessTimes.clear();
    _indexFuture = null;
    _maintenanceTimer?.cancel();
    _maintenanceTimer = null;
    return _mutate(_clearCache);
  }

  static Future<void> _clearCache() async {
    final root = await getApplicationDocumentsDirectory();
    final cacheDir = Directory(
      '${root.path}${Platform.pathSeparator}emoji_cache',
    );
    if (await cacheDir.exists()) {
      await for (final file in cacheDir.list(followLinks: false)) {
        if (file is File && !_activeParts.contains(file.path)) {
          await file.delete();
        }
      }
    }
  }

  static Future<String?> _download(
    String reference,
    String origin,
    int epoch,
    int version,
    Future<Map<String, dynamic>> Function(String, Map<String, dynamic>) request,
  ) async {
    File? partial;
    bool current() =>
        epoch == _epoch &&
        origin == SettingsService.instance.backendUrl &&
        (_versions[_key(reference, origin)] ?? 0) == version;
    try {
      await _mutationTail;
      if (!current()) return null;
      final cachedPath = await _findCachedPath(reference, origin, epoch);
      if (!current()) return null;
      if (cachedPath != null) {
        return cachedPath;
      }

      final init = await request('emoji_file_init', {'reference': reference});
      final transferId = (init['transfer_id'] ?? '').toString();
      final totalChunks = init['total_chunks'] as int? ?? 0;
      final size = init['size'] as int? ?? -1;
      final filename = (init['filename'] ?? '').toString();
      final expectedHash = (init['sha256'] ?? '').toString();
      if (transferId.isEmpty ||
          totalChunks <= 0 ||
          size < 0 ||
          size > _maxFileSize) {
        return null;
      }

      final root = await getApplicationDocumentsDirectory();
      final cacheDir = Directory(
        '${root.path}${Platform.pathSeparator}emoji_cache',
      );
      if (!await cacheDir.exists()) {
        await cacheDir.create(recursive: true);
      }

      final extension = _extensionFrom(filename);
      if (!current()) return null;
      final cacheKey = _key(reference, origin);
      final target = File(
        '${cacheDir.path}${Platform.pathSeparator}$cacheKey.$extension',
      );
      final temp = File('${target.path}.${_downloadId++}.part');
      partial = temp;
      _activeParts.add(temp.path);
      final sink = temp.openWrite();
      var received = 0;
      try {
        for (var index = 0; index < totalChunks; index += 1) {
          if (!current()) return null;
          final chunk = await request('emoji_file_chunk', {
            'transfer_id': transferId,
            'chunk_index': index,
          });
          if (chunk['chunk_index'] != index ||
              chunk['chunk_base64'] is! String) {
            throw const FormatException('invalid emoji chunk response');
          }
          final bytes = base64Decode(chunk['chunk_base64'] as String);
          received += bytes.length;
          if (received > size) {
            throw const FormatException('emoji size overflow');
          }
          sink.add(bytes);
        }
      } finally {
        await sink.close();
      }
      if (received != size) {
        throw const FormatException('incomplete emoji transfer');
      }
      if (expectedHash.isNotEmpty) {
        final actualHash = sha256.convert(await temp.readAsBytes()).toString();
        if (actualHash != expectedHash) {
          throw const FormatException('emoji checksum mismatch');
        }
      }
      return await _mutate(() async {
        if (!current()) return null;
        if (await target.exists()) await target.delete();
        await temp.rename(target.path);
        if (!current()) {
          await target.delete();
          return null;
        }
        _paths[cacheKey] = target.path;
        _scheduleMaintenance();
        return target.path;
      });
    } catch (error) {
      debugPrint('EmojiTransferService: transfer failed: $error');
      return null;
    } finally {
      if (partial != null) {
        _activeParts.remove(partial.path);
        try {
          if (await partial.exists()) await partial.delete();
        } catch (_) {}
      }
    }
  }

  static String _extensionFrom(String filename) {
    final dot = filename.lastIndexOf('.');
    if (dot < 0 || dot == filename.length - 1) return 'img';
    final extension = filename.substring(dot + 1).toLowerCase();
    return RegExp(r'^[a-z0-9]{1,5}$').hasMatch(extension) ? extension : 'img';
  }

  /// Cached emoji file names are derived from their stable transfer reference.
  /// Look there before contacting the server so historical stickers render
  /// immediately after an app restart, including while reconnecting offline.
  static Future<void> _loadIndex(
    Directory cacheDir,
    String origin,
    int epoch,
  ) async {
    final found = <String, String>{};
    if (await cacheDir.exists()) {
      await for (final entry in cacheDir.list(followLinks: false)) {
        if (entry is! File) continue;
        final name = entry.uri.pathSegments.last;
        if (RegExp(r'^[a-f0-9]{64}\.[a-z0-9]{1,5}$').hasMatch(name)) {
          found[name.substring(0, 64)] = entry.path;
        }
      }
    }
    if (epoch != _epoch) return;
    _paths.addAll(found);
    if (StorageService.getString(_legacyOriginKey) == null) {
      await StorageService.setString(_legacyOriginKey, origin);
    }
  }

  static Future<String?> _findCachedPath(
    String reference,
    String origin,
    int epoch,
  ) async {
    try {
      final root = await getApplicationDocumentsDirectory();
      final cacheDir = Directory(
        '${root.path}${Platform.pathSeparator}emoji_cache',
      );
      await (_indexFuture ??= _loadIndex(cacheDir, origin, epoch));
      if (epoch != _epoch) return null;
      final cacheKey = _key(reference, origin);
      final legacyKey = sha256.convert(utf8.encode(reference)).toString();
      final path =
          _paths[cacheKey] ??
          (StorageService.getString(_legacyOriginKey) == origin
              ? _paths[legacyKey]
              : null);
      if (path == null) return null;
      final file = File(path);
      if (!await file.exists() || await file.length() == 0) {
        _paths.removeWhere((key, value) => value == path);
        return null;
      }
      _accessTimes[path] = DateTime.now();
      _scheduleMaintenance();
      return path;
    } catch (error) {
      debugPrint('EmojiTransferService: local cache lookup failed: $error');
    }
    return null;
  }

  /// Keeps the on-disk emoji cache bounded by file count and total bytes.
  /// Stale `.part` files are dropped first, then the oldest complete files are
  /// evicted until both limits are satisfied. Cleanup failures are non-fatal
  /// and never interrupt rendering of a freshly downloaded sticker.
  static Future<void> _enforceCacheBudget(Directory cacheDir) async {
    try {
      if (!await cacheDir.exists()) return;

      final files = <File>[];
      await for (final entry in cacheDir.list(followLinks: false)) {
        if (entry is! File) continue;
        final name = entry.path.split(Platform.pathSeparator).last;
        if (name.endsWith('.part')) {
          if (_activeParts.contains(entry.path)) continue;
          try {
            await entry.delete();
          } catch (_) {}
          continue;
        }
        files.add(entry);
      }

      if (files.length <= _maxCacheFiles) {
        var totalBytes = 0;
        for (final file in files) {
          totalBytes += await _safeLength(file);
        }
        if (totalBytes <= _maxCacheBytes) return;
      }

      // Sort oldest-first by modification time so recent stickers survive.
      final stats = <File, ({int size, DateTime modified})>{};
      for (final file in files) {
        try {
          final stat = await file.stat();
          stats[file] = (size: stat.size, modified: stat.modified);
        } catch (_) {
          stats[file] = (
            size: 0,
            modified: DateTime.fromMillisecondsSinceEpoch(0),
          );
        }
      }
      files.sort((a, b) => stats[a]!.modified.compareTo(stats[b]!.modified));

      var count = files.length;
      var totalBytes = files.fold<int>(0, (sum, f) => sum + stats[f]!.size);

      for (final file in files) {
        if (count <= _maxCacheFiles && totalBytes <= _maxCacheBytes) break;
        try {
          await file.delete();
          _paths.removeWhere((key, value) => value == file.path);
          count -= 1;
          totalBytes -= stats[file]!.size;
        } catch (_) {}
      }
    } catch (error) {
      debugPrint('EmojiTransferService: cache cleanup failed: $error');
    }
  }

  static Future<int> _safeLength(File file) async {
    try {
      return await file.length();
    } catch (_) {
      return 0;
    }
  }
}
