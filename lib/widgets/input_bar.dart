import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../models/emoji_item.dart';
import '../services/emoji_service.dart';
import '../services/secure_backend_client.dart';
import '../services/settings_service.dart';

class InputBarController extends ChangeNotifier {
  void closeControls() {
    notifyListeners();
  }
}

/// ZeroChat 风格输入栏组件
/// 用于聊天页面底部的消息输入区域
class InputBar extends StatefulWidget {
  final Function(String)? onSend;
  final Function(String imagePath)? onImageSend;
  final void Function(EmojiItem emoji)? onEmojiSend;
  final InputBarController? controller;
  final String? roleId;
  final String? hintText;

  const InputBar({
    super.key,
    this.onSend,
    this.onImageSend,
    this.onEmojiSend,
    this.controller,
    this.roleId,
    this.hintText,
  });

  @override
  State<InputBar> createState() => _InputBarState();
}

class _InputBarState extends State<InputBar> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  final ImagePicker _imagePicker = ImagePicker();
  bool _showSendButton = false;
  bool _showEmojiPicker = false;

  void _handleExternalClose() {
    final needsStateUpdate = _showEmojiPicker;
    _focusNode.unfocus();
    if (needsStateUpdate && mounted) {
      setState(() {
        _showEmojiPicker = false;
      });
    }
  }

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onTextChanged);
    widget.controller?.addListener(_handleExternalClose);
  }

  @override
  void didUpdateWidget(covariant InputBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller?.removeListener(_handleExternalClose);
      widget.controller?.addListener(_handleExternalClose);
    }
  }

  void _onTextChanged() {
    final hasText = _controller.text.trim().isNotEmpty;
    if (hasText != _showSendButton) {
      setState(() {
        _showSendButton = hasText;
      });
    }
  }

  void _handleSend() {
    final text = _controller.text.trim();
    if (text.isNotEmpty) {
      widget.onSend?.call(text);
      _controller.clear();
      if (_showEmojiPicker) {
        setState(() {
          _showEmojiPicker = false;
        });
      }
    }
  }

  void _toggleEmojiPanel() {
    if (widget.onEmojiSend == null) {
      return;
    }
    _focusNode.unfocus();
    setState(() {
      _showEmojiPicker = !_showEmojiPicker;
    });
  }

  /// 显示附件选项菜单
  void _showAttachmentMenu() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                margin: const EdgeInsets.only(top: 8),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey[300],
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _buildAttachmentOption(
                      icon: Icons.photo_library,
                      label: '相册',
                      color: const Color(0xFF07C160),
                      onTap: () => _pickImage(ImageSource.gallery),
                    ),
                    _buildAttachmentOption(
                      icon: Icons.camera_alt,
                      label: '拍照',
                      color: const Color(0xFF4A90D9),
                      onTap: () => _pickImage(ImageSource.camera),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text(
                  '取消',
                  style: TextStyle(color: Colors.grey, fontSize: 16),
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAttachmentOption({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, size: 28, color: color),
          ),
          const SizedBox(height: 8),
          Text(label, style: const TextStyle(fontSize: 12)),
        ],
      ),
    );
  }

  Future<void> _pickImage(ImageSource source) async {
    Navigator.pop(context);

    try {
      final pickedFile = await _imagePicker.pickImage(
        source: source,
        maxWidth: 1024,
        maxHeight: 1024,
        imageQuality: 85,
      );

      if (pickedFile != null && widget.onImageSend != null) {
        widget.onImageSend!(pickedFile.path);
      }
    } catch (e) {
      debugPrint('Image picker error: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('选择图片失败: $e')));
      }
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onTextChanged);
    widget.controller?.removeListener(_handleExternalClose);
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFFF7F7F7),
        border: Border(top: BorderSide(color: Color(0xFFD9D9D9), width: 0.5)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  _buildIconButton(Icons.keyboard_voice_outlined, onPressed: () {}),
                  Expanded(
                    child: Container(
                      constraints: const BoxConstraints(minHeight: 36, maxHeight: 120),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(
                          color: const Color(0xFFDCDCDC),
                          width: 0.5,
                        ),
                      ),
                      child: TextField(
                        controller: _controller,
                        focusNode: _focusNode,
                        maxLines: null,
                        textInputAction: TextInputAction.send,
                        onTap: () {
                          if (_showEmojiPicker) {
                            setState(() {
                              _showEmojiPicker = false;
                            });
                          }
                        },
                        onSubmitted: (_) => _handleSend(),
                        style: const TextStyle(
                          fontSize: 17,
                          color: Color(0xFF000000),
                        ),
                        decoration: const InputDecoration(
                          hintText: '',
                          hintStyle: TextStyle(
                            color: Color(0xFFBBBBBB),
                            fontSize: 17,
                          ),
                          border: InputBorder.none,
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 8,
                          ),
                          isDense: true,
                        ),
                      ),
                    ),
                  ),
                  _buildIconButton(Icons.emoji_emotions_outlined, onPressed: _toggleEmojiPanel),
                  if (_showSendButton)
                    _buildSendButton()
                  else
                    _buildIconButton(
                      Icons.add_circle_outline,
                      onPressed: _showAttachmentMenu,
                    ),
                ],
              ),
            ),
            if (_showEmojiPicker)
              _EmojiPickerPanel(
                roleId: widget.roleId,
                onEmojiSelected: (emoji) {
                  widget.onEmojiSend?.call(emoji);
                  setState(() {
                    _showEmojiPicker = false;
                  });
                },
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildIconButton(IconData icon, {VoidCallback? onPressed}) {
    return SizedBox(
      width: 40,
      height: 36,
      child: IconButton(
        onPressed: onPressed,
        icon: Icon(icon, size: 28, color: const Color(0xFF181818)),
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(),
      ),
    );
  }

  Widget _buildSendButton() {
    return GestureDetector(
      onTap: _handleSend,
      child: Container(
        width: 56,
        height: 36,
        margin: const EdgeInsets.only(left: 4),
        decoration: BoxDecoration(
          color: const Color(0xFF07C160),
          borderRadius: BorderRadius.circular(4),
        ),
        child: const Center(
          child: Text(
            '发送',
            style: TextStyle(
              fontSize: 16,
              color: Colors.white,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}

class _EmojiPickerPanel extends StatefulWidget {
  final String? roleId;
  final void Function(EmojiItem emoji) onEmojiSelected;

  const _EmojiPickerPanel({required this.roleId, required this.onEmojiSelected});

  @override
  State<_EmojiPickerPanel> createState() => _EmojiPickerPanelState();
}

class _EmojiPickerPanelState extends State<_EmojiPickerPanel> {
  bool _isUserTab = true;
  bool _loading = true;
  final ImagePicker _picker = ImagePicker();
  String? _baseUrl;
  final TextEditingController _searchController = TextEditingController();
  String _searchKeyword = '';
  List<String> _categories = [];
  String? _selectedCategory;
  List<EmojiItem> _emojis = [];

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() {
      final keyword = _searchController.text.trim();
      if (keyword != _searchKeyword) {
        setState(() {
          _searchKeyword = keyword;
        });
      }
    });
    _loadAll();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadAll() async {
    setState(() {
      _loading = true;
    });

    _baseUrl = SettingsService.instance.backendUrl;

    final categories = _isUserTab
        ? await EmojiService.instance.getUserCategories()
        : (widget.roleId == null
              ? <String>[]
              : await EmojiService.instance.getAiCategories(widget.roleId!));

    final selected = categories.isEmpty ? null : categories.first;
    final emojis = await _loadByCategory(selected);

    if (!mounted) {
      return;
    }

    setState(() {
      _categories = categories;
      _selectedCategory = selected;
      _emojis = emojis;
      _loading = false;
    });
  }

  Future<List<EmojiItem>> _loadByCategory(String? category) async {
    if (category == null) {
      return [];
    }
    if (_isUserTab) {
      return EmojiService.instance.getUserEmojis(category: category);
    }
    if (widget.roleId == null) {
      return [];
    }
    return EmojiService.instance.getAiEmojis(widget.roleId!, category);
  }

  Future<void> _changeCategory(String category) async {
    setState(() {
      _loading = true;
      _selectedCategory = category;
    });
    final emojis = await _loadByCategory(category);
    if (!mounted) {
      return;
    }
    setState(() {
      _emojis = emojis;
      _loading = false;
    });
  }

  Future<void> _addCategory() async {
    final controller = TextEditingController();
    final category = await showDialog<String>(
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
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('确定'),
          ),
        ],
      ),
    );

    if (category == null || category.isEmpty) {
      return;
    }

    final ok = _isUserTab
        ? await EmojiService.instance.addUserCategory(category)
        : (widget.roleId == null
              ? false
              : await EmojiService.instance.addAiCategory(widget.roleId!, category));

    if (ok) {
      await _loadAll();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('分类创建成功')),
      );
    }
  }

  Future<void> _uploadEmoji() async {
    if (_selectedCategory == null || _selectedCategory!.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先选择分类')),
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

    String tag = _selectedCategory!;
    if (_isUserTab) {
      final tagController = TextEditingController(text: _selectedCategory!);
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('设置标签'),
          content: TextField(
            controller: tagController,
            decoration: const InputDecoration(
              hintText: '请输入标签',
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
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('标签不能为空')),
        );
        return;
      }
    }

    final result = _isUserTab
        ? await EmojiService.instance.uploadUserEmoji(
            category: _selectedCategory!,
            tag: tag,
            filePath: picked.path,
          )
        : (widget.roleId == null
              ? null
              : await EmojiService.instance.uploadAiEmoji(
                  roleId: widget.roleId!,
                  category: _selectedCategory!,
                  filePath: picked.path,
                ));

    if (result != null) {
      await _changeCategory(_selectedCategory!);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('上传成功')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 300,
      decoration: const BoxDecoration(
        color: Color(0xFFF2F2F2),
        border: Border(top: BorderSide(color: Color(0xFFDCDCDC), width: 0.5)),
      ),
      child: Column(
        children: [
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _buildTabButton('用户表情', true),
              const SizedBox(width: 10),
              _buildTabButton('AI表情', false),
            ],
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchController,
                    decoration: InputDecoration(
                      hintText: _isUserTab ? '搜索标签/分类/文件名' : '搜索分类/文件名',
                      prefixIcon: const Icon(Icons.search, size: 20),
                      suffixIcon: _searchKeyword.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.close, size: 18),
                              onPressed: () => _searchController.clear(),
                            ),
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                      filled: true,
                      fillColor: Colors.white,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                TextButton(onPressed: _addCategory, child: const Text('+分类')),
                TextButton(onPressed: _uploadEmoji, child: const Text('+上传')),
              ],
            ),
          ),
          const SizedBox(height: 6),
          SizedBox(
            height: 34,
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              scrollDirection: Axis.horizontal,
              itemBuilder: (context, index) {
                final category = _categories[index];
                final selected = category == _selectedCategory;
                return ChoiceChip(
                  label: Text(category),
                  selected: selected,
                  onSelected: (_) => _changeCategory(category),
                );
              },
              separatorBuilder: (_, _) => const SizedBox(width: 6),
              itemCount: _categories.length,
            ),
          ),
          const Divider(height: 12),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _buildEmojiGrid(),
          ),
        ],
      ),
    );
  }

  Widget _buildTabButton(String label, bool userTab) {
    final selected = _isUserTab == userTab;
    return GestureDetector(
      onTap: () {
        if (_isUserTab == userTab) {
          return;
        }
        setState(() {
          _isUserTab = userTab;
        });
        _loadAll();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFF07C160) : const Color(0xFFF2F2F2),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            color: selected ? Colors.white : const Color(0xFF5C5C5C),
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  Widget _buildEmojiGrid() {
    final filteredEmojis = _filterEmojis(_emojis, _searchKeyword);

    if (filteredEmojis.isEmpty) {
      return const Center(child: Text('暂无表情'));
    }

    final base = _baseUrl ?? '';
    return GridView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 5,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
      ),
      itemCount: filteredEmojis.length,
      itemBuilder: (context, index) {
        final emoji = filteredEmojis[index];
        final fullUrl = EmojiService.instance.withBase(emoji.url, base);
        return GestureDetector(
          onTap: () {
            widget.onEmojiSelected(
              EmojiItem(
                id: emoji.id,
                category: emoji.category,
                url: fullUrl,
                tag: emoji.tag,
                filename: emoji.filename,
                isAi: emoji.isAi,
              ),
            );
          },
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              color: const Color(0xFFF3F3F3),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Image.network(
                    fullUrl,
                    fit: BoxFit.cover,
                    headers: SecureBackendClient.authHeaders,
                    errorBuilder: (_, _, _) => const Icon(Icons.image_not_supported),
                  ),
                  if (!emoji.isAi && (emoji.tag ?? '').isNotEmpty)
                    Align(
                      alignment: Alignment.bottomCenter,
                      child: Container(
                        color: const Color(0xAA000000),
                        padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 2),
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

  List<EmojiItem> _filterEmojis(List<EmojiItem> emojis, String keyword) {
    final q = keyword.trim().toLowerCase();
    if (q.isEmpty) {
      return emojis;
    }
    return emojis.where((emoji) {
      final category = emoji.category.toLowerCase();
      final filename = (emoji.filename ?? '').toLowerCase();
      final tag = (emoji.tag ?? '').toLowerCase();
      return category.contains(q) || filename.contains(q) || tag.contains(q);
    }).toList();
  }
}
