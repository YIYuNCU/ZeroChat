import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import 'conditional_cache_service.dart';
import 'secure_backend_client.dart';
import 'settings_service.dart';

/// Disposable network media only. Never owns picked images or attachments.
class RemoteMediaCache {
  static const maximumBytes = 200 * 1024 * 1024;
  static final _pending = <String, Future<File?>>{};
  static final _activeFiles = <String, int>{};
  static Future<void> _writeMeta(File file, Map<String, dynamic> value) async {
    final temp = File('${file.path}.part');
    await temp.writeAsString(jsonEncode(value), flush: true);
    await temp.rename(file.path);
  }

  static Future<Directory> _root() async => Directory(
    '${(await getApplicationCacheDirectory()).path}/remote_media_v1',
  );
  static String get _scope =>
      '${SettingsService.instance.backendUrl}|${SecureBackendClient.cacheIdentity}';

  static Future<File?> resolve(String url) {
    final scope = _scope;
    final key = ConditionalCacheService.digest('$scope|$url');
    return _pending.putIfAbsent(
      key,
      () => _resolve(url, key, scope).whenComplete(() => _pending.remove(key)),
    );
  }

  static Future<File?> _resolve(String url, String key, String scope) async {
    final root = await _root();
    await root.create(recursive: true);
    final metaFile = File('${root.path}/$key.json');
    Map<String, dynamic> meta = {};
    File? cached;
    try {
      meta = Map<String, dynamic>.from(
        jsonDecode(await metaFile.readAsString()) as Map,
      );
      final hash = meta['hash']?.toString() ?? '';
      if (RegExp(r'^[a-f0-9]{64}$').hasMatch(hash)) {
        final file = File('${root.path}/$hash.media');
        if (await file.exists() &&
            await file.length() == meta['size'] &&
            sha256.convert(await file.readAsBytes()).toString() == hash) {
          cached = file;
        }
      }
      if (cached != null &&
          DateTime.now().millisecondsSinceEpoch -
                  (meta['checked'] as int? ?? 0) <
              300000) {
        await cached.setLastModified(DateTime.now());
        return scope == _scope ? cached : null;
      }
    } catch (_) {
      /* Missing or damaged cache is fetched again. */
    }
    try {
      if (scope != _scope) return null;
      final uri = Uri.parse(url);
      final backend = Uri.parse(SettingsService.instance.backendUrl);
      final response = await SecureBackendClient.getRaw(
        url,
        includeAuth: uri.origin == backend.origin,
        headers: {
          if (cached != null && meta['etag'] != null)
            'If-None-Match': meta['etag'].toString(),
        },
      );
      if (scope != _scope) return null;
      if (response.statusCode == 304 && cached != null) {
        meta['checked'] = DateTime.now().millisecondsSinceEpoch;
        await _writeMeta(metaFile, meta);
        return scope == _scope ? cached : null;
      }
      if (response.statusCode == 200 &&
          response.bodyBytes.isNotEmpty &&
          response.bodyBytes.length <= maximumBytes) {
        final hash = sha256.convert(response.bodyBytes).toString();
        final file = File('${root.path}/$hash.media');
        _activeFiles[file.path] = (_activeFiles[file.path] ?? 0) + 1;
        try {
          if (!await file.exists() ||
              sha256.convert(await file.readAsBytes()).toString() != hash) {
            final temp = File('${root.path}/$key.part');
            await temp.writeAsBytes(response.bodyBytes, flush: true);
            await temp.rename(file.path);
          }
          await file.setLastModified(DateTime.now());
          await _writeMeta(metaFile, {
            'hash': hash,
            'size': response.bodyBytes.length,
            'etag': response.headers['etag'],
            'checked': DateTime.now().millisecondsSinceEpoch,
          });
          await trim();
          return scope == _scope ? file : null;
        } finally {
          final remaining = _activeFiles[file.path]! - 1;
          if (remaining == 0) {
            _activeFiles.remove(file.path);
          } else {
            _activeFiles[file.path] = remaining;
          }
        }
      }
    } catch (_) {
      /* Offline: continue displaying the existing file. */
    }
    return scope == _scope ? cached : null;
  }

  static Future<void> evict(String url) async {
    final key = ConditionalCacheService.digest('$_scope|$url');
    final file = File('${(await _root()).path}/$key.json');
    if (await file.exists()) await file.delete();
  }

  static Future<void> trim() async {
    final root = await _root();
    if (!await root.exists()) return;
    final files = <({File file, FileStat stat})>[];
    await for (final entry in root.list(followLinks: false)) {
      if (entry is File && !entry.path.endsWith('.part')) {
        files.add((file: entry, stat: await entry.stat()));
      }
    }
    files.sort((a, b) => a.stat.modified.compareTo(b.stat.modified));
    var bytes = files.fold<int>(0, (sum, item) => sum + item.stat.size);
    for (final item in files) {
      if (bytes <= maximumBytes) break;
      if (_activeFiles.containsKey(item.file.path) ||
          _pending.keys.any((key) => item.file.path.endsWith('$key.json'))) {
        continue;
      }
      try {
        await item.file.delete();
        bytes -= item.stat.size;
      } catch (_) {}
    }
  }
}
