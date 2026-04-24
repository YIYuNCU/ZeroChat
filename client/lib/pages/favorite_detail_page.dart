import 'package:flutter/material.dart';
import '../models/favorite_collection.dart';
import '../services/favorite_service.dart';

/// 收藏详情页面
/// 只读聊天视图，支持标签管理
class FavoriteDetailPage extends StatefulWidget {
  final String collectionId;

  const FavoriteDetailPage({super.key, required this.collectionId});

  @override
  State<FavoriteDetailPage> createState() => _FavoriteDetailPageState();
}

class _FavoriteDetailPageState extends State<FavoriteDetailPage> {
  FavoriteCollection? _collection;

  @override
  void initState() {
    super.initState();
    _loadCollection();
    FavoriteService.instance.addListener(_onFavoritesChanged);
  }

  @override
  void dispose() {
    FavoriteService.instance.removeListener(_onFavoritesChanged);
    super.dispose();
  }

  void _onFavoritesChanged() {
    _loadCollection();
  }

  void _loadCollection() {
    setState(() {
      _collection = FavoriteService.instance.getCollection(widget.collectionId);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_collection == null) {
      return Scaffold(
        appBar: AppBar(
          backgroundColor: const Color(0xFFEDEDED),
          foregroundColor: const Color(0xFF000000),
          elevation: 0,
          title: const Text('收藏详情'),
        ),
        body: const Center(child: Text('收藏不存在')),
      );
    }

    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFFEDEDED),
        foregroundColor: const Color(0xFF000000),
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        title: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _collection!.roleName,
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w500),
            ),
            Text(
              '${_collection!.messages.length} 条消息',
              style: const TextStyle(fontSize: 12, color: Color(0xFF888888)),
            ),
          ],
        ),
        leading: IconButton(
          onPressed: () => Navigator.pop(context),
          icon: const Icon(Icons.arrow_back_ios, size: 20),
        ),
        actions: [
          IconButton(
            onPressed: _showOptions,
            icon: const Icon(Icons.more_horiz, size: 24),
          ),
        ],
      ),
      body: Container(
        color: const Color(0xFFEDEDED),
        child: Column(
          children: [
            // 标签栏
            if (_collection!.tags.isNotEmpty) _buildTagBar(),
            // 消息列表
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(vertical: 10),
                itemCount: _collection!.messages.length,
                itemBuilder: (context, index) {
                  final message = _collection!.messages[index];
                  final showTime = _shouldShowTime(index);

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
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 构建标签栏
  Widget _buildTagBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      color: Colors.white,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            const Icon(Icons.label_outline, size: 16, color: Color(0xFF888888)),
            const SizedBox(width: 8),
            ..._collection!.tags.map(
              (tag) => Container(
                margin: const EdgeInsets.only(right: 8),
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFF07C160).withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  tag,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF07C160),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  bool _shouldShowTime(int index) {
    if (index == 0) return true;
    final current = _collection!.messages[index];
    final previous = _collection!.messages[index - 1];
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

  /// 构建消息气泡（只读版本）
  Widget _buildMessageBubble(MessageSnapshot message) {
    final isSender = message.isFromUser;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Row(
        mainAxisAlignment: isSender
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 接收方头像
          if (!isSender) _buildAvatar(message.senderName),
          if (!isSender) const SizedBox(width: 8),

          // 气泡
          Flexible(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!isSender) _buildBubbleArrow(isLeft: true),
                Flexible(
                  child: Container(
                    constraints: BoxConstraints(
                      maxWidth: MediaQuery.of(context).size.width * 0.65,
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: isSender ? const Color(0xFF95EC69) : Colors.white,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // 引用块
                        if (message.quotedContent != null) ...[
                          Container(
                            padding: const EdgeInsets.all(6),
                            decoration: BoxDecoration(
                              color: isSender
                                  ? const Color(
                                      0xFF7BC857,
                                    ).withValues(alpha: 0.5)
                                  : const Color(0xFFEEEEEE),
                              borderRadius: BorderRadius.circular(2),
                              border: Border(
                                left: BorderSide(
                                  color: isSender
                                      ? const Color(0xFF5BA93D)
                                      : const Color(0xFFCCCCCC),
                                  width: 2,
                                ),
                              ),
                            ),
                            child: Text(
                              message.quotedContent!,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                color: isSender
                                    ? const Color(0xFF2E5A1E)
                                    : const Color(0xFF888888),
                              ),
                            ),
                          ),
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
                  ),
                ),
                if (isSender) _buildBubbleArrow(isLeft: false),
              ],
            ),
          ),

          // 发送方头像
          if (isSender) const SizedBox(width: 8),
          if (isSender) _buildAvatar(_collection!.userName),
        ],
      ),
    );
  }

  Widget _buildAvatar(String name) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: Container(
        width: 40,
        height: 40,
        color: const Color(0xFFE7C77E),
        child: Center(
          child: Text(
            name.isNotEmpty ? name.substring(0, 1) : '?',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBubbleArrow({required bool isLeft}) {
    return CustomPaint(
      size: const Size(6, 12),
      painter: _BubbleArrowPainter(
        color: isLeft ? Colors.white : const Color(0xFF95EC69),
        isLeft: isLeft,
      ),
    );
  }

  void _showOptions() {
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
            ListTile(
              leading: const Icon(
                Icons.label_outline,
                color: Color(0xFF07C160),
              ),
              title: const Text('添加标签'),
              onTap: () {
                Navigator.pop(context);
                _showAddTagDialog();
              },
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.red),
              title: const Text('删除收藏'),
              onTap: () {
                Navigator.pop(context);
                _showDeleteConfirm();
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _showAddTagDialog() {
    final controller = TextEditingController();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('添加标签'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '输入标签名',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              final tag = controller.text.trim();
              if (tag.isNotEmpty) {
                FavoriteService.instance.addTag(widget.collectionId, tag);
              }
              Navigator.pop(context);
            },
            child: const Text('添加'),
          ),
        ],
      ),
    );
  }

  void _showDeleteConfirm() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除收藏'),
        content: const Text('确定要删除这个收藏合集吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              FavoriteService.instance.deleteCollection(widget.collectionId);
              Navigator.pop(context);
              Navigator.pop(context);
            },
            child: const Text('删除', style: TextStyle(color: Colors.red)),
          ),
        ],
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
