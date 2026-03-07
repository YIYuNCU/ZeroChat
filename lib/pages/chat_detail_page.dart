import 'dart:io';
import 'package:flutter/material.dart';
import '../models/message.dart';
import '../models/emoji_item.dart';
import '../models/role.dart';
import '../widgets/chat_bubble.dart';
import '../widgets/input_bar.dart';
import '../core/chat_controller.dart';
import '../core/message_store.dart';
import '../services/role_service.dart';
import '../services/favorite_service.dart';
import '../services/settings_service.dart';
import 'chat_settings_page.dart';
import 'group_settings_page.dart';

/// 引用状态
class QuoteState {
  final String messageId;
  final String content;
  final String senderName;

  const QuoteState({
    required this.messageId,
    required this.content,
    required this.senderName,
  });
}

/// 聊天详情页面
/// 使用 ChatController 架构，支持多选收藏
class ChatDetailPage extends StatefulWidget {
  final String chatId;
  final String chatName;
  final bool isAI;
  final bool isGroup;
  final List<String>? memberIds;

  const ChatDetailPage({
    super.key,
    required this.chatId,
    required this.chatName,
    this.isAI = true,
    this.isGroup = false,
    this.memberIds,
  });

  @override
  State<ChatDetailPage> createState() => _ChatDetailPageState();
}

class _ChatDetailPageState extends State<ChatDetailPage> {
  final ScrollController _scrollController = ScrollController();
  final InputBarController _inputBarController = InputBarController();
  static const int _messagePageSize = 50;

  int _visibleMessageCount = _messagePageSize;
  int _lastTotalMessageCount = 0;
  bool _isLoadingMoreMessages = false;
  bool _isUserNearBottom = true;
  bool _loadMoreConfirmNeeded = false;
  DateTime? _lastLoadMoreConfirmTime;
  bool _showTyping = false;
  late Role _currentRole;

  /// 当前引用状态
  QuoteState? _quoteState;

  /// 多选模式
  bool _isMultiSelectMode = false;
  final Set<String> _selectedMessageIds = {};

  @override
  void initState() {
    super.initState();

    _scrollController.addListener(_onScroll);

    _currentRole =
        RoleService.getRoleById(widget.chatId) ?? RoleService.getCurrentRole();

    ChatController.instance.registerTypingCallback(
      widget.chatId,
      _onTypingChanged,
    );

    // 监听设置更新（包括背景图）
    SettingsService.instance.addListener(_onSettingsChanged);

    _initializeChat();
  }

