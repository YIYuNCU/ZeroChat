import 'package:flutter/material.dart';

/// 表情包管理页面
/// 用户上传和管理角色表情包
class EmojiManagerPage extends StatefulWidget {
  const EmojiManagerPage({super.key});

  @override
  State<EmojiManagerPage> createState() => _EmojiManagerPageState();
}

class _EmojiManagerPageState extends State<EmojiManagerPage> {
  // 表情分类
  final List<String> _categories = [
    'happy',
    'sad',
    'angry',
    'surprised',
    'love',
    'neutral',
  ];
  String _selectedCategory = 'happy';

  // 模拟表情数据（实际需要从存储加载）
  final Map<String, List<String>> _emojis = {
    'happy': [],
    'sad': [],
    'angry': [],
    'surprised': [],
    'love': [],
    'neutral': [],
  };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFEDEDED),
      appBar: AppBar(
        backgroundColor: const Color(0xFFEDEDED),
        elevation: 0,
        title: const Text('表情包管理'),
        leading: IconButton(
          onPressed: () => Navigator.pop(context),
          icon: const Icon(Icons.arrow_back_ios, size: 20),
        ),
      ),
      body: Column(
        children: [
          // 分类标签
          _buildCategoryTabs(),

          // 表情列表
          Expanded(child: _buildEmojiGrid()),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _addEmoji,
        backgroundColor: const Color(0xFF07C160),
        child: const Icon(Icons.add),
      ),
    );
  }

  Widget _buildCategoryTabs() {
    return Container(
      color: Colors.white,
      height: 50,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: _categories.length,
        itemBuilder: (context, index) {
          final category = _categories[index];
          final isSelected = category == _selectedCategory;

          return GestureDetector(
            onTap: () => setState(() => _selectedCategory = category),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
              decoration: BoxDecoration(
                color: isSelected
                    ? const Color(0xFF07C160)
                    : const Color(0xFFF5F5F5),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Center(
                child: Text(
                  _getCategoryLabel(category),
                  style: TextStyle(
                    color: isSelected ? Colors.white : Colors.black,
                    fontSize: 14,
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildEmojiGrid() {
    final emojis = _emojis[_selectedCategory] ?? [];

    if (emojis.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.emoji_emotions_outlined,
              size: 64,
              color: Colors.grey[400],
            ),
            const SizedBox(height: 16),
            Text(
              '暂无表情',
              style: TextStyle(fontSize: 16, color: Colors.grey[500]),
            ),
            const SizedBox(height: 8),
            Text(
              '点击 + 添加表情',
              style: TextStyle(fontSize: 14, color: Colors.grey[400]),
            ),
          ],
        ),
      );
    }

    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 4,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
      ),
      itemCount: emojis.length,
      itemBuilder: (context, index) {
        return GestureDetector(
          onLongPress: () => _deleteEmoji(index),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.network(
              emojis[index],
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => Container(
                color: Colors.grey[300],
                child: const Icon(Icons.broken_image, color: Colors.grey),
              ),
            ),
          ),
        );
      },
    );
  }

  String _getCategoryLabel(String category) {
    switch (category) {
      case 'happy':
        return '😊 开心';
      case 'sad':
        return '😢 难过';
      case 'angry':
        return '😠 生气';
      case 'surprised':
        return '😲 惊讶';
      case 'love':
        return '❤️ 喜欢';
      case 'neutral':
        return '😐 平静';
      default:
        return category;
    }
  }

  void _addEmoji() async {
    final urlController = TextEditingController();

    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('添加表情'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '当前分类: ${_getCategoryLabel(_selectedCategory)}',
              style: const TextStyle(color: Color(0xFF888888)),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: urlController,
              decoration: const InputDecoration(
                labelText: '表情图片 URL',
                hintText: 'https://example.com/emoji.gif',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, urlController.text),
            child: const Text('添加'),
          ),
        ],
      ),
    );

    if (result != null && result.isNotEmpty) {
      setState(() {
        _emojis[_selectedCategory]!.add(result);
      });
      // TODO: 保存到存储
    }
  }

  void _deleteEmoji(int index) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除表情'),
        content: const Text('确定要删除这个表情吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              setState(() {
                _emojis[_selectedCategory]!.removeAt(index);
              });
              // TODO: 保存到存储
            },
            child: const Text('删除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }
}
