import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'secure_websocket_client.dart';

/// Downloads protected emoji assets over the encrypted WebSocket in bounded chunks.
class EmojiTransferService {
  EmojiTransferService._();

  static const int _maxFileSize = 12 * 1024 * 1024;

  /// Bounded cache budget so downloaded emoji assets never grow without limit.
  /// Applied to the whole `emoji_cache/` directory after each successful write.
  static const int _maxCacheFiles = 500;
  static const int _maxCacheBytes = 200 * 1024 * 1024;

  static final Map<String, Future<String?>> _inFlight = {};

  static bool isTransferReference(String value) =>
      value.trim().startsWith('ws-emoji://');

  static Future<String?> resolveLocalPath(String reference) {
    final normalized = reference.trim();
    if (!isTransferReference(normalized)) return Future.value(null);
    return _inFlight.putIfAbsent(normalized, () => _download(normalized));
  }

  /// Runs bounded cache maintenance without opening an emoji transfer.
  static Future<void> trimToBudget() async {
    try {
      final root = await getApplicationDocumentsDirectory();
      final cacheDir = Directory(
        '${root.path}${Platform.pathSeparator}emoji_cache',
      );
      await _enforceCacheBudget(cacheDir);
    } catch (error) {
      debugPrint('EmojiTransferService: cache maintenance failed: $error');
    }
  }

  /// Clears only downloaded transfer assets. Imported sticker files are stored
  /// elsewhere and are never affected.
  static Future<void> clearCache() async {
    final root = await getApplicationDocumentsDirectory();
    final cacheDir = Directory(
      '${root.path}${Platform.pathSeparator}emoji_cache',
    );
    if (await cacheDir.exists()) {
      await cacheDir.delete(recursive: true);
    }
  }

  static Future<String?> _download(String reference) async {
    try {
      final cachedPath = await _findCachedPath(reference);
      if (cachedPath != null) {
        return cachedPath;
      }

      final init = await SecureWebSocketClient.instance.request(
        'emoji_file_init',
        {'reference': reference},
        timeout: const Duration(seconds: 20),
      );
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
      final cacheKey = sha256.convert(utf8.encode(reference)).toString();
      final target = File(
        '${cacheDir.path}${Platform.pathSeparator}$cacheKey.$extension',
      );
      if (await target.exists() && await target.length() == size) {
        return target.path;
      }

      final temp = File('${target.path}.part');
      if (await temp.exists()) await temp.delete();
      final sink = temp.openWrite();
      var received = 0;
      try {
        for (var index = 0; index < totalChunks; index += 1) {
          final chunk = await SecureWebSocketClient.instance.request(
            'emoji_file_chunk',
            {'transfer_id': transferId, 'chunk_index': index},
            timeout: const Duration(seconds: 20),
          );
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
      if (await target.exists()) await target.delete();
      await temp.rename(target.path);
      await _enforceCacheBudget(cacheDir);
      return target.path;
    } catch (error) {
      debugPrint('EmojiTransferService: transfer failed: $error');
      return null;
    } finally {
      _inFlight.remove(reference);
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
  static Future<String?> _findCachedPath(String reference) async {
    try {
      final root = await getApplicationDocumentsDirectory();
      final cacheDir = Directory(
        '${root.path}${Platform.pathSeparator}emoji_cache',
      );
      if (!await cacheDir.exists()) {
        return null;
      }

      final cacheKey = sha256.convert(utf8.encode(reference)).toString();
      await for (final entry in cacheDir.list(followLinks: false)) {
        if (entry is! File) {
          continue;
        }
        final name = entry.path.split(Platform.pathSeparator).last;
        if (!name.startsWith('$cacheKey.') || name.endsWith('.part')) {
          continue;
        }
        if (await entry.length() > 0) {
          // Keep frequently displayed emoji assets near the end of LRU cleanup.
          try {
            await entry.setLastModified(DateTime.now());
          } catch (error) {
            debugPrint('EmojiTransferService: cache access update failed: $error');
          }
          return entry.path;
        }
      }
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
          // Orphaned partial downloads are always safe to remove.
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