  Future<void> _initializeChat() async {
    await ChatController.instance.initChat(
      widget.chatId,
      isGroup: widget.isGroup,
      memberIds: widget.memberIds,
    );

    await ChatController.instance.onChatPageEnter(widget.chatId);

    if (mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToBottom(animate: false);
      });
    }
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    SettingsService.instance.removeListener(_onSettingsChanged);
    ChatController.instance.unregisterTypingCallback(widget.chatId);
    ChatController.instance.onChatPageExit(widget.chatId);
    _inputBarController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _dismissInputControls() {
    FocusScope.of(context).unfocus();
    _inputBarController.closeControls();
  }

  void _onSettingsChanged() {
    // 设置更新时刷新背景图
    if (mounted) setState(() {});
  }

  void _onTypingChanged(bool isTyping) {
    if (mounted) {
      setState(() => _showTyping = isTyping);
    }
  }

  /// 发送消息（支持引用）
  void _sendMessage(String text) {
    if (text.trim().isEmpty) return;
    if (ChatController.instance.isProcessing(widget.chatId)) return;

    if (_quoteState != null) {
      ChatController.instance.sendUserMessageWithQuote(
        widget.chatId,
        text,
        _quoteState!.messageId,
        _quoteState!.content,
      );
      setState(() => _quoteState = null);
    } else {
      ChatController.instance.sendUserMessage(widget.chatId, text);
    }

    _scrollToBottom();
  }

  /// 发送图片消息
  void _sendImageMessage(String imagePath) {
    if (ChatController.instance.isProcessing(widget.chatId)) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('正在处理消息，请稍后')));
      return;
    }

    // 发送图片消息
    ChatController.instance.sendUserImageMessage(widget.chatId, imagePath);

    _scrollToBottom();
  }

  void _sendEmojiMessage(EmojiItem emoji) {
    if (ChatController.instance.isProcessing(widget.chatId)) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('正在处理消息，请稍后')));
      return;
    }

    if (emoji.isAi) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('AI表情仅支持查看，不可发送')));
      return;
    }

    ChatController.instance.sendUserStickerMessage(
      chatId: widget.chatId,
      stickerUrl: emoji.url,
      category: emoji.category,
      tag: emoji.tag ?? emoji.category,
      emojiId: emoji.id,
      fromUserLibrary: !emoji.isAi,
    );

    _scrollToBottom();
  }

  /// 设置引用状态
  void _setQuote(Message message) {
    final senderName = message.senderId == 'me'
        ? '我'
        : (RoleService.getRoleById(message.senderId)?.name ?? widget.chatName);

    setState(() {
      _quoteState = QuoteState(
        messageId: message.id,
        content: message.content.length > 50
            ? '${message.content.substring(0, 50)}...'
            : message.content,
        senderName: senderName,
      );
    });
  }

  /// 清除引用状态
  void _clearQuote() {
    setState(() => _quoteState = null);
  }

  // ========== 多选模式 ==========

  /// 进入多选模式
  void _enterMultiSelectMode(Message initialMessage) {
    setState(() {
      _isMultiSelectMode = true;
      _selectedMessageIds.clear();
      _selectedMessageIds.add(initialMessage.id);
    });
  }

  /// 退出多选模式
  void _exitMultiSelectMode() {
    setState(() {
      _isMultiSelectMode = false;
      _selectedMessageIds.clear();
    });
  }

  /// 切换消息选中状态
  void _toggleMessageSelection(Message message) {
    setState(() {
      if (_selectedMessageIds.contains(message.id)) {
        _selectedMessageIds.remove(message.id);
      } else {
        _selectedMessageIds.add(message.id);
      }
    });
  }

  /// 收藏选中的消息
  Future<void> _favoriteSelectedMessages() async {
    if (_selectedMessageIds.isEmpty) return;

    final messages = MessageStore.instance.getMessages(widget.chatId);
    final selectedMessages = messages
        .where((m) => _selectedMessageIds.contains(m.id))
        .toList();

    if (selectedMessages.isEmpty) return;

    await FavoriteService.instance.createCollection(
      chatId: widget.chatId,
      chatName: widget.chatName,
      userName: '我',
      roleName: _currentRole.name,
      messages: selectedMessages,
      getSenderName: (senderId) {
        final role = RoleService.getRoleById(senderId);
        return role?.name ?? widget.chatName;
      },
    );

    _exitMultiSelectMode();
  }

  /// 删除消息
  void _deleteMessage(Message message) async {
    await MessageStore.instance.deleteMessage(widget.chatId, message.id);
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;

    final position = _scrollController.position;
    final distanceToBottom = position.maxScrollExtent - position.pixels;
    _isUserNearBottom = distanceToBottom < 120;

    if (position.pixels > 120 && _loadMoreConfirmNeeded) {
      setState(() {
        _loadMoreConfirmNeeded = false;
        _lastLoadMoreConfirmTime = null;
      });
    }

    if (position.pixels <= 60) {
      if (!_loadMoreConfirmNeeded) {
        setState(() {
          _loadMoreConfirmNeeded = true;
          _lastLoadMoreConfirmTime = DateTime.now();
        });
        return;
      }

      final confirmAt = _lastLoadMoreConfirmTime;
      if (confirmAt != null &&
          DateTime.now().difference(confirmAt) <
              const Duration(milliseconds: 350)) {
        return;
      }

      _loadMoreMessages();
    }
  }

  void _loadMoreMessages() {
    if (_isLoadingMoreMessages || !_scrollController.hasClients) return;

    final totalMessageCount = MessageStore.instance.getMessageCount(
      widget.chatId,
    );
    if (_visibleMessageCount >= totalMessageCount) return;

    final oldMaxScrollExtent = _scrollController.position.maxScrollExtent;
    final oldPixels = _scrollController.position.pixels;

    setState(() {
      _isLoadingMoreMessages = true;
      _loadMoreConfirmNeeded = false;
      _lastLoadMoreConfirmTime = null;
      _visibleMessageCount += _messagePageSize;
      if (_visibleMessageCount > totalMessageCount) {
        _visibleMessageCount = totalMessageCount;
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        final newMaxScrollExtent = _scrollController.position.maxScrollExtent;
        final delta = newMaxScrollExtent - oldMaxScrollExtent;
        _scrollController.jumpTo(oldPixels + delta);
      }
      if (mounted) {
        setState(() => _isLoadingMoreMessages = false);
      }
    });
  }

  void _handleAutoScroll(int totalMessagesCount) {
    final hasNewMessages = totalMessagesCount > _lastTotalMessageCount;
    _lastTotalMessageCount = totalMessagesCount;

    if (!hasNewMessages || _isMultiSelectMode || !_isUserNearBottom) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _scrollToBottom();
      }
    });
  }

  void _scrollToBottom({bool animate = true}) {
    if (_scrollController.hasClients) {
      final position = _scrollController.position.maxScrollExtent;
      if (animate) {
        _scrollController.animateTo(
          position,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      } else {
        _scrollController.jumpTo(position);
      }
    }
  }

  bool _shouldShowTime(List<Message> messages, int index) {
    if (index == 0) return true;
    final current = messages[index];
    final previous = messages[index - 1];
    return current.timestamp.difference(previous.timestamp).inMinutes > 5;
  }

  String _formatTime(DateTime time) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final messageDay = DateTime(time.year, time.month, time.day);

    if (messageDay == today) {
      return '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
    } else if (messageDay == today.subtract(const Duration(days: 1))) {
      return '昨天 ${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
    } else {
      return '${time.month}/${time.day} ${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
    }
  }

  void _openSettings() {
    if (widget.isGroup) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => GroupSettingsPage(groupId: widget.chatId),
        ),
      );
    } else {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => ChatSettingsPage(
            chatId: widget.chatId,
            chatName: widget.chatName,
            currentRole: _currentRole,
            onRoleChanged: () {
              setState(() {
                _currentRole =
                    RoleService.getRoleById(widget.chatId) ??
                    RoleService.getCurrentRole();
              });
            },
            onClearHistory: () {
              MessageStore.instance.clearMessages(widget.chatId);
            },
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final globalBackgroundUrl = SettingsService.instance.chatBackgroundUrl;
    final backgroundUrl = _currentRole.chatBackgroundUrl.isNotEmpty
        ? _currentRole.chatBackgroundUrl
        : globalBackgroundUrl;
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Scaffold(
      resizeToAvoidBottomInset: false,
      appBar: _buildAppBar(),
      body: Container(
        decoration: BoxDecoration(
          color: const Color(0xFFEDEDED),
          image: backgroundUrl.isNotEmpty
              ? DecorationImage(
                  image: backgroundUrl.startsWith('http')
                      ? NetworkImage(backgroundUrl) as ImageProvider
                      : FileImage(File(backgroundUrl)),
                  fit: BoxFit.cover,
                )
              : null,
        ),
        child: Column(
          children: [
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: _dismissInputControls,
                child: StreamBuilder<List<Message>>(
                  stream: MessageStore.instance.watchMessages(widget.chatId),
                  builder: (context, snapshot) {
                    final messages = snapshot.data ?? [];
                    final totalMessagesCount = messages.length;
                    final currentVisibleCount =
                        totalMessagesCount < _visibleMessageCount
                        ? totalMessagesCount
                        : _visibleMessageCount;
                    final visibleStart = totalMessagesCount - currentVisibleCount;
                    final visibleMessages = messages.sublist(visibleStart);
                    final hasMoreMessages = totalMessagesCount > currentVisibleCount;
                    final remainingMessageCount =
                        totalMessagesCount - currentVisibleCount;

                    if (!hasMoreMessages && _loadMoreConfirmNeeded) {
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (mounted) {
                          setState(() {
                            _loadMoreConfirmNeeded = false;
                            _lastLoadMoreConfirmTime = null;
                          });
                        }
                      });
                    }

                    if (visibleMessages.isEmpty) {
                      return const Center(
                        child: Text(
                          '暂无消息',
                          style: TextStyle(
                            color: Color(0xFFBBBBBB),
                            fontSize: 14,
                          ),
                        ),
                      );
                    }

                    _handleAutoScroll(totalMessagesCount);

                    return ListView.builder(
                      controller: _scrollController,
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      itemCount:
                          visibleMessages.length + (hasMoreMessages ? 1 : 0),
                      itemBuilder: (context, index) {
                        if (hasMoreMessages && index == 0) {
                          return Padding(
                            padding: const EdgeInsets.only(top: 6, bottom: 10),
                            child: Center(
                              child: Text(
                                _isLoadingMoreMessages
                                    ? '正在加载更多消息...'
                                    : _loadMoreConfirmNeeded
                                    ? '继续上划，加载更早的 $remainingMessageCount 条消息'
                                    : '上划查看更早消息（$remainingMessageCount 条）',
                                style: const TextStyle(
                                  color: Color(0xFF999999),
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          );
                        }

                        final adjustedIndex = hasMoreMessages ? index - 1 : index;
                        final message = visibleMessages[adjustedIndex];
                        final showTime = _shouldShowTime(
                          visibleMessages,
                          adjustedIndex,
                        );

                        return Column(
                          children: [
                            if (showTime)
                              Padding(
                                padding: const EdgeInsets.symmetric(vertical: 10),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 4,
                                  ),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFCECECE),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    _formatTime(message.timestamp),
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: Colors.white,
                                    ),
                                  ),
                                ),
                              ),
                            _buildMessageBubble(message),
                          ],
                        );
                      },
                    );
                  },
                ),
              ),
            ),
            if (_quoteState != null && !_isMultiSelectMode) _buildQuotePreview(),
            if (_isMultiSelectMode)
              _buildMultiSelectToolbar()
            else
              AnimatedPadding(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOut,
                padding: EdgeInsets.only(bottom: bottomInset),
                child: InputBar(
                  controller: _inputBarController,
                  onSend: _sendMessage,
                  onImageSend: _sendImageMessage,
                  onEmojiSend: _sendEmojiMessage,
                  roleId: widget.isGroup
                      ? RoleService.getCurrentRole().id
                      : widget.chatId,
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 构建 AppBar（支持多选模式）
  PreferredSizeWidget _buildAppBar() {
    if (_isMultiSelectMode) {
      return AppBar(
        backgroundColor: const Color(0xFFEDEDED),
        foregroundColor: const Color(0xFF000000),
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: IconButton(
          onPressed: _exitMultiSelectMode,
          icon: const Icon(Icons.close, size: 24),
        ),
        title: Text(
          '已选择 ${_selectedMessageIds.length} 条',
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w500),
        ),
      );
    }

    return AppBar(
      backgroundColor: const Color(0xFFEDEDED),
      foregroundColor: const Color(0xFF000000),
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: true,
      title: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            widget.chatName,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w500),
          ),
          if (_showTyping && !widget.isGroup)
            const Text(
              '对方正在输入...',
              style: TextStyle(fontSize: 12, color: Color(0xFF888888)),
            ),
        ],
      ),
      leading: IconButton(
        onPressed: () => Navigator.pop(context),
        icon: const Icon(Icons.arrow_back_ios, size: 20),
      ),
      actions: [
        IconButton(
          onPressed: _openSettings,
          icon: const Icon(Icons.more_horiz, size: 24),
        ),
      ],
    );
  }

  /// 构建多选工具栏
  Widget _buildMultiSelectToolbar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: Color(0xFFE0E0E0), width: 0.5)),
      ),
      child: SafeArea(
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _buildToolbarButton(
              icon: Icons.star_border,
              label: '收藏',
              onTap: _selectedMessageIds.isEmpty
                  ? null
                  : _favoriteSelectedMessages,
            ),
            _buildToolbarButton(
              icon: Icons.delete_outline,
              label: '删除',
              onTap: _selectedMessageIds.isEmpty
                  ? null
                  : _deleteSelectedMessages,
              color: Colors.red,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildToolbarButton({
    required IconData icon,
    required String label,
    VoidCallback? onTap,
    Color? color,
  }) {
    final isEnabled = onTap != null;
    final finalColor = isEnabled
        ? (color ?? const Color(0xFF333333))
        : const Color(0xFFCCCCCC);

    return InkWell(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 24, color: finalColor),
          const SizedBox(height: 4),
          Text(label, style: TextStyle(fontSize: 12, color: finalColor)),
        ],
      ),
    );
  }

  /// 删除选中的消息
  Future<void> _deleteSelectedMessages() async {
    for (final id in _selectedMessageIds) {
      await MessageStore.instance.deleteMessage(widget.chatId, id);
    }
    _exitMultiSelectMode();
  }

  /// 构建引用预览
  Widget _buildQuotePreview() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: const BoxDecoration(
        color: Color(0xFFF5F5F5),
        border: Border(top: BorderSide(color: Color(0xFFE0E0E0), width: 0.5)),
      ),
      child: Row(
        children: [
          Container(width: 3, height: 32, color: const Color(0xFF07C160)),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '引用 ${_quoteState!.senderName}',
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF07C160),
                    fontWeight: FontWeight.w500,
                  ),
                ),
                Text(
                  _quoteState!.content,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    color: Color(0xFF888888),
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: _clearQuote,
            icon: const Icon(Icons.close, size: 18, color: Color(0xFF888888)),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
          ),
        ],
      ),
    );
  }

  Widget _buildMessageBubble(Message message) {
    // 错误消息
    if (message.senderId == 'error') {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFFFFEEEE),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: const Color(0xFFFFCCCC)),
            ),
            child: Text(
              message.content,
              style: const TextStyle(color: Color(0xFFFF4444), fontSize: 13),
            ),
          ),
        ),
      );
    }

    // 系统消息
    if (message.senderId == 'system') {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFFE8F5E9),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              message.content,
              style: const TextStyle(color: Color(0xFF4CAF50), fontSize: 13),
            ),
          ),
        ),
      );
    }

    // 普通消息
    final isMe = message.senderId == 'me';
    final role = isMe ? null : RoleService.getRoleById(message.senderId);
    final senderName = isMe ? '我' : (role?.name ?? widget.chatName);
    final isSelected = _selectedMessageIds.contains(message.id);

    // 多选模式
    if (_isMultiSelectMode) {
      return GestureDetector(
        onTap: () => _toggleMessageSelection(message),
        child: Container(
          color: isSelected
              ? const Color(0xFF07C160).withValues(alpha: 0.1)
              : Colors.transparent,
          child: Row(
            children: [
              Padding(
                padding: const EdgeInsets.only(left: 12),
                child: Icon(
                  isSelected
                      ? Icons.check_circle
                      : Icons.radio_button_unchecked,
                  color: isSelected
                      ? const Color(0xFF07C160)
                      : const Color(0xFFCCCCCC),
                  size: 22,
                ),
              ),
              Expanded(
                child: ChatBubble(
                  message: message,
                  isSender: isMe,
                  avatarUrl: isMe ? null : role?.avatarUrl,
                  avatarHash: isMe ? null : role?.avatarHash,
                  senderName: senderName,
                ),
              ),
            ],
          ),
        ),
      );
    }

    // 普通模式
    return ChatBubble(
      message: message,
      isSender: isMe,
      avatarUrl: isMe ? null : role?.avatarUrl,
      avatarHash: isMe ? null : role?.avatarHash,
      senderName: senderName,
      onLongPress: () => _enterMultiSelectMode(message),
      onQuote: () => _setQuote(message),
      onDelete: () => _deleteMessage(message),
    );
  }
}
