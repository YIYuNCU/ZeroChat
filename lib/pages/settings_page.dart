import 'dart:io';
import 'package:flutter/material.dart';
import '../services/settings_service.dart';
import '../services/image_service.dart';

/// 设置页面
/// 整合背景设置等功能
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFEDEDED),
      appBar: AppBar(
        backgroundColor: const Color(0xFFEDEDED),
        elevation: 0,
        centerTitle: true,
        title: const Text(
          '设置',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w500),
        ),
      ),
      body: ListView(
        children: [
          const SizedBox(height: 10),

          // 背景设置
          _buildSectionHeader('背景'),
          _buildSection([
            _buildImageItem(
              title: '朋友圈封面',
              currentPath: SettingsService.instance.coverImageUrl,
              onSelect: () => _selectImage('cover'),
            ),
            const Divider(height: 1, indent: 16),
            _buildImageItem(
              title: '聊天背景',
              currentPath: SettingsService.instance.chatBackgroundUrl,
              onSelect: () => _selectImage('background'),
            ),
          ]),

          const SizedBox(height: 20),

          // 消息等待时间设置
          _buildSectionHeader('消息发送'),
          _buildSection([_buildWaitIntervalItem()]),

          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              '消息等待时间：发送消息后等待指定秒数，期间发送的消息会合并为一条发送给AI，方便多段输入。设为 0 表示立即发送。',
              style: TextStyle(color: Color(0xFF888888), fontSize: 12),
            ),
          ),

          const SizedBox(height: 20),

          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              '点击设置背景图片，支持从相册选择本地图片。',
              style: TextStyle(color: Color(0xFF888888), fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  /// 构建等待时间设置项
  Widget _buildWaitIntervalItem() {
    final seconds = SettingsService.instance.messageWaitSeconds;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('等待时间', style: TextStyle(fontSize: 16)),
              Text(
                seconds == 0 ? '立即发送' : '$seconds 秒',
                style: const TextStyle(
                  fontSize: 16,
                  color: Color(0xFF07C160),
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: const Color(0xFF07C160),
              inactiveTrackColor: const Color(0xFFE0E0E0),
              thumbColor: const Color(0xFF07C160),
              overlayColor: const Color(0x2007C160),
              trackHeight: 4,
            ),
            child: Slider(
              value: seconds.toDouble(),
              min: 0,
              max: 10,
              divisions: 10,
              onChanged: (value) async {
                await SettingsService.instance.updateMessageWaitSeconds(
                  value.round(),
                );
                if (mounted) setState(() {});
              },
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: const [
              Text(
                '0',
                style: TextStyle(color: Color(0xFF888888), fontSize: 12),
              ),
              Text(
                '10秒',
                style: TextStyle(color: Color(0xFF888888), fontSize: 12),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Text(
        title,
        style: const TextStyle(color: Color(0xFF888888), fontSize: 13),
      ),
    );
  }

  Widget _buildSection(List<Widget> children) {
    return Container(
      color: Colors.white,
      child: Column(children: children),
    );
  }

  Widget _buildImageItem({
    required String title,
    required String currentPath,
    required VoidCallback onSelect,
  }) {
    return InkWell(
      onTap: onSelect,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Expanded(child: Text(title, style: const TextStyle(fontSize: 16))),
            if (currentPath.isNotEmpty)
              _buildPreview(currentPath)
            else
              _buildPlaceholder(),
            const SizedBox(width: 8),
            const Icon(
              Icons.arrow_forward_ios,
              size: 14,
              color: Color(0xFFCCCCCC),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPreview(String path) {
    if (ImageService.isLocalPath(path)) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: Image.file(
          File(path),
          width: 40,
          height: 40,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _buildBrokenImage(),
        ),
      );
    } else {
      return ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: Image.network(
          path,
          width: 40,
          height: 40,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _buildBrokenImage(),
        ),
      );
    }
  }

  Widget _buildBrokenImage() {
    return Container(
      width: 40,
      height: 40,
      color: const Color(0xFFEEEEEE),
      child: const Icon(Icons.broken_image, size: 20, color: Color(0xFFAAAAAA)),
    );
  }

  Widget _buildPlaceholder() {
    return const Text(
      '未设置',
      style: TextStyle(color: Color(0xFFAAAAAA), fontSize: 14),
    );
  }

  void _selectImage(String type) {
    final currentPath = type == 'cover'
        ? SettingsService.instance.coverImageUrl
        : SettingsService.instance.chatBackgroundUrl;

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: const Color(0xFFDDDDDD),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 16),
            ListTile(
              leading: const Icon(
                Icons.photo_library,
                color: Color(0xFF07C160),
              ),
              title: const Text('从相册选择'),
              onTap: () async {
                Navigator.pop(ctx);
                final path = await ImageService.instance.pickImage();
                if (path != null) {
                  await _saveImagePath(type, path);
                }
              },
            ),
            if (currentPath.isNotEmpty) ...[
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.delete_outline, color: Colors.red),
                title: const Text('清除'),
                onTap: () async {
                  Navigator.pop(ctx);
                  await _saveImagePath(type, '');
                },
              ),
            ],
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  Future<void> _saveImagePath(String type, String path) async {
    if (type == 'cover') {
      await SettingsService.instance.updateDisplaySettings(coverImageUrl: path);
    } else {
      await SettingsService.instance.updateDisplaySettings(
        chatBackgroundUrl: path,
      );
    }
    if (mounted) {
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(type == 'cover' ? '朋友圈封面已更新' : '聊天背景已更新'),
          duration: const Duration(seconds: 1),
        ),
      );
    }
  }
}
