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
  static final Map<String, Future<String?>> _inFlight = {};

  static bool isTransferReference(String value) =>
      value.trim().startsWith('ws-emoji://');

  static Future<String?> resolveLocalPath(String reference) {
    final normalized = reference.trim();
    if (!isTransferReference(normalized)) return Future.value(null);
    return _inFlight.putIfAbsent(normalized, () => _download(normalized));
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
      if (transferId.isEmpty || totalChunks <= 0 || size < 0 || size > _maxFileSize) {
        return null;
      }

      final root = await getApplicationDocumentsDirectory();
      final cacheDir = Directory('${root.path}${Platform.pathSeparator}emoji_cache');
      if (!await cacheDir.exists()) await cacheDir.create(recursive: true);

      final extension = _extensionFrom(filename);
      final cacheKey = sha256.convert(utf8.encode(reference)).toString();
      final target = File('${cacheDir.path}${Platform.pathSeparator}$cacheKey.$extension');
      if (await target.exists() && await target.length() == size) return target.path;

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
          if (chunk['chunk_index'] != index || chunk['chunk_base64'] is! String) {
            throw const FormatException('invalid emoji chunk response');
          }
          final bytes = base64Decode(chunk['chunk_base64'] as String);
          received += bytes.length;
          if (received > size) throw const FormatException('emoji size overflow');
          sink.add(bytes);
        }
      } finally {
        await sink.close();
      }
      if (received != size) throw const FormatException('incomplete emoji transfer');
      if (expectedHash.isNotEmpty) {
        final actualHash = sha256.convert(await temp.readAsBytes()).toString();
        if (actualHash != expectedHash) {
          throw const FormatException('emoji checksum mismatch');
        }
      }
      if (await target.exists()) await target.delete();
      await temp.rename(target.path);
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
          return entry.path;
        }
      }
    } catch (error) {
      debugPrint('EmojiTransferService: local cache lookup failed: $error');
    }
    return null;
  }
}
