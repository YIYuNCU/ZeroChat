import 'dart:convert';
import 'dart:io';

import '../models/emoji_item.dart';
import 'secure_websocket_client.dart';

class EmojiService {
  static EmojiService? _instance;
  static EmojiService get instance => _instance ??= EmojiService._();

  EmojiService._();

  Future<List<String>> getAiCategories(String roleId) async {
    final resp = await SecureWebSocketClient.instance.request(
      'role_emoji_categories_list',
      {'role_id': roleId},
    );
    final raw = resp['categories'];
    if (raw is! List) {
      return [];
    }
    return raw.map((e) => e.toString()).toList();
  }

  Future<bool> addAiCategory(String roleId, String category) async {
    final resp = await SecureWebSocketClient.instance.request(
      'role_emoji_category_create',
      {'role_id': roleId, 'category': category},
    );
    return resp['success'] == true;
  }

  Future<bool> deleteAiCategory(String roleId, String category) async {
    final resp = await SecureWebSocketClient.instance.request(
      'role_emoji_category_delete',
      {'role_id': roleId, 'category': category},
    );
    return resp['success'] == true;
  }

  Future<List<EmojiItem>> getAiEmojis(String roleId, String category) async {
    final resp = await SecureWebSocketClient.instance.request(
      'role_emojis_list',
      {'role_id': roleId, 'category': category},
    );
    final raw = resp['emojis'];
    if (raw is! List) {
      return [];
    }
    return raw
        .whereType<Map>()
        .map((e) => EmojiItem.fromAiJson(e.cast<String, dynamic>()))
        .toList();
  }

  Future<EmojiItem?> uploadAiEmoji({
    required String roleId,
    required String category,
    required String filePath,
  }) async {
    final bytes = await File(filePath).readAsBytes();
    final filename = filePath.split(RegExp(r'[\\/]')).last;
    final resp = await SecureWebSocketClient.instance.request(
      'role_emoji_upload',
      {
        'role_id': roleId,
        'category': category,
        'filename': filename,
        'content_base64': base64Encode(bytes),
      },
    );
    if (resp['emoji'] is! Map) {
      return null;
    }
    return EmojiItem.fromAiJson((resp['emoji'] as Map).cast<String, dynamic>());
  }

  Future<bool> deleteAiEmoji({
    required String roleId,
    required String category,
    required String filename,
  }) async {
    final resp = await SecureWebSocketClient.instance.request(
      'role_emoji_delete',
      {'role_id': roleId, 'category': category, 'filename': filename},
    );
    return resp['success'] == true;
  }

  Future<List<String>> getUserCategories() async {
    final resp = await SecureWebSocketClient.instance.request(
      'user_emoji_categories_list',
      const <String, dynamic>{},
    );
    final raw = resp['categories'];
    if (raw is! List) {
      return [];
    }
    return raw.map((e) => e.toString()).toList();
  }

  Future<bool> addUserCategory(String category) async {
    final resp = await SecureWebSocketClient.instance.request(
      'user_emoji_category_create',
      {'category': category},
    );
    return resp['success'] == true;
  }

  Future<bool> deleteUserCategory(String category) async {
    final resp = await SecureWebSocketClient.instance.request(
      'user_emoji_category_delete',
      {'category': category},
    );
    return resp['success'] == true;
  }

  Future<List<EmojiItem>> getUserEmojis({String? category}) async {
    final resp = await SecureWebSocketClient.instance.request(
      'user_emojis_list',
      {'category': category},
    );
    final raw = resp['emojis'];
    if (raw is! List) {
      return [];
    }
    return raw
        .whereType<Map>()
        .map((e) => EmojiItem.fromUserJson(e.cast<String, dynamic>()))
        .toList();
  }

  Future<EmojiItem?> uploadUserEmoji({
    required String category,
    required String tag,
    required String filePath,
  }) async {
    final bytes = await File(filePath).readAsBytes();
    final filename = filePath.split(RegExp(r'[\\/]')).last;
    final resp = await SecureWebSocketClient.instance.request(
      'user_emoji_upload',
      {
        'category': category,
        'tag': tag,
        'filename': filename,
        'content_base64': base64Encode(bytes),
      },
    );
    if (resp['emoji'] is! Map) {
      return null;
    }
    return EmojiItem.fromUserJson((resp['emoji'] as Map).cast<String, dynamic>());
  }

  Future<bool> deleteUserEmoji(String emojiId) async {
    final resp = await SecureWebSocketClient.instance.request(
      'user_emoji_delete',
      {'emoji_id': emojiId},
    );
    return resp['success'] == true;
  }

  Future<String?> resolveUserEmojiTag(String emojiId) async {
    final resp = await SecureWebSocketClient.instance.request(
      'user_emoji_resolve_tag',
      {'emoji_id': emojiId},
    );
    if (resp['found'] != true) {
      return null;
    }
    return resp['tag']?.toString();
  }

  String _normalizeEmojiPath(String value) {
    final trimmed = value.trim();
    if (trimmed.startsWith('/api/emojis/')) {
      return trimmed.replaceFirst('/api/emojis/', '/files/emojis/');
    }
    if (trimmed.startsWith('/api/user-emojis/')) {
      return trimmed.replaceFirst('/api/user-emojis/', '/files/user-emojis/');
    }
    return trimmed;
  }

  String withBase(String relativeUrl, String baseUrl) {
    final normalized = _normalizeEmojiPath(relativeUrl);
    if (normalized.startsWith('http://') ||
        normalized.startsWith('https://') ||
        normalized.startsWith('data:') ||
        normalized.startsWith('file://')) {
      return normalized;
    }

    final safeBase = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    if (safeBase.isEmpty) {
      return normalized;
    }
    if (normalized.startsWith('/')) {
      return '$safeBase$normalized';
    }
    return '$safeBase/$normalized';
  }

  Future<String> getImageUrl(String relativeUrl) async {
    return withBase(relativeUrl, '');
  }
}
