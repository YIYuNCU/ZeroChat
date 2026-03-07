import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../models/emoji_item.dart';
import '../services/emoji_service.dart';
import '../services/role_service.dart';
import '../services/secure_backend_client.dart';
import '../services/settings_service.dart';

/// 表情管理页面
/// 支持 AI 表情和用户表情的分类/上传/删除
class EmojiManagerPage extends StatefulWidget {
  final String? roleId;

  const EmojiManagerPage({super.key, this.roleId});

  @override
  State<EmojiManagerPage> createState() => _EmojiManagerPageState();
}

class _EmojiManagerPageState extends State<EmojiManagerPage> {
  final ImagePicker _picker = ImagePicker();
  bool _loading = true;
  bool _aiMode = false;
  String _baseUrl = '';

  List<String> _categories = [];
  String? _selectedCategory;
  List<EmojiItem> _emojis = [];

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() => _loading = true);

    final backendUrl = SettingsService.instance.backendUrl;
    final categories = _aiMode
        ? (widget.roleId == null
              ? <String>[]
              : await EmojiService.instance.getAiCategories(widget.roleId!))
        : await EmojiService.instance.getUserCategories();

    final selected = _selectedCategory != null && categories.contains(_selectedCategory)
        ? _selectedCategory
        : (categories.isNotEmpty ? categories.first : null);

    final emojis = await _loadEmojis(selected);

    if (!mounted) {
      return;
    }

    setState(() {
      _baseUrl = backendUrl;
      _categories = categories;
      _selectedCategory = selected;
      _emojis = emojis;
      _loading = false;
    });
  }

  Future<List<EmojiItem>> _loadEmojis(String? category) async {
    if (category == null) {
      return [];
    }
    if (_aiMode) {
      if (widget.roleId == null) {
        return [];
      }
      return EmojiService.instance.getAiEmojis(widget.roleId!, category);
    }
    return EmojiService.instance.getUserEmojis(category: category);
  }

  Future<void> _selectCategory(String category) async {
    setState(() {
      _selectedCategory = category;
      _loading = true;
    });
    final emojis = await _loadEmojis(category);
    if (!mounted) {
      return;
    }
    setState(() {
      _emojis = emojis;
      _loading = false;
    });
  }

  Future<void> _switchMode(bool aiMode) async {
    if (_aiMode == aiMode) {
      return;
    }
    setState(() {
      _aiMode = aiMode;
      _selectedCategory = null;
    });
    await _loadData();
  }

  Future<void> _addCategory() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('新增分类'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            hintText: '请输入分类名',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('确定'),
          ),
        ],
      ),
    );

    if (name == null || name.isEmpty) {
      return;
    }

    final success = _aiMode
        ? (widget.roleId == null
              ? false
              : await EmojiService.instance.addAiCategory(widget.roleId!, name))
        : await EmojiService.instance.addUserCategory(name);

    if (success) {
      await _loadData();
    }
  }

  Future<void> _deleteCategory([String? categoryName]) async {
    final targetCategory = categoryName ?? _selectedCategory;
    if (targetCategory == null || targetCategory.isEmpty) {
      return;
    }

    final shouldDelete = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除分类'),
        content: Text('长按删除已触发，确定删除分类 "$targetCategory" 及其所有表情吗？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (shouldDelete != true) {
      return;
    }

    final success = _aiMode
        ? (widget.roleId == null
              ? false
              : await EmojiService.instance.deleteAiCategory(widget.roleId!, targetCategory))
        : await EmojiService.instance.deleteUserCategory(targetCategory);

    if (success) {
      await _loadData();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已删除分类: $targetCategory')),
      );
    }
  }

  Future<void> _uploadEmoji() async {
    if (_selectedCategory == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先创建并选择分类')),
      );
      return;
    }

    final picked = await _picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 90,
      maxWidth: 1200,
    );
    if (picked == null) {
      return;
    }

    String tag = '';
    if (!_aiMode) {
      final tagController = TextEditingController();
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('设置标签'),
          content: TextField(
            controller: tagController,
            decoration: const InputDecoration(
              hintText: '例如: 开心、害羞、撒娇',
              border: OutlineInputBorder(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('上传'),
            ),
          ],
        ),
      );
      if (confirmed != true) {
        return;
      }
      tag = tagController.text.trim();
      if (tag.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('用户表情必须填写标签')),
        );
        return;
      }
    }

    EmojiItem? result;
    if (_aiMode) {
      if (widget.roleId != null) {
        result = await EmojiService.instance.uploadAiEmoji(
          roleId: widget.roleId!,
          category: _selectedCategory!,
          filePath: picked.path,
        );
      }
    } else {
      result = await EmojiService.instance.uploadUserEmoji(
        category: _selectedCategory!,
        tag: tag,
        filePath: picked.path,
      );
    }

    if (result != null) {
      await _selectCategory(_selectedCategory!);
    }
  }

  Future<void> _deleteEmoji(EmojiItem emoji) async {
    final shouldDelete = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除表情'),
        content: const Text('确定删除该表情吗？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (shouldDelete != true) {
      return;
    }

    final success = _aiMode
        ? await EmojiService.instance.deleteAiEmoji(
            roleId: widget.roleId ?? '',
            category: emoji.category,
            filename: emoji.filename ?? '',
          )
        : await EmojiService.instance.deleteUserEmoji(emoji.id);

    if (success && _selectedCategory != null) {
      await _selectCategory(_selectedCategory!);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('表情已删除')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFEDEDED),
      appBar: AppBar(
        backgroundColor: const Color(0xFFEDEDED),
        elevation: 0,
        title: const Text('表情管理'),
        actions: [
          IconButton(
            icon: const Icon(Icons.file_download_outlined),
            tooltip: '一键导入原有表情',
            onPressed: _importLegacyStickers,
          ),
          IconButton(
            icon: const Icon(Icons.create_new_folder_outlined),
            tooltip: '新增分类',
            onPressed: _addCategory,
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: '删除当前分类',
            onPressed: _deleteCategory,
          ),
        ],
      ),
      body: Column(
        children: [
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _modeButton('用户表情', false),
              const SizedBox(width: 8),
              _modeButton('AI表情', true),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 38,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: _categories.length,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              separatorBuilder: (_, _) => const SizedBox(width: 6),
              itemBuilder: (context, index) {
                final category = _categories[index];
                return GestureDetector(
                  onLongPress: () => _deleteCategory(category),
                  child: ChoiceChip(
                    selected: category == _selectedCategory,
                    label: Text(category),
                    onSelected: (_) => _selectCategory(category),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _buildEmojiGrid(),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _uploadEmoji,
        backgroundColor: const Color(0xFF07C160),
        child: const Icon(Icons.add),
      ),
    );
  }

  Widget _modeButton(String label, bool ai) {
    final selected = _aiMode == ai;
    return GestureDetector(
      onTap: () => _switchMode(ai),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          color: selected ? const Color(0xFF07C160) : Colors.white,
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? Colors.white : const Color(0xFF4A4A4A),
            fontWeight: FontWeight.w600,
            fontSize: 13,
          ),
        ),
      ),
    );
  }

  Widget _buildEmojiGrid() {
    if (_emojis.isEmpty) {
      return const Center(child: Text('暂无表情，点击 + 上传'));
    }

    return GridView.builder(
      padding: const EdgeInsets.all(12),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 4,
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
      ),
      itemCount: _emojis.length,
      itemBuilder: (context, index) {
        final emoji = _emojis[index];
        final url = EmojiService.instance.withBase(emoji.url, _baseUrl);
        return GestureDetector(
          onLongPress: () => _deleteEmoji(emoji),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              color: Colors.white,
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Image.network(
                    url,
                    headers: SecureBackendClient.authHeaders,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => const Icon(Icons.broken_image),
                  ),
                  if (!_aiMode && (emoji.tag ?? '').isNotEmpty)
                    Align(
                      alignment: Alignment.bottomCenter,
                      child: Container(
                        color: const Color(0xAA000000),
                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                        child: Text(
                          emoji.tag!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white, fontSize: 10),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _importLegacyStickers() async {
    final targetRole = widget.roleId != null
        ? RoleService.getRoleById(widget.roleId!)
        : RoleService.getCurrentRole();

    final stickers = targetRole?.stickerConfig.stickers ?? const [];
    if (stickers.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('未找到可导入的原有表情')));
      return;
    }

    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('导入原有表情'),
        content: Text('检测到 ${stickers.length} 个旧表情，是否导入到用户表情库？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('开始导入'),
          ),
        ],
      ),
    );

    if (confirm != true) {
      return;
    }

    if (!mounted) return;
    setState(() => _loading = true);

    var success = 0;
    var skipped = 0;
    var failed = 0;

    for (final sticker in stickers) {
      try {
        final path = sticker.imagePath.trim();
        if (path.isEmpty || path.startsWith('http://') || path.startsWith('https://')) {
          skipped++;
          continue;
        }

        final file = File(path);
        if (!await file.exists()) {
          skipped++;
          continue;
        }

        final imported = await EmojiService.instance.uploadUserEmoji(
          category: sticker.emotion,
          tag: (sticker.name == null || sticker.name!.trim().isEmpty)
              ? sticker.emotion
              : sticker.name!.trim(),
          filePath: path,
        );

        if (imported != null) {
          success++;
        } else {
          failed++;
        }
      } catch (_) {
        failed++;
      }
    }

    await _loadData();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('导入完成：成功 $success，跳过 $skipped，失败 $failed'),
      ),
    );
  }
}
