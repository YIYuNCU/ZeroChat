import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'storage_service.dart';

/// 敏感数据安全存储服务
///
/// 用平台 Keystore/Keychain 保存密钥类数据（各类 API Key、后端鉴权 token、
/// 传输加密 secret），替代明文 SharedPreferences。启动时对旧明文值做一次性
/// 迁移：搬入 secure storage 后从 SharedPreferences 删除。
class SecureStorageService {
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  /// 需要走安全存储的敏感键（与旧 SharedPreferences 键名保持一致，便于迁移）。
  static const List<String> sensitiveKeys = [
    'chat_api_key',
    'intent_api_key',
    'vision_api_key',
    'embedding_api_key',
    'backend_auth_token',
    'backend_encryption_secret',
  ];

  /// 内存缓存：secure storage 为异步接口，同步 getter 从此缓存读取。
  static final Map<String, String> _cache = {};

  /// 初始化：加载所有敏感键到缓存，并迁移历史明文值。
  static Future<void> init() async {
    // 一次性迁移：SharedPreferences 里如仍有明文值，搬入 secure storage 并清除。
    for (final key in sensitiveKeys) {
      final legacy = StorageService.getString(key);
      if (legacy != null && legacy.isNotEmpty) {
        try {
          final existing = await _storage.read(key: key);
          if (existing == null || existing.isEmpty) {
            await _storage.write(key: key, value: legacy);
          }
          await StorageService.remove(key);
          debugPrint('SecureStorageService: migrated "$key" to secure storage');
        } catch (e) {
          debugPrint('SecureStorageService: migrate "$key" failed: $e');
        }
      }
    }

    try {
      final all = await _storage.readAll();
      _cache
        ..clear()
        ..addAll(all);
    } catch (e) {
      debugPrint('SecureStorageService: readAll failed: $e');
    }
    debugPrint('SecureStorageService initialized (${_cache.length} keys)');
  }

  /// 同步读取（来自内存缓存，init 后可用）。
  static String getString(String key) => _cache[key] ?? '';

  static bool has(String key) => (_cache[key] ?? '').isNotEmpty;

  /// 写入并更新缓存。
  static Future<void> setString(String key, String value) async {
    _cache[key] = value;
    try {
      await _storage.write(key: key, value: value);
    } catch (e) {
      debugPrint('SecureStorageService: write "$key" failed: $e');
    }
  }

  static Future<void> remove(String key) async {
    _cache.remove(key);
    try {
      await _storage.delete(key: key);
    } catch (e) {
      debugPrint('SecureStorageService: delete "$key" failed: $e');
    }
  }
}
