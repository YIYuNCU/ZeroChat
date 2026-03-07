import 'package:http/http.dart' as http;

import '../models/emoji_item.dart';
import 'secure_backend_client.dart';
import 'settings_service.dart';

class EmojiService {
  static EmojiService? _instance;
  static EmojiService get instance => _instance ??= EmojiService._();

  EmojiService._();

  Future<String> _baseUrl() async {
    return SettingsService.instance.backendUrl;
  }

  Future<List<String>> getAiCategories(String roleId) async {
    final base = await _baseUrl();
    final resp = await SecureBackendClient.get('$base/api/roles/$roleId/emoji-categories');
    if (resp.statusCode != 200 || resp.data == null) {
      return [];
    }
    final raw = resp.data!['categories'];
    if (raw is! List) {
      return [];
    }
    return raw.map((e) => e.toString()).toList();
  }

  Future<bool> addAiCategory(String roleId, String category) async {
    final base = await _baseUrl();
    final resp = await SecureBackendClient.post(
      '$base/api/roles/$roleId/emoji-categories',
      {'category': category},
    );
    return resp.statusCode == 200;
  }

  Future<bool> deleteAiCategory(String roleId, String category) async {
    final base = await _baseUrl();
    final resp = await SecureBackendClient.delete(
      '$base/api/roles/$roleId/emoji-categories/$category',
    );
    return resp.statusCode == 200;
  }

  Future<List<EmojiItem>> getAiEmojis(String roleId, String category) async {
    final base = await _baseUrl();
    final resp = await SecureBackendClient.get('$base/api/roles/$roleId/emojis/$category/list');
    if (resp.statusCode != 200 || resp.data == null) {
      return [];
    }
    final raw = resp.data!['emojis'];
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
    final base = await _baseUrl();
    final file = await http.MultipartFile.fromPath('file', filePath);
    final resp = await SecureBackendClient.multipartPost(
      '$base/api/roles/$roleId/emojis/$category/upload',
      files: [file],
    );
    if (resp.statusCode != 200) {
      return null;
    }
    final body = await resp.stream.bytesToString();
    final decoded = SecureBackendClient.decodeResponseBodyString(body);
    final jsonMap = decoded is Map<String, dynamic>
        ? decoded
        : (decoded is Map ? decoded.cast<String, dynamic>() : null);
    if (jsonMap == null || jsonMap['emoji'] is! Map) {
      return null;
    }
    return EmojiItem.fromAiJson((jsonMap['emoji'] as Map).cast<String, dynamic>());
  }

  Future<bool> deleteAiEmoji({
    required String roleId,
    required String category,
    required String filename,
  }) async {
    final base = await _baseUrl();
    final resp = await SecureBackendClient.delete(
      '$base/api/roles/$roleId/emojis/$category/$filename',
    );
    return resp.statusCode == 200;
  }

  Future<List<String>> getUserCategories() async {
    final base = await _baseUrl();
    final resp = await SecureBackendClient.get('$base/api/user-emojis/categories');
    if (resp.statusCode != 200 || resp.data == null) {
      return [];
    }
    final raw = resp.data!['categories'];
    if (raw is! List) {
      return [];
    }
    return raw.map((e) => e.toString()).toList();
  }

  Future<bool> addUserCategory(String category) async {
    final base = await _baseUrl();
    final resp = await SecureBackendClient.post(
      '$base/api/user-emojis/categories',
      {'category': category},
    );
    return resp.statusCode == 200;
  }

  Future<bool> deleteUserCategory(String category) async {
    final base = await _baseUrl();
    final resp = await SecureBackendClient.delete('$base/api/user-emojis/categories/$category');
    return resp.statusCode == 200;
  }

  Future<List<EmojiItem>> getUserEmojis({String? category}) async {
    final base = await _baseUrl();
    final suffix = (category == null || category.isEmpty)
        ? ''
        : '?category=${Uri.encodeComponent(category)}';
    final resp = await SecureBackendClient.get('$base/api/user-emojis$suffix');
    if (resp.statusCode != 200 || resp.data == null) {
      return [];
    }
    final raw = resp.data!['emojis'];
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
    final base = await _baseUrl();
    final file = await http.MultipartFile.fromPath('file', filePath);
    final resp = await SecureBackendClient.multipartPost(
      '$base/api/user-emojis/upload',
      files: [file],
      fields: {
        'category': category,
        'tag': tag,
      },
    );
    if (resp.statusCode != 200) {
      return null;
    }
    final body = await resp.stream.bytesToString();
    final decoded = SecureBackendClient.decodeResponseBodyString(body);
    final jsonMap = decoded is Map<String, dynamic>
        ? decoded
        : (decoded is Map ? decoded.cast<String, dynamic>() : null);
    if (jsonMap == null || jsonMap['emoji'] is! Map) {
      return null;
    }
    return EmojiItem.fromUserJson((jsonMap['emoji'] as Map).cast<String, dynamic>());
  }

  Future<bool> deleteUserEmoji(String emojiId) async {
    final base = await _baseUrl();
    final resp = await SecureBackendClient.delete('$base/api/user-emojis/$emojiId');
    return resp.statusCode == 200;
  }

  Future<String?> resolveUserEmojiTag(String emojiId) async {
    final base = await _baseUrl();
    final resp = await SecureBackendClient.post(
      '$base/api/user-emojis/resolve-tag',
      {'emoji_id': emojiId},
    );
    if (resp.statusCode != 200 || resp.data == null) {
      return null;
    }
    return resp.data!['tag']?.toString();
  }

  String withBase(String relativeUrl, String baseUrl) {
    if (relativeUrl.startsWith('http://') || relativeUrl.startsWith('https://')) {
      return relativeUrl;
    }
    return '$baseUrl$relativeUrl';
  }

  Future<String> getImageUrl(String relativeUrl) async {
    return withBase(relativeUrl, await _baseUrl());
  }
}
