import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import '../models/sticker.dart';

/// 表情包管理服务
class StickerService {
  static final Random _random = Random();
  static const String _stickerDirName = 'stickers';

  /// 获取表情包存储目录
  static Future<Directory> getStickerDirectory(String roleId) async {
    final appDir = await getApplicationDocumentsDirectory();
    final stickerDir = Directory('${appDir.path}/$_stickerDirName/$roleId');
    if (!await stickerDir.exists()) {
      await stickerDir.create(recursive: true);
    }
    return stickerDir;
  }

  /// 导入表情包图片
  static Future<Sticker?> importSticker({
    required String roleId,
    required String sourcePath,
    required String emotion,
    String? name,
  }) async {
    try {
      final sourceFile = File(sourcePath);
      if (!await sourceFile.exists()) {
        debugPrint('StickerService: Source file not found: $sourcePath');
        return null;
      }

      final stickerDir = await getStickerDirectory(roleId);
      final extension = sourcePath.split('.').last;
      final stickerId =
          '${DateTime.now().millisecondsSinceEpoch}_${_random.nextInt(1000)}';
      final targetPath = '${stickerDir.path}/$stickerId.$extension';

      await sourceFile.copy(targetPath);

      return Sticker(
        id: stickerId,
        emotion: emotion,
        imagePath: targetPath,
        name: name,
      );
    } catch (e) {
      debugPrint('StickerService: Error importing sticker: $e');
      return null;
    }
  }

  /// 删除表情包文件
  static Future<bool> deleteSticker(String imagePath) async {
    try {
      final file = File(imagePath);
      if (await file.exists()) {
        await file.delete();
      }
      return true;
    } catch (e) {
      debugPrint('StickerService: Error deleting sticker: $e');
      return false;
    }
  }

  /// 根据情绪随机选择一个表情包
  static Sticker? pickRandomByEmotion(StickerConfig config, String emotion) {
    final candidates = config.getByEmotion(emotion);
    if (candidates.isEmpty) return null;
    return candidates[_random.nextInt(candidates.length)];
  }

  /// 决定是否发送表情包（基于概率）
  static bool shouldSendSticker(StickerConfig config) {
    if (!config.enabled) return false;
    return _random.nextDouble() < config.sendProbability;
  }

  static String? _normalizeEmotionTag(String raw) {
    final value = raw.trim().toLowerCase();
    const aliases = {
      'suprised': 'surprised',
      'surprise': 'surprised',
      'sleep': 'sleepy',
    };
    final mapped = aliases[value] ?? value;
    if (EmotionTypes.all.contains(mapped)) {
      return mapped;
    }
    return null;
  }

  /// 解析情绪标签并提取内容
  /// 返回 (cleanedText, emotion?)
  static (String, String?) parseEmotionTag(String text) {
    final regex = RegExp(r'\[(\w+)\]\s*');
    final match = regex.firstMatch(text);

    if (match != null) {
      final normalizedEmotion = _normalizeEmotionTag(match.group(1) ?? '');
      // 验证是否是有效的情绪类型
      if (normalizedEmotion != null) {
        final cleanedText = text.replaceFirst(regex, '').trim();
        return (cleanedText, normalizedEmotion);
      }
    }

    return (text, null);
  }

  /// 为表情包消息生成内容标识
  static String createStickerMessageContent(String emotion, String imagePath) {
    final storedPath = normalizeAiStickerStoragePath(imagePath);
    // Keep AI sticker payload in legacy format to stay compatible with
    // historical records and existing backend-side processors.
    return '[STICKER:$emotion:$storedPath]';
  }

  static String normalizeAiStickerStoragePath(String imagePath) {
    final raw = imagePath.trim();
    if (raw.isEmpty) return raw;

    final uri = Uri.tryParse(raw);
    if (uri != null && uri.hasScheme) {
      final path = uri.path;
      if (path.startsWith('/api/emojis/')) {
        var out = path
            .replaceFirst('/api/emojis/', '/files/emojis/')
            .replaceFirst('/api/user-emojis/', '/files/user-emojis/');
        if (uri.hasQuery) {
          out = '$out?${uri.query}';
        }
        if (uri.hasFragment) {
          out = '$out#${uri.fragment}';
        }
        return out;
      }
      if (path.startsWith('/files/emojis/') || path.startsWith('/files/user-emojis/')) {
        var out = path;
        if (uri.hasQuery) {
          out = '$out?${uri.query}';
        }
        if (uri.hasFragment) {
          out = '$out#${uri.fragment}';
        }
        return out;
      }
    }

    return raw;
  }

  /// 为用户表情消息生成内容标识
  static String createUserStickerMessageContent({
    required String category,
    required String tag,
    required String emojiId,
    required String imagePath,
  }) {
    return '[STICKER|user|$category|$tag|$emojiId|$imagePath]';
  }

  /// 解析表情包消息内容
  /// 返回 (isSticker, emotion?, imagePath?)
  static (bool, String?, String?) parseStickerMessage(String content) {
    final normalized = content.trim();

    if (!normalized.endsWith(']')) {
      return (false, null, null);
    }

    // 新格式: [STICKER|ai|emotion|url] / [STICKER|user|category|tag|emojiId|url]
    if (normalized.startsWith('[STICKER|')) {
      final inner = normalized.substring(9, normalized.length - 1);
      final parts = inner.split('|');
      if (parts.length >= 4) {
        if (parts[0] == 'ai') {
          return (true, parts[1], parts.sublist(2).join('|').trim());
        }
        // user format: [STICKER|user|category|tag|emojiId|url]
        // inner parts: [user, category, tag, emojiId, url]
        if (parts[0] == 'user' && parts.length >= 5) {
          return (true, parts[1], parts.sublist(4).join('|').trim());
        }
      }
    }

    // 兼容旧格式: [STICKER:emotion:path]
    final regex = RegExp(r'\[STICKER:(\w+):(.+)\]');
    final match = regex.firstMatch(normalized);

    if (match != null) {
      return (true, match.group(1), (match.group(2) ?? '').trim());
    }

    return (false, null, null);
  }
}
