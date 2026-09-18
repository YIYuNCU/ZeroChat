import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 本地存储服务
/// 使用 SharedPreferences 持久化数据
class StorageService {
  static SharedPreferences? _prefs;
  static String namespace = '';
  static String archiveNamespace = '';

  static Future<void> configureNamespace(String identity) async {
    final legacy = prefs.getString('legacy_resource_owner');
    if (legacy == null) {
      await prefs.setString('legacy_resource_owner', identity);
    }
    namespace = identity;
    archiveNamespace = (legacy ?? identity) == identity ? '' : identity;
  }

  static String _scoped(String key) {
    if (archiveNamespace.isEmpty) return key;
    const prefixes = [
      'roles',
      'current_role',
      'core_memory',
      'scheduled_tasks',
      'moments_',
      'message',
      'pending_chat_',
      'rendered_chat_',
      'emoji_',
      'chat_list',
      'group',
      'json_memory_',
      'proactive_config_',
      'role_model_profile_selections',
    ];
    return prefixes.any(key.startsWith) ? 'backend_${namespace}_$key' : key;
  }

  /// 初始化存储服务
  static Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    debugPrint('StorageService initialized');
  }

  /// 获取 SharedPreferences 实例
  static SharedPreferences get prefs {
    if (_prefs == null) {
      throw Exception('StorageService not initialized. Call init() first.');
    }
    return _prefs!;
  }

  // ========== 通用方法 ==========

  static Future<bool> setString(String key, String value) async {
    return await prefs.setString(_scoped(key), value);
  }

  static String? getString(String key) {
    return prefs.getString(_scoped(key));
  }

  static Future<bool> setStringList(String key, List<String> value) async {
    return await prefs.setStringList(_scoped(key), value);
  }

  static List<String>? getStringList(String key) {
    return prefs.getStringList(_scoped(key));
  }

  static Future<bool> setInt(String key, int value) async {
    return await prefs.setInt(_scoped(key), value);
  }

  static int? getInt(String key) {
    return prefs.getInt(_scoped(key));
  }

  static Future<bool> setBool(String key, bool value) async {
    return await prefs.setBool(_scoped(key), value);
  }

  static bool? getBool(String key) {
    return prefs.getBool(_scoped(key));
  }

  static Future<bool> remove(String key) async {
    return await prefs.remove(_scoped(key));
  }

  // ========== JSON 对象存储 ==========

  static Future<bool> setJson(String key, Map<String, dynamic> json) async {
    return await setString(key, jsonEncode(json));
  }

  static Map<String, dynamic>? getJson(String key) {
    final str = getString(key);
    if (str == null) return null;
    try {
      return jsonDecode(str) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('Error parsing JSON for key $key: $e');
      return null;
    }
  }

  static Future<bool> setJsonList(
    String key,
    List<Map<String, dynamic>> list,
  ) async {
    return await setString(key, jsonEncode(list));
  }

  static List<Map<String, dynamic>>? getJsonList(String key) {
    final str = getString(key);
    if (str == null) return null;
    try {
      final list = jsonDecode(str) as List;
      return list.map((e) => e as Map<String, dynamic>).toList();
    } catch (e) {
      debugPrint('Error parsing JSON list for key $key: $e');
      return null;
    }
  }

  // ========== 存储键定义 ==========

  static const String keyRoles = 'roles';
  static const String keyRolesHash = 'roles_hash';
  static const String keyCurrentRoleId = 'current_role_id';
  static const String keyCoreMemory = 'core_memory';
  static const String keyScheduledTasks = 'scheduled_tasks';
  static const String keyChatApiConfig = 'chat_api_config';
  static const String keyIntentApiConfig = 'intent_api_config';
}
