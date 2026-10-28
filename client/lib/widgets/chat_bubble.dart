import 'dart:async';
import 'dart:io';
import 'remote_media_image.dart';

import 'package:flutter/material.dart';
import '../models/message.dart';
import '../models/stats_config.dart';
import '../models/voice_message.dart';
import '../core/group_mentions.dart';
import '../core/message_parts.dart';
import '../services/sticker_service.dart';
import '../services/voice_playback_service.dart';
import '../services/emoji_transfer_service.dart';
import '../services/settings_service.dart';
import '../services/secure_backend_client.dart';
import '../services/secure_websocket_client.dart';
import '../services/role_service.dart';
import '../services/tool_call_service.dart';
import 'smart_avatar_image.dart';

/// ZeroChat 风格聊天气泡组件
/// 支持文字、表情包、引用显示和长按操作
class ChatBubble extends StatelessWidget {
  final Message message;
  final bool isSender;
  final String? avatarUrl;
  final String? avatarHash;
  final String senderName;

  /// 是否在对方气泡上方显示发送者名称（群聊中用于区分发言者）。
  final bool showSenderName;

  /// 群成员名称：非空时，正文中的「@成员名」「@所有人」会高亮显示。
  final List<String> mentionNames;

  /// 长按回调：非空时长按弹出上下文菜单（复制/引用/提醒/收藏/多选/删除）。
  /// 为 null 时（如收藏详情页只读展示）长按无操作。
  final VoidCallback? onLongPress;

  /// 复制回调
  final VoidCallback? onCopy;

  /// 引用回调
  final VoidCallback? onQuote;

  /// 提醒回调
  final VoidCallback? onRemind;

  /// 收藏回调
  final VoidCallback? onFavorite;

  /// 进入多选回调
  final VoidCallback? onMultiSelect;

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
    this.showSenderName = false,
    this.mentionNames = const [],
    this.onLongPress,
    this.onCopy,
    this.onQuote,
    this.onRemind,
    this.onFavorite,
    this.onMultiSelect,
    this.onDelete,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    if (_isHiddenNoReply) {
      return const SizedBox.shrink();
    }
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
            child: _withSenderName(
              Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 接收方气泡尖角（左侧）
                  if (!isSender && !_isSticker) _buildBubbleArrow(isLeft: true),

                  if (isSender &&
                      message.sendStatus == MessageSendStatus.failed)
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

                  if (isSender &&
                      message.sendStatus == MessageSendStatus.sending)
                    const Padding(
                      padding: EdgeInsets.only(right: 8, top: 10),
                      child: SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            Colors.grey,
                          ),
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
          ),

