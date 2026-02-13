import 'dart:io';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import '../models/message.dart';
import '../services/sticker_service.dart';
import '../services/settings_service.dart';

/// ZeroChat 风格聊天气泡组件
/// 支持文字、表情包、引用显示和长按操作
class ChatBubble extends StatelessWidget {
  final Message message;
  final bool isSender;
  final String? avatarUrl;
  final String senderName;

  /// 长按回调
  final VoidCallback? onLongPress;

  /// 引用回调
  final VoidCallback? onQuote;

  /// 收藏回调
  final VoidCallback? onFavorite;

  /// 删除回调
  final VoidCallback? onDelete;

  const ChatBubble({
    super.key,
    required this.message,
    required this.isSender,
    this.avatarUrl,
    this.senderName = '',
    this.onLongPress,
    this.onQuote,
    this.onFavorite,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Row(
        mainAxisAlignment: isSender
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 接收方头像（左侧）
          if (!isSender) _buildAvatar(),
          if (!isSender) const SizedBox(width: 8),

          // 气泡内容
          Flexible(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 接收方气泡尖角（左侧）
                if (!isSender && !_isSticker) _buildBubbleArrow(isLeft: true),

                // 气泡主体（长按菜单）
                Flexible(
                  child: GestureDetector(
                    onLongPress: () => _showContextMenu(context),
                    child: _buildBubbleContent(context),
                  ),
                ),

                // 发送方气泡尖角（右侧）
                if (isSender && !_isSticker) _buildBubbleArrow(isLeft: false),
              ],
            ),
          ),

          // 发送方头像（右侧）
          if (isSender) const SizedBox(width: 8),
          if (isSender) _buildAvatar(),
        ],
      ),
    );
  }

  /// 是否是表情包消息
  bool get _isSticker => message.type == MessageType.sticker;

  /// 是否是图片消息
  bool get _isImage => message.type == MessageType.image;

  /// 构建气泡内容
  Widget _buildBubbleContent(BuildContext context) {
    if (_isSticker) {
      return _buildStickerContent();
    }
    if (_isImage) {
      return _buildImageContent(context);
    }
    return _buildTextContent(context);
  }

  /// 构建图片内容
  Widget _buildImageContent(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: GestureDetector(
        onTap: () {
          // 点击查看大图
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => Scaffold(
                backgroundColor: Colors.black,
                appBar: AppBar(
                  backgroundColor: Colors.black,
                  iconTheme: const IconThemeData(color: Colors.white),
                ),
                body: Center(
                  child: InteractiveViewer(
                    child: Image.file(File(message.content)),
                  ),
                ),
              ),
            ),
          );
        },
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 200, maxHeight: 300),
          child: Image.file(
            File(message.content),
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => Container(
              width: 150,
              height: 100,
              color: Colors.grey[300],
              child: const Center(
                child: Icon(Icons.broken_image, size: 40, color: Colors.grey),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 构建文字内容
  Widget _buildTextContent(BuildContext context) {
    return Container(
      constraints: BoxConstraints(
        maxWidth: MediaQuery.of(context).size.width * 0.65,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      decoration: BoxDecoration(
        color: isSender ? const Color(0xFF95EC69) : Colors.white,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // 引用块（如果有）
          if (message.hasQuote) ...[
            _buildQuoteBlock(),
            const SizedBox(height: 6),
          ],
          // 正文
          Text(
            message.content,
            style: const TextStyle(
              fontSize: 17,
              color: Color(0xFF000000),
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }

  /// 构建引用块（ZeroChat 风格：左侧竖线 + 灰色背景）
  Widget _buildQuoteBlock() {
    return Container(
      padding: const EdgeInsets.only(left: 8, top: 4, bottom: 4, right: 8),
      decoration: BoxDecoration(
        color: isSender
            ? const Color(0xFF7BC857).withValues(alpha: 0.5)
            : const Color(0xFFEEEEEE),
        borderRadius: BorderRadius.circular(2),
        border: Border(
          left: BorderSide(
            color: isSender ? const Color(0xFF5BA93D) : const Color(0xFFCCCCCC),
            width: 2,
          ),
        ),
      ),
      child: Text(
        message.quotedPreviewText ?? '',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 13,
          color: isSender ? const Color(0xFF2E5A1E) : const Color(0xFF888888),
        ),
      ),
    );
  }

  /// 构建表情包内容
  Widget _buildStickerContent() {
    final (isSticker, emotion, imagePath) = StickerService.parseStickerMessage(
      message.content,
    );

    if (!isSticker || imagePath == null) {
      return const SizedBox.shrink();
    }

    return Container(
      constraints: const BoxConstraints(maxWidth: 120, maxHeight: 120),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: imagePath.startsWith('http')
            ? CachedNetworkImage(
                imageUrl: imagePath,
                fit: BoxFit.contain,
                placeholder: (_, __) => _buildStickerPlaceholder(emotion),
                errorWidget: (_, __, ___) => _buildStickerPlaceholder(emotion),
                fadeInDuration: const Duration(milliseconds: 150),
              )
            : File(imagePath).existsSync()
            ? Image.file(
                File(imagePath),
                fit: BoxFit.contain,
                errorBuilder: (_, __, ___) => _buildStickerPlaceholder(emotion),
              )
            : _buildStickerPlaceholder(emotion),
      ),
    );
  }

  /// 表情包占位符
  Widget _buildStickerPlaceholder(String? emotion) {
    return Container(
      width: 80,
      height: 80,
      decoration: BoxDecoration(
        color: const Color(0xFFF5F5F5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Center(
        child: Text(
          _getEmotionEmoji(emotion),
          style: const TextStyle(fontSize: 40),
        ),
      ),
    );
  }

  /// 获取情绪对应的 emoji
  String _getEmotionEmoji(String? emotion) {
    switch (emotion) {
      case 'happy':
        return '😊';
      case 'sad':
        return '😢';
      case 'angry':
        return '😠';
      case 'shy':
        return '😳';
      case 'love':
        return '❤️';
      case 'confused':
        return '😕';
      case 'sleepy':
        return '😴';
      case 'suprised':
        return '😮';
      case 'tired':
        return '😩';
      default:
        return '😊';
    }
  }

  /// 显示长按菜单
  void _showContextMenu(BuildContext context) {
    // 如果有 onLongPress 回调，优先使用它（用于多选模式）
    if (onLongPress != null) {
      onLongPress!();
      return;
    }

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 多选
            ListTile(
              leading: const Icon(Icons.checklist, color: Color(0xFF07C160)),
              title: const Text('多选'),
              onTap: () {
                Navigator.pop(context);
                onLongPress?.call();
              },
            ),
            const Divider(height: 1),
            // 引用
            ListTile(
              leading: const Icon(Icons.reply, color: Color(0xFF2196F3)),
              title: const Text('引用'),
              onTap: () {
                Navigator.pop(context);
                onQuote?.call();
              },
            ),
            const Divider(height: 1),
            // 删除
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.red),
              title: const Text('删除'),
              onTap: () {
                Navigator.pop(context);
                onDelete?.call();
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  /// 构建头像
  Widget _buildAvatar() {
    // 对于发送者（用户），使用 SettingsService 的头像
    String? effectiveAvatarUrl = avatarUrl;
    if (isSender) {
      final userAvatar = SettingsService.instance.userAvatarUrl;
      if (userAvatar.isNotEmpty) {
        // 如果是相对路径，加上后端URL前缀
        if (userAvatar.startsWith('/')) {
          effectiveAvatarUrl =
              '${SettingsService.instance.backendUrl}$userAvatar';
        } else {
          effectiveAvatarUrl = userAvatar;
        }
      }
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: Container(
        width: 40,
        height: 40,
        color: isSender ? const Color(0xFF7EB7E7) : const Color(0xFFE7C77E),
        child: effectiveAvatarUrl != null && effectiveAvatarUrl.isNotEmpty
            ? (effectiveAvatarUrl.startsWith('http')
                  ? Image.network(
                      effectiveAvatarUrl,
                      width: 40,
                      height: 40,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => _buildDefaultAvatar(),
                    )
                  : Image.file(
                      File(effectiveAvatarUrl),
                      width: 40,
                      height: 40,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => _buildDefaultAvatar(),
                    ))
            : _buildDefaultAvatar(),
      ),
    );
  }

  /// 默认头像内容
  Widget _buildDefaultAvatar() {
    return Center(
      child: Icon(
        isSender ? Icons.person : Icons.smart_toy,
        color: Colors.white,
        size: 24,
      ),
    );
  }

  /// 构建气泡尖角
  Widget _buildBubbleArrow({required bool isLeft}) {
    return CustomPaint(
      size: const Size(6, 12),
      painter: _BubbleArrowPainter(
        color: isLeft ? Colors.white : const Color(0xFF95EC69),
        isLeft: isLeft,
      ),
    );
  }
}

/// 气泡尖角绘制器
class _BubbleArrowPainter extends CustomPainter {
  final Color color;
  final bool isLeft;

  _BubbleArrowPainter({required this.color, required this.isLeft});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    final path = Path();

    if (isLeft) {
      path.moveTo(size.width, 0);
      path.lineTo(0, size.height / 2);
      path.lineTo(size.width, size.height);
    } else {
      path.moveTo(0, 0);
      path.lineTo(size.width, size.height / 2);
      path.lineTo(0, size.height);
    }

    path.close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
