import 'package:flutter/material.dart';
import '../widgets/chat_bubble.dart';
import '../widgets/input_bar.dart';
import '../models/message.dart';

/// ZeroChat 风格聊天页面
/// 包含消息列表和底部输入栏
class ChatPage extends StatefulWidget {
  const ChatPage({super.key});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final List<Message> _messages = [];
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _addInitialMessages();
  }

  /// 添加初始示例消息
  void _addInitialMessages() {
    final now = DateTime.now();
    _messages.addAll([
      Message(
        id: '1',
        senderId: 'ai',
        receiverId: 'me',
        content: '你好！我是 AI 助手，有什么可以帮助你的吗？',
        timestamp: now.subtract(const Duration(minutes: 10)),
      ),
      Message(
        id: '2',
        senderId: 'me',
        receiverId: 'ai',
        content: '你好，请介绍一下你自己',
        timestamp: now.subtract(const Duration(minutes: 9)),
      ),
      Message(
        id: '3',
        senderId: 'ai',
        receiverId: 'me',
        content: '我是一个智能对话助手，可以回答问题、进行对话、提供建议等。我会尽力帮助你解决各种问题！',
        timestamp: now.subtract(const Duration(minutes: 8)),
      ),
    ]);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  /// 发送消息
  void _sendMessage(String text) {
    if (text.trim().isEmpty) return;

    setState(() {
      _messages.add(
        Message(
          id: DateTime.now().millisecondsSinceEpoch.toString(),
          senderId: 'me',
          receiverId: 'ai',
          content: text,
          timestamp: DateTime.now(),
        ),
      );
    });

    _scrollToBottom();
    _simulateAIReply(text);
  }

  /// 模拟 AI 回复
  void _simulateAIReply(String userMessage) {
    Future.delayed(const Duration(seconds: 1), () {
      if (mounted) {
        setState(() {
          _messages.add(
            Message(
              id: DateTime.now().millisecondsSinceEpoch.toString(),
              senderId: 'ai',
              receiverId: 'me',
              content: '收到你的消息："$userMessage"。这是一条模拟回复。',
              timestamp: DateTime.now(),
            ),
          );
        });
        _scrollToBottom();
      }
    });
  }

  /// 滚动到消息列表底部
  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  /// 判断是否需要显示时间分隔
  bool _shouldShowTime(int index) {
    if (index == 0) return true;
    final current = _messages[index].timestamp;
    final previous = _messages[index - 1].timestamp;
    return current.difference(previous).inMinutes >= 5;
  }

  /// 格式化时间
  String _formatTime(DateTime time) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final messageDate = DateTime(time.year, time.month, time.day);

    String timeStr =
        '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';

    if (messageDate == today) {
      return timeStr;
    } else if (messageDate == today.subtract(const Duration(days: 1))) {
      return '昨天 $timeStr';
    } else if (time.year == now.year) {
      return '${time.month}月${time.day}日 $timeStr';
    } else {
      return '${time.year}年${time.month}月${time.day}日 $timeStr';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFFEDEDED),
      child: Column(
        children: [
          // 消息列表
          Expanded(
            child: _messages.isEmpty
                ? const Center(
                    child: Text(
                      '暂无消息',
                      style: TextStyle(color: Color(0xFFBBBBBB), fontSize: 14),
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    itemCount: _messages.length,
                    itemBuilder: (context, index) {
                      final message = _messages[index];
                      final isSender = message.senderId == 'me';
                      final showTime = _shouldShowTime(index);

                      return Column(
                        children: [
                          // 时间分隔
                          if (showTime)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 10),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFCDCDCD),
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
                          // 消息气泡
                          ChatBubble(message: message, isSender: isSender),
                        ],
                      );
                    },
                  ),
          ),
          // 底部输入栏
          InputBar(onSend: _sendMessage),
        ],
      ),
    );
  }
}