          // 发送方头像（右侧）
          if (isSender) const SizedBox(width: 8),
          if (isSender) _buildAvatar(),
        ],
      ),
    );
  }

  /// 群聊中在对方气泡上方叠加发送者名称；其余情况原样返回气泡行。
  Widget _withSenderName(Widget bubbleRow) {
    final name = senderName.trim();
    if (isSender || !showSenderName || name.isEmpty) {
      return bubbleRow;
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          // 与气泡主体左缘对齐（表情包没有 6px 尖角）。
          padding: EdgeInsets.only(left: _isSticker ? 0 : 6, bottom: 3),
          child: Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, color: Color(0xFF7A7A7A)),
          ),
        ),
        bubbleRow,
      ],
    );
  }

  /// 是否是表情包消息
  bool get _isSticker => message.type == MessageType.sticker;

  /// 是否是图片消息
  bool get _isImage => message.type == MessageType.image;

  /// 是否是语音消息
  bool get _isVoice => message.type == MessageType.voice;

  bool get _isHiddenNoReply {
    if (isSender || !MessageParts.isNoReplyDirective(message.content)) {
      return false;
    }
    // 即使角色未开启「显示无回复气泡」，只要这条无回复消息携带了工具调用记录
    // 且角色开启了「显示工具调用历史」，也不能整条隐藏气泡——否则那次调用
    // （例如无回复续写 continue_if_no_reply）就永远没有入口可查看。
    // 无回复文本本身仍由 _buildBodyParts 按 showNoReply 单独控制是否显示。
    if (message.hasToolCalls && message.hasRequestId && _showToolCallsCard) {
      return false;
    }
    if (_showReasoningCard) return false;
    return !(RoleService.getRoleById(message.senderId)?.showNoReply ?? false);
  }

  /// 构建气泡内容
  Widget _buildBubbleContent(BuildContext context) {
    if (_isSticker) {
      return _buildStickerContent();
    }
    if (_isImage) {
      return _buildImageContent(context);
    }
    if (_isVoice) {
      return _buildVoiceContent(context);
    }
    return _buildTextContent(context);
  }

  /// 构建语音内容：点击播放，可展开「转文字」
  Widget _buildVoiceContent(BuildContext context) {
    final voice = VoiceMessage.fromMessage(message);
    final maxWidth = MediaQuery.of(context).size.width * 0.65;
    final color = isSender ? const Color(0xFF95EC69) : Colors.white;
    if (voice == null) {
      // 内容损坏时退化为占位文案，避免把 JSON 原文渲染到气泡里。
      return Container(
        constraints: BoxConstraints(maxWidth: maxWidth),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(4),
        ),
        child: _buildDialogue(VoiceMessage.previewLabel),
      );
    }
    return _VoiceBubble(
      key: ValueKey('voice-bubble-${message.id}'),
      messageId: message.id,
      voice: voice,
      isSender: isSender,
      maxWidth: maxWidth,
      color: color,
      headers: [
        // 引用块（如果有）
        if (message.hasQuote) ...[
          _buildQuoteBlock(),
          const SizedBox(height: 6),
        ],
        // 思考过程（角色开启「显示思维链」时展示，默认折叠）
        if (_showReasoningCard) ...[
          _ThinkingChainCard(reasoning: message.reasoningContent!),
          const SizedBox(height: 6),
        ],
      ],
      footers: [
        // 工具调用历史（角色开启「显示工具调用历史」且本条消息携带记录时展示）
        if (_showToolCallsCard) ...[
          const SizedBox(height: 6),
          _ToolCallsCard(
            roleId: message.senderId,
            requestId: message.requestId!,
          ),
        ],
      ],
    );
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
            cacheWidth: (200 * MediaQuery.of(context).devicePixelRatio).round(),
            errorBuilder: (_, _, _) => Container(
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
          // 思考过程（角色开启「显示思维链」时展示，默认折叠）
          if (_showReasoningCard) ...[
            _ThinkingChainCard(reasoning: message.reasoningContent!),
            const SizedBox(height: 6),
          ],
          // 正文按标签的原始顺序逐片段渲染。
          ..._buildBodyParts(),
          // 工具调用历史（角色开启「显示工具调用历史」且本条消息携带记录时展示）
          if (_showToolCallsCard) ...[
            const SizedBox(height: 6),
            _ToolCallsCard(
              roleId: message.senderId,
              requestId: message.requestId!,
            ),
          ],
        ],
      ),
    );
  }

  /// 是否显示工具调用历史卡片：仅 AI 消息、角色已开启该设置、且本条消息
  /// 确实发生过工具调用（明细按需向服务端查询，这里只判断入口是否展示）。
  bool get _showToolCallsCard {
    if (isSender || !message.hasToolCalls || !message.hasRequestId) {
      return false;
    }
    return RoleService.getRoleById(message.senderId)?.showToolCalls ?? false;
  }

  /// 是否显示思考过程卡片：仅 AI 消息、角色开启该设置、且本条消息有内容。
  bool get _showReasoningCard {
    if (isSender || !message.hasReasoning) return false;
    return RoleService.getRoleById(message.senderId)?.showReasoning ?? false;
  }

  /// 构建消息正文各片段（对话/动作/声音/心理/事实/数值）。
  List<Widget> _buildBodyParts() {
    final parts = MessageParts.parse(
      message.content,
      allowFact: isSender,
      allowNoReply: !isSender,
    );
    final role = isSender ? null : RoleService.getRoleById(message.senderId);
    final showAction = role?.showAction ?? true;
    final showSound = role?.showSound ?? true;
    final showPsychology = role?.showPsychology ?? true;
    final showStats = role?.showStats ?? true;
    final showNoReply = role?.showNoReply ?? false;
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
        case MessagePartType.sound:
          if (showSound) addPart(_buildSound(part.text));
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
          if (showNoReply) addPart(_buildNoReply(part.text));
          break;
      }
    }

    if (widgets.isEmpty && parts.parts.isEmpty && message.content.isNotEmpty) {
      widgets.add(_buildDialogue(message.content));
    }
    return widgets;
  }

  Widget _buildDialogue(String text) {
    const style = TextStyle(
      fontSize: 17,
      color: Color(0xFF000000),
      height: 1.4,
    );
    if (mentionNames.isEmpty || !text.contains('@')) {
      return Text(text, style: style);
    }
    final spans = GroupMentions.findSpans(text, {
      for (final name in mentionNames) name: [name],
    });
    if (spans.isEmpty) {
      return Text(text, style: style);
    }
    final children = <InlineSpan>[];
    var cursor = 0;
    for (final span in spans) {
      if (span.start > cursor) {
        children.add(TextSpan(text: text.substring(cursor, span.start)));
      }
      children.add(
        TextSpan(
          text: text.substring(span.start, span.end),
          style: const TextStyle(color: Color(0xFF576B95)),
        ),
      );
      cursor = span.end;
    }
    if (cursor < text.length) {
      children.add(TextSpan(text: text.substring(cursor)));
    }
    return Text.rich(TextSpan(style: style, children: children));
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

  Widget _buildSound(String text) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const Padding(
          padding: EdgeInsets.only(top: 2, right: 4),
          child: Icon(
            Icons.volume_up_outlined,
            size: 15,
            color: Color(0xFF5E8BA8),
          ),
        ),
        Flexible(
          child: Text(
            text,
            style: const TextStyle(
              fontSize: 14,
              fontStyle: FontStyle.italic,
              color: Color(0xFF4F7892),
              height: 1.3,
            ),
          ),
        ),
      ],
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
                errorBuilder: (_, _, _) => _buildStickerPlaceholder(emotion),
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
          errorBuilder: (_, _, _) => _buildStickerPlaceholder(emotion),
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
    return RemoteMediaImage(
      imageUrl,
      headers: SecureBackendClient.authHeaders,
      fit: BoxFit.contain,
      // 120px 显示上限 × 3 解码，限制内存位图大小。
      cacheWidth: 360,
      errorBuilder: (_, _, _) {
        final retryUrl = _buildBaseRetryUrl(imageUrl);
        if (retryUrl == null || retryUrl == imageUrl) {
          return _buildStickerPlaceholder(emotion);
        }

        return RemoteMediaImage(
          retryUrl,
          headers: SecureBackendClient.authHeaders,
          fit: BoxFit.contain,
          cacheWidth: 360,
          errorBuilder: (_, _, _) => _buildStickerPlaceholder(emotion),
        );
      },
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
  // ignore: unused_element
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

  /// 显示长按上下文菜单：复制 / 引用 / 提醒 / 收藏 / 多选 / 删除。
  void _showContextMenu(BuildContext context) {
    // 无任何交互回调时（如只读展示）不弹菜单。
    if (onLongPress == null &&
        onCopy == null &&
        onQuote == null &&
        onRemind == null &&
        onFavorite == null &&
        onMultiSelect == null &&
        onDelete == null) {
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
            if (onCopy != null)
              _buildMenuItem(
                context,
                icon: Icons.copy,
                color: const Color(0xFF333333),
                label: '复制',
                onTap: onCopy,
              ),
            if (onQuote != null)
              _buildMenuItem(
                context,
                icon: Icons.reply,
                color: const Color(0xFF2196F3),
                label: '引用',
                onTap: onQuote,
              ),
            if (onRemind != null)
              _buildMenuItem(
                context,
                icon: Icons.alarm,
                color: const Color(0xFFFF9800),
                label: '提醒',
                onTap: onRemind,
              ),
            if (onFavorite != null)
              _buildMenuItem(
                context,
                icon: Icons.star_border,
                color: const Color(0xFFFFB300),
                label: '收藏',
                onTap: onFavorite,
              ),
            if (onMultiSelect != null)
              _buildMenuItem(
                context,
                icon: Icons.checklist,
                color: const Color(0xFF07C160),
                label: '多选',
                onTap: onMultiSelect,
              ),
            if (onDelete != null)
              _buildMenuItem(
                context,
                icon: Icons.delete_outline,
                color: Colors.red,
                label: '删除',
                onTap: onDelete,
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _buildMenuItem(
    BuildContext context, {
    required IconData icon,
    required Color color,
    required String label,
    VoidCallback? onTap,
  }) {
    return ListTile(
      leading: Icon(icon, color: color),
      title: Text(label),
      onTap: () {
        Navigator.pop(context);
        onTap?.call();
      },
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
    _reconnectSubscription = SecureWebSocketClient.instance.onReconnectedStream
        .listen((_) {
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

  // ignore: unused_element
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

/// 思考过程卡片：默认折叠，展开后直接展示该条 AI 回复的推理文本。
class _ThinkingChainCard extends StatefulWidget {
  final String reasoning;

  const _ThinkingChainCard({required this.reasoning});

  @override
  State<_ThinkingChainCard> createState() => _ThinkingChainCardState();
}

class _ThinkingChainCardState extends State<_ThinkingChainCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: const Color(0xFFF4F1FA),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0xFFE4DDF2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.psychology_outlined,
                    size: 14,
                    color: Color(0xFF6A5A8C),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    _expanded ? '收起思考过程' : '思考过程',
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF6A5A8C),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 16,
                    color: const Color(0xFF6A5A8C),
                  ),
                ],
              ),
            ),
          ),
          if (_expanded)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 240),
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                child: Text(
                  widget.reasoning,
                  style: const TextStyle(
                    fontSize: 12,
                    height: 1.45,
                    color: Color(0xFF555555),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 工具调用历史卡片：默认折叠，仅显示入口。点击展开时才向服务端按需查询
/// 该次回复的工具调用明细（首次查询后本地缓存，见 [ToolCallService]）。
class _ToolCallsCard extends StatefulWidget {
  final String roleId;
  final String requestId;

  const _ToolCallsCard({required this.roleId, required this.requestId});

  @override
  State<_ToolCallsCard> createState() => _ToolCallsCardState();
}

class _ToolCallsCardState extends State<_ToolCallsCard> {
  bool _expanded = false;
  bool _loading = false;
  List<Map<String, dynamic>>? _toolCalls;
  String? _error;

  Future<void> _toggleExpanded() async {
    setState(() => _expanded = !_expanded);
    if (!_expanded || _toolCalls != null || _loading) return;

    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final calls = await ToolCallService.getToolCalls(
        roleId: widget.roleId,
        requestId: widget.requestId,
      );
      if (!mounted) return;
      setState(() {
        _toolCalls = calls;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '加载失败';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: const Color(0xFFF0F2F5),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0xFFE0E3E8)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: _toggleExpanded,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.build_outlined,
                    size: 14,
                    color: Color(0xFF666666),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    _headerText,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF666666),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 16,
                    color: const Color(0xFF666666),
                  ),
                ],
              ),
            ),
          ),
          if (_expanded) _buildExpandedBody(),
        ],
      ),
    );
  }

  String get _headerText {
    if (_loading) return '正在加载工具调用记录…';
    if (_error != null) return _error!;
    final calls = _toolCalls;
    if (calls == null) return '查看工具调用记录';
    return '调用了 ${calls.length} 个工具';
  }

  Widget _buildExpandedBody() {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.fromLTRB(8, 0, 8, 8),
        child: SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    final calls = _toolCalls ?? const <Map<String, dynamic>>[];
    if (calls.isEmpty) {
      return const Padding(
        padding: EdgeInsets.fromLTRB(8, 0, 8, 8),
        child: Text(
          '没有可显示的调用记录',
          style: TextStyle(fontSize: 12, color: Color(0xFF888888)),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [for (final call in calls) _buildCallEntry(call)],
      ),
    );
  }

  Widget _buildCallEntry(Map<String, dynamic> call) {
    final name = call['name']?.toString() ?? '';
    final rawArguments = call['arguments'];
    final argumentsText = (rawArguments is Map && rawArguments.isNotEmpty)
        ? rawArguments.entries.map((e) => '${e.key}=${e.value}').join(', ')
        : '';
    final result = call['result']?.toString() ?? '';

    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            name,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Color(0xFF333333),
            ),
          ),
          if (argumentsText.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                argumentsText,
                style: const TextStyle(fontSize: 12, color: Color(0xFF888888)),
              ),
            ),
          if (result.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                result,
                style: const TextStyle(fontSize: 12, color: Color(0xFF4F7892)),
              ),
            ),
        ],
      ),
    );
  }
}

