import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:path_provider/path_provider.dart';
import 'package:saver_gallery/saver_gallery.dart';
import 'package:share_plus/share_plus.dart';
import 'dart:io';
import '../models/message.dart';
import '../models/role.dart';
import '../services/role_service.dart';
import '../widgets/chat_bubble.dart';

/// 多选消息生成分享截图页：把选中的消息渲染成图片，可保存相册或系统分享。
class ShareScreenshotPage extends StatefulWidget {
  final String chatName;
  final String roleName;
  final List<Message> messages;

  const ShareScreenshotPage({
    super.key,
    required this.chatName,
    required this.roleName,
    required this.messages,
  });

  @override
  State<ShareScreenshotPage> createState() => _ShareScreenshotPageState();
}

class _ShareScreenshotPageState extends State<ShareScreenshotPage> {
  final GlobalKey _boundaryKey = GlobalKey();
  bool _busy = false;

  /// 捕获 RepaintBoundary 为 PNG 字节。
  Future<Uint8List?> _capture() async {
    try {
      final boundary =
          _boundaryKey.currentContext?.findRenderObject()
              as RenderRepaintBoundary?;
      if (boundary == null) return null;
      final image = await boundary.toImage(pixelRatio: 3.0);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      return byteData?.buffer.asUint8List();
    } catch (e) {
      debugPrint('ShareScreenshotPage: capture failed: $e');
      return null;
    }
  }

  Future<void> _saveToGallery() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final bytes = await _capture();
      if (bytes == null) {
        _toast('生成图片失败');
        return;
      }
      final fileName = 'zerochat_${DateTime.now().millisecondsSinceEpoch}.png';
      final result = await SaverGallery.saveImage(
        bytes,
        quality: 100,
        fileName: fileName,
        skipIfExists: false,
      );
      _toast(result.isSuccess ? '已保存到相册' : '保存失败');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _share() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final bytes = await _capture();
      if (bytes == null) {
        _toast('生成图片失败');
        return;
      }
      final dir = await getTemporaryDirectory();
      final file = File(
        '${dir.path}/zerochat_${DateTime.now().millisecondsSinceEpoch}.png',
      );
      await file.writeAsBytes(bytes);
      await Share.shareXFiles(
        [XFile(file.path)],
        subject: widget.chatName,
      );
    } catch (e) {
      debugPrint('ShareScreenshotPage: share failed: $e');
      _toast('分享失败');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFEDEDED),
      appBar: AppBar(
        title: const Text('生成截图'),
        backgroundColor: const Color(0xFFEDEDED),
        elevation: 0,
      ),
      body: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: RepaintBoundary(
                key: _boundaryKey,
                child: Container(
                  color: const Color(0xFFEDEDED),
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: widget.messages.map(_buildBubble).toList(),
                  ),
                ),
              ),
            ),
          ),
          _buildActionBar(),
        ],
      ),
    );
  }

  Widget _buildBubble(Message message) {
    final isMe = message.senderId == 'me';
    final Role? role = isMe ? null : RoleService.getRoleById(message.senderId);
    final senderName = isMe ? '我' : (role?.name ?? widget.chatName);
    return ChatBubble(
      message: message,
      isSender: isMe,
      avatarUrl: isMe ? null : role?.avatarUrl,
      avatarHash: isMe ? null : role?.avatarHash,
      senderName: senderName,
    );
  }

  Widget _buildActionBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: Color(0xFFE0E0E0), width: 0.5)),
      ),
      child: SafeArea(
        child: Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _busy ? null : _saveToGallery,
                icon: const Icon(Icons.download),
                label: const Text('保存到相册'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: ElevatedButton.icon(
                onPressed: _busy ? null : _share,
                icon: const Icon(Icons.share),
                label: const Text('分享'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF07C160),
                  foregroundColor: Colors.white,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
