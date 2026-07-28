import 'dart:async';
import 'dart:io';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import '../models/message.dart';
import '../models/stats_config.dart';
import '../core/message_parts.dart';
import '../services/sticker_service.dart';
import '../services/emoji_transfer_service.dart';
import '../services/settings_service.dart';
import '../services/secure_backend_client.dart';
import '../services/secure_websocket_client.dart';
import '../services/role_service.dart';
import 'smart_avatar_image.dart';

/// ZeroChat 风格聊天气泡组件
/// 支持文字、表情包、引用显示和长按操作
class ChatBubble extends StatelessWidget {
  final Message message;
  final bool isSender;
  final String? avatarUrl;
  final String? avatarHash;
  final String senderName;

  /// 长按回调
  final VoidCallback? onLongPress;

  /// 引用回调
  final VoidCallback? onQuote;

  /// 收藏回调
  final VoidCallback? onFavorite;

  /// 删除回调
  final VoidCallback? onDelete;

  /// 重发回调（发送失败时）
  final VoidCallback? onRetry;

  const ChatBubble({
    super.key,
    required this.message,
    required this.isSender,
    this.avatarUrl,
    this.avatarHash,
    this.senderName = '',
    this.onLongPress,
    this.onQuote,
    this.onFavorite,
    this.onDelete,
    this.onRetry,
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

                if (isSender && message.sendStatus == MessageSendStatus.failed)
                  Padding(
                    padding: const EdgeInsets.only(right: 8, top: 8),
                    child: GestureDetector(
                      onTap: onRetry,
                      behavior: HitTestBehavior.opaque,
                      child: const Icon(
                        Icons.error,
                        color: Colors.red,
                        size: 18,
                      ),
                    ),
                  ),

                if (isSender && message.sendStatus == MessageSendStatus.sending)
                  const Padding(
                    padding: EdgeInsets.only(right: 8, top: 10),
                    child: SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor:
                            AlwaysStoppedAnimation<Color>(Colors.grey),
                      ),
                    ),
                  ),

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
            // 缩略图按显示上限解码，避免把全分辨率原图（最高 1920px）塞进图片缓存。
            cacheWidth:
                (200 * MediaQuery.of(context).devicePixelRatio).round(),
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
          // 正文按标签的原始顺序逐片段渲染。
          ..._buildBodyParts(),
        ],
      ),
    );
  }

  /// 构建消息正文各片段（对话/动作/心理/事实/数值）。
  List<Widget> _buildBodyParts() {
    final parts = MessageParts.parse(
      message.content,
      allowFact: isSender,
      allowNoReply: !isSender,
    );
    final role = isSender ? null : RoleService.getRoleById(message.senderId);
    final showAction = role?.showAction ?? true;
    final showPsychology = role?.showPsychology ?? true;
    final showStats = role?.showStats ?? true;
    final widgets = <Widget>[];

    void addPart(Widget widget, {double spacing = 6}) {
      widgets.add(
        Padding(
          padding: EdgeInsets.only(top: widgets.isEmpty ? 0 : spacing),
          child: widget,
        ),
      );
    }

    for (final part in parts.parts) {
      switch (part.type) {
        case MessagePartType.dialogue:
          addPart(_buildDialogue(part.text));
          break;
        case MessagePartType.action:
          if (showAction) addPart(_buildAction(part.text));
          break;
        case MessagePartType.psychology:
          if (showPsychology) addPart(_buildPsychology(part.text));
          break;
        case MessagePartType.fact:
          // parse(allowFact: false) 已保证 AI 事实块不会进入此分支。
          addPart(_buildFact(part.text), spacing: 8);
          break;
        case MessagePartType.stats:
          if (showStats && part.stats != null && part.stats!.isNotEmpty) {
            addPart(_buildStats(part.stats!, role?.statsConfig), spacing: 8);
          }
          break;
        case MessagePartType.noReply:
          addPart(_buildNoReply(part.text));
          break;
      }
    }

    if (widgets.isEmpty && parts.parts.isEmpty && message.content.isNotEmpty) {
      widgets.add(_buildDialogue(message.content));
    }
    return widgets;
  }

  Widget _buildDialogue(String text) {
    return Text(
      text,
      style: const TextStyle(
        fontSize: 17,
        color: Color(0xFF000000),
        height: 1.4,
      ),
    );
  }

  Widget _buildPsychology(String text) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const Padding(
          padding: EdgeInsets.only(top: 2, right: 4),
          child: Icon(
            Icons.psychology_alt_outlined,
            size: 15,
            color: Color(0xFF9C7BB8),
          ),
        ),
        Flexible(
          child: Text(
            text,
            style: const TextStyle(
              fontSize: 14,
              fontStyle: FontStyle.italic,
              color: Color(0xFF8A6FA6),
              height: 1.3,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildAction(String text) {
    return Text(
      text,
      style: const TextStyle(
        fontSize: 14,
        fontStyle: FontStyle.italic,
        color: Color(0xFF888888),
        height: 1.3,
      ),
    );
  }

  Widget _buildFact(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF4D6),
        borderRadius: BorderRadius.circular(6),
        border: const Border(
          left: BorderSide(color: Color(0xFFD89B21), width: 3),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 1, right: 5),
            child: Icon(
              Icons.fact_check_outlined,
              size: 15,
              color: Color(0xFF9A6800),
            ),
          ),
          Flexible(
            child: Text(
              text,
              style: const TextStyle(
                fontSize: 14,
                color: Color(0xFF684700),
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNoReply(String text) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(
          Icons.notifications_off_outlined,
          size: 15,
          color: Color(0xFF888888),
        ),
        const SizedBox(width: 5),
        Text(
          text,
          style: const TextStyle(
            fontSize: 13,
            fontStyle: FontStyle.italic,
            color: Color(0xFF888888),
          ),
        ),
      ],
    );
  }

  Widget _buildStats(Map<String, String> stats, StatsConfig? config) {
    final items = config?.stats ?? const <StatItem>[];
    // 建立 key -> 定义 映射，用于显示名称与画进度条
    final defByKey = {for (final s in items) s.key: s};

    final chips = <Widget>[];
    stats.forEach((key, value) {
      final def = defByKey[key];
      final label = def?.name.isNotEmpty == true ? def!.name : key;
      final numValue = double.tryParse(value);
      double? ratio;
      if (def != null && numValue != null && def.max > def.min) {
        ratio = ((numValue - def.min) / (def.max - def.min)).clamp(0.0, 1.0);
      }
      chips.add(_buildStatChip(label, value, ratio));
    });

    return Wrap(spacing: 6, runSpacing: 6, children: chips);
  }

  Widget _buildStatChip(String label, String value, double? ratio) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFFF0F2F5),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFE0E3E8)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: const TextStyle(fontSize: 12, color: Color(0xFF666666)),
              ),
              const SizedBox(width: 4),
              Text(
                value,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF333333),
                ),
              ),
            ],
          ),
          if (ratio != null) ...[
            const SizedBox(height: 3),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: SizedBox(
                width: 64,
                height: 4,
                child: LinearProgressIndicator(
                  value: ratio,
                  backgroundColor: const Color(0xFFE0E3E8),
                  valueColor: const AlwaysStoppedAnimation<Color>(
                    Color(0xFF7BC857),
                  ),
                ),
              ),
            ),
          ],
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

    final resolvedPath = _resolveStickerImagePath(imagePath.trim());

    if (EmojiTransferService.isTransferReference(resolvedPath)) {
      return _TransferStickerContent(
        key: ValueKey(message.id),
        reference: resolvedPath,
        emotion: emotion,
      );
    }

    return Container(
      constraints: const BoxConstraints(maxWidth: 120, maxHeight: 120),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: resolvedPath.startsWith('http')
            ? _buildNetworkStickerWithRetry(resolvedPath, emotion)
            : File(resolvedPath).existsSync()
            ? Image.file(
                File(resolvedPath),
                fit: BoxFit.contain,
                // 120px 显示上限 × 3（覆盖最高 DPR）解码，免全分辨率贴图。
                cacheWidth: 360,
                errorBuilder: (_, __, ___) => _buildStickerPlaceholder(emotion),
              )
            : _buildStickerPlaceholder(emotion),
      ),
    );
  }

  static Widget _buildLocalSticker(String localPath, String? emotion) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 120, maxHeight: 120),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.file(
          File(localPath),
          fit: BoxFit.contain,
          cacheWidth: 360,
          errorBuilder: (_, __, ___) => _buildStickerPlaceholder(emotion),
        ),
      ),
    );
  }

  String _resolveStickerImagePath(String rawPath) {
    if (rawPath.startsWith('/files/emojis/') ||
        rawPath.startsWith('/files/user-emojis/')) {
      final base = SettingsService.instance.backendUrl.trim();
      if (base.isNotEmpty) {
        return '${base.replaceAll(RegExp(r'/+$'), '')}$rawPath';
      }
    }

    if (rawPath.startsWith('/api/emojis/') ||
        rawPath.startsWith('/api/user-emojis/')) {
      final base = SettingsService.instance.backendUrl.trim();
      if (base.isNotEmpty) {
        final normalized = rawPath
            .replaceFirst('/api/emojis/', '/files/emojis/')
            .replaceFirst('/api/user-emojis/', '/files/user-emojis/');
        return '${base.replaceAll(RegExp(r'/+$'), '')}$normalized';
      }
    }
    return rawPath;
  }

  Widget _buildNetworkStickerWithRetry(String imageUrl, String? emotion) {
    return CachedNetworkImage(
      imageUrl: imageUrl,
      httpHeaders: SecureBackendClient.authHeaders,
      fit: BoxFit.contain,
      // 120px 显示上限 × 3 解码，限制内存位图大小。
      memCacheWidth: 360,
      placeholder: (_, __) => _buildStickerPlaceholder(emotion),
      errorWidget: (_, __, ___) {
        final retryUrl = _buildBaseRetryUrl(imageUrl);
        if (retryUrl == null || retryUrl == imageUrl) {
          return _buildStickerPlaceholder(emotion);
        }

        return CachedNetworkImage(
          imageUrl: retryUrl,
          httpHeaders: SecureBackendClient.authHeaders,
          fit: BoxFit.contain,
          memCacheWidth: 360,
          placeholder: (_, __) => _buildStickerPlaceholder(emotion),
          errorWidget: (_, __, ___) => _buildStickerPlaceholder(emotion),
          fadeInDuration: const Duration(milliseconds: 100),
        );
      },
      fadeInDuration: const Duration(milliseconds: 150),
    );
  }

  String? _buildBaseRetryUrl(String imageUrl) {
    final base = SettingsService.instance.backendUrl.trim();
    if (base.isEmpty) {
      return null;
    }

    final uri = Uri.tryParse(imageUrl);
    if (uri == null || !uri.hasAbsolutePath) {
      return null;
    }

    final path = uri.path;
    if (!(path.startsWith('/api/emojis/') ||
        path.startsWith('/api/user-emojis/') ||
        path.startsWith('/files/emojis/') ||
        path.startsWith('/files/user-emojis/'))) {
      return null;
    }

    final normalizedPath = path
        .replaceFirst('/api/emojis/', '/files/emojis/')
        .replaceFirst('/api/user-emojis/', '/files/user-emojis/');

    var candidate = '${base.replaceAll(RegExp(r'/+$'), '')}$normalizedPath';
    if (uri.hasQuery) {
      candidate = '$candidate?${uri.query}';
    }
    if (uri.hasFragment) {
      candidate = '$candidate#${uri.fragment}';
    }
    return candidate;
  }

  /// 表情包占位符
  static Widget _buildStickerPlaceholder(String? emotion) {
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
  static String _getEmotionEmoji(String? emotion) {
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
      final fullUrl = SettingsService.instance.userAvatarFullUrl;
      if (fullUrl.isNotEmpty) {
        effectiveAvatarUrl = fullUrl;
      }
    }

    String? effectiveAvatarHash = avatarHash;
    if (!isSender && message.senderId.isNotEmpty) {
      final role = RoleService.getRoleById(message.senderId);
      effectiveAvatarHash = role?.avatarHash ?? effectiveAvatarHash;
    }

    final cacheKey = isSender
        ? 'user_self_avatar'
        : 'role_${message.senderId}_avatar';

    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: Container(
        width: 40,
        height: 40,
        color: isSender ? const Color(0xFF7EB7E7) : const Color(0xFFE7C77E),
        child: effectiveAvatarUrl != null && effectiveAvatarUrl.isNotEmpty
            ? SmartAvatarImage(
                remoteUrl: effectiveAvatarUrl,
                cacheKey: cacheKey,
                backendHash: isSender
                    ? SettingsService.instance.userAvatarHash
                    : effectiveAvatarHash,
                width: 40,
                height: 40,
                fit: BoxFit.cover,
                fallbackBuilder: _buildDefaultAvatar,
              )
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

/// Holds the transfer Future for one message so send-status refreshes do not
/// replace FutureBuilder's active work with a new request.
class _TransferStickerContent extends StatefulWidget {
  final String reference;
  final String? emotion;

  const _TransferStickerContent({
    super.key,
    required this.reference,
    required this.emotion,
  });

  @override
  State<_TransferStickerContent> createState() =>
      _TransferStickerContentState();
}

class _TransferStickerContentState extends State<_TransferStickerContent> {
  late Future<String?> _localPathFuture;
  StreamSubscription<void>? _reconnectSubscription;
  Timer? _retryTimer;
  int _retryCount = 0;
  bool _resolved = false;
  static const int _maxRetries = 5;

  @override
  void initState() {
    super.initState();
    _startResolution();
    _reconnectSubscription =
        SecureWebSocketClient.instance.onReconnectedStream.listen((_) {
          _retryImmediately();
        });
  }

  @override
  void didUpdateWidget(covariant _TransferStickerContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.reference != widget.reference) {
      _retryTimer?.cancel();
      _retryCount = 0;
      _resolved = false;
      _startResolution();
    }
  }

  void _startResolution() {
    _localPathFuture = _resolveLocalPath();
  }

  Future<String?> _resolveLocalPath() async {
    final localPath = await EmojiTransferService.resolveLocalPath(
      widget.reference,
    );
    if (localPath != null) {
      _resolved = true;
    } else {
      _scheduleRetry();
    }
    return localPath;
  }

  void _scheduleRetry() {
    if (!mounted || _retryTimer != null || _retryCount >= _maxRetries) {
      return;
    }
    final delaySeconds = 1 << _retryCount;
    _retryCount += 1;
    _retryTimer = Timer(Duration(seconds: delaySeconds), () {
      _retryTimer = null;
      _retryImmediately();
    });
  }

  void _retryImmediately() {
    if (!mounted || _resolved) {
      return;
    }
    _retryTimer?.cancel();
    _retryTimer = null;
    setState(_startResolution);
  }

  @override
  void dispose() {
    _retryTimer?.cancel();
    _reconnectSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String?>(
      future: _localPathFuture,
      builder: (context, snapshot) {
        final localPath = snapshot.data;
        if (localPath == null) {
          return ChatBubble._buildStickerPlaceholder(widget.emotion);
        }
        return ChatBubble._buildLocalSticker(localPath, widget.emotion);
      },
    );
  }

  Widget _buildPlaceholder(String? emotion) {
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

  static String _getEmotionEmoji(String? emotion) {
    switch (emotion) {
      case 'happy':
        return '🙂';
      case 'sad':
        return '😢';
      case 'angry':
        return '😠';
      case 'shy':
        return '😊';
      case 'love':
        return '❤️';
      case 'confused':
        return '😕';
      case 'surprised':
        return '😮';
      case 'sleepy':
        return '😴';
      default:
        return '😐';
    }
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