/// 语音气泡：点击播放/停止，可展开「转文字」查看所说内容。
///
/// 播放状态由全局 [VoicePlaybackService] 维护（同一时间只播放一条）。
class _VoiceBubble extends StatefulWidget {
  final String messageId;
  final VoiceMessage voice;
  final bool isSender;
  final double maxWidth;
  final Color color;

  /// 气泡内语音条之前 / 之后的附加内容（引用块、思考过程、工具调用等）。
  final List<Widget> headers;
  final List<Widget> footers;

  const _VoiceBubble({
    super.key,
    required this.messageId,
    required this.voice,
    required this.isSender,
    required this.maxWidth,
    required this.color,
    this.headers = const [],
    this.footers = const [],
  });

  @override
  State<_VoiceBubble> createState() => _VoiceBubbleState();
}

class _VoiceBubbleState extends State<_VoiceBubble> {
  bool _showText = false;

  Future<void> _onTap() async {
    final ok = await VoicePlaybackService.instance.toggle(
      messageId: widget.messageId,
      reference: widget.voice.ref,
    );
    if (!ok && mounted) {
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(const SnackBar(content: Text('语音加载失败，请稍后重试')));
    }
  }

  Widget _buildIcon(VoicePlaybackStatus status) {
    switch (status) {
      case VoicePlaybackStatus.loading:
        return const SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        );
      case VoicePlaybackStatus.playing:
        return const Icon(Icons.graphic_eq, size: 22, color: Color(0xFF07C160));
      case VoicePlaybackStatus.idle:
        return const Icon(Icons.volume_up_rounded, size: 22);
    }
  }

  @override
  Widget build(BuildContext context) {
    final voice = widget.voice;
    final hasText = voice.text.trim().isNotEmpty;
    // 语音条宽度随时长增长，限制在气泡可用宽度内。
    final seconds = ((voice.durationMs ?? 0) / 1000)
        .ceil()
        .clamp(0, 60)
        .toInt();
    final maxBar = widget.maxWidth - 20 < 72.0 ? 72.0 : widget.maxWidth - 20;
    final barWidth = (72.0 + seconds * 3).clamp(72.0, maxBar).toDouble();

    return ListenableBuilder(
      listenable: VoicePlaybackService.instance,
      builder: (context, _) {
        final status = VoicePlaybackService.instance.statusOf(widget.messageId);
        final label = voice.durationLabel;
        final children = <Widget>[
          _buildIcon(status),
          if (label.isNotEmpty) ...[
            const SizedBox(width: 8),
            Text(
              label,
              style: const TextStyle(fontSize: 15, color: Color(0xFF000000)),
            ),
          ],
        ];
        return Container(
          constraints: BoxConstraints(maxWidth: widget.maxWidth),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          decoration: BoxDecoration(
            color: widget.color,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              ...widget.headers,
              Semantics(
                button: true,
                label: label.isEmpty ? '语音消息' : '语音消息 $label',
                child: GestureDetector(
                  key: const ValueKey('voice-play'),
                  behavior: HitTestBehavior.opaque,
                  onTap: _onTap,
                  child: SizedBox(
                    width: barWidth,
                    height: 28,
                    child: Row(
                      mainAxisAlignment: widget.isSender
                          ? MainAxisAlignment.end
                          : MainAxisAlignment.start,
                      children: widget.isSender
                          ? children.reversed.toList()
                          : children,
                    ),
                  ),
                ),
              ),
              if (hasText) ...[
                const SizedBox(height: 4),
                GestureDetector(
                  key: const ValueKey('voice-toggle-text'),
                  behavior: HitTestBehavior.opaque,
                  onTap: () => setState(() => _showText = !_showText),
                  child: Text(
                    _showText ? '收起文字' : '转文字',
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF576B95),
                    ),
                  ),
                ),
              ],
              if (hasText && _showText) ...[
                const SizedBox(height: 6),
                Text(
                  voice.text,
                  style: const TextStyle(
                    fontSize: 15,
                    color: Color(0xFF000000),
                    height: 1.4,
                  ),
                ),
              ],
              ...widget.footers,
            ],
          ),
        );
      },
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
