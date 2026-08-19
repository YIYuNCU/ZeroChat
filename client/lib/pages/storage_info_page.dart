import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';

import '../services/local_storage_service.dart';

class StorageInfoPage extends StatefulWidget {
  const StorageInfoPage({super.key});

  @override
  State<StorageInfoPage> createState() => _StorageInfoPageState();
}

class _StorageInfoPageState extends State<StorageInfoPage> {
  final LocalStorageService _storageService = LocalStorageService.instance;
  late Future<List<LocalStorageCategoryInfo>> _categoriesFuture;

  @override
  void initState() {
    super.initState();
    _categoriesFuture = _storageService.listCategories();
  }

  Future<void> _refresh() async {
    final future = _storageService.listCategories();
    setState(() => _categoriesFuture = future);
    await future;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFEDEDED),
      appBar: AppBar(
        title: const Text('存储信息'),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: _refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: FutureBuilder<List<LocalStorageCategoryInfo>>(
        future: _categoriesFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return _ErrorState(onRetry: _refresh);
          }
          final categories = snapshot.data ?? const [];
          return RefreshIndicator(
            onRefresh: _refresh,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                const SizedBox(height: 10),
                Container(
                  color: Colors.white,
                  child: Column(
                    children: [
                      for (
                        var index = 0;
                        index < categories.length;
                        index++
                      ) ...[
                        _CategoryRow(
                          info: categories[index],
                          onTap: () => _openCategory(categories[index]),
                        ),
                        if (index != categories.length - 1)
                          const Divider(height: 1, indent: 56),
                      ],
                    ],
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: Text(
                    '仅管理本机聊天记录、下载表情和头像缓存，不影响已导入表情、设置及云端数据。',
                    style: TextStyle(fontSize: 13, color: Color(0xFF888888)),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _openCategory(LocalStorageCategoryInfo info) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => _StorageCategoryPage(
          storageService: _storageService,
          category: info.category,
        ),
      ),
    );
    if (mounted) await _refresh();
  }
}

class _CategoryRow extends StatelessWidget {
  const _CategoryRow({required this.info, required this.onTap});

  final LocalStorageCategoryInfo info;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final icon = switch (info.category) {
      LocalStorageCategory.chatArchives => Icons.forum_outlined,
      LocalStorageCategory.emojiCache => Icons.emoji_emotions_outlined,
      LocalStorageCategory.avatarCache => Icons.account_circle_outlined,
    };
    final iconColor = switch (info.category) {
      LocalStorageCategory.chatArchives => const Color(0xFF07C160),
      LocalStorageCategory.emojiCache => const Color(0xFFFFAA00),
      LocalStorageCategory.avatarCache => const Color(0xFF4A90E2),
    };
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Icon(icon, color: iconColor, size: 26),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    info.category.label,
                    style: const TextStyle(fontSize: 16),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    info.isEmpty
                        ? info.category.emptyMessage
                        : '${info.fileCount} 个文件，共 ${formatBytes(info.totalBytes)}',
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF888888),
                    ),
                  ),
                ],
              ),
            ),
            const Icon(
              Icons.arrow_forward_ios,
              size: 16,
              color: Color(0xFFCCCCCC),
            ),
          ],
        ),
      ),
    );
  }
}

class _StorageCategoryPage extends StatefulWidget {
  const _StorageCategoryPage({
    required this.storageService,
    required this.category,
  });

  final LocalStorageService storageService;
  final LocalStorageCategory category;

  @override
  State<_StorageCategoryPage> createState() => _StorageCategoryPageState();
}

class _StorageCategoryPageState extends State<_StorageCategoryPage> {
  late Future<LocalStorageCategoryInfo> _infoFuture;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _infoFuture = widget.storageService.getCategoryInfo(widget.category);
  }

  Future<void> _refresh() async {
    final future = widget.storageService.getCategoryInfo(widget.category);
    setState(() => _infoFuture = future);
    await future;
  }

  Future<void> _export(LocalStorageCategoryInfo info) async {
    if (_busy || info.isEmpty) return;
    setState(() => _busy = true);
    try {
      final archive = await widget.storageService.exportCategory(
        widget.category,
      );
      await Share.shareXFiles([
        XFile(archive.path),
      ], subject: 'ZeroChat ${widget.category.label}');
    } catch (_) {
      _showMessage('导出失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete(LocalStorageCategoryInfo info) async {
    if (_busy || info.isEmpty) return;
    final proceed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('删除${widget.category.label}'),
        content: Text(
          '将删除本机的 ${info.fileCount} 个文件（${formatBytes(info.totalBytes)}）。'
          '此操作不会删除云端数据，但本机数据无法恢复。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('继续删除'),
          ),
        ],
      ),
    );
    if (proceed != true || !mounted) return;

    final confirmationController = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('确认删除'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('请输入“${widget.category.label}”以确认删除。'),
              const SizedBox(height: 12),
              TextField(
                controller: confirmationController,
                autofocus: true,
                onChanged: (_) => setDialogState(() {}),
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  hintText: '输入类别名称',
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: confirmationController.text == widget.category.label
                  ? () => Navigator.pop(context, true)
                  : null,
              style: TextButton.styleFrom(foregroundColor: Colors.red),
              child: const Text('删除'),
            ),
          ],
        ),
      ),
    );
    confirmationController.dispose();
    if (confirmed != true || !mounted) return;

    setState(() => _busy = true);
    try {
      await widget.storageService.deleteCategory(widget.category);
      await _refresh();
      _showMessage('已删除${widget.category.label}');
    } catch (_) {
      _showMessage('删除失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<LocalStorageCategoryInfo>(
      future: _infoFuture,
      builder: (context, snapshot) {
        final info = snapshot.data;
        return Scaffold(
          backgroundColor: const Color(0xFFEDEDED),
          appBar: AppBar(
            title: Text(widget.category.label),
            actions: [
              IconButton(
                tooltip: '导出',
                onPressed: info == null || info.isEmpty || _busy
                    ? null
                    : () => _export(info),
                icon: const Icon(Icons.ios_share_outlined),
              ),
              IconButton(
                tooltip: '删除',
                onPressed: info == null || info.isEmpty || _busy
                    ? null
                    : () => _delete(info),
                icon: const Icon(Icons.delete_outline),
              ),
            ],
          ),
          body: _buildBody(snapshot),
        );
      },
    );
  }

  Widget _buildBody(AsyncSnapshot<LocalStorageCategoryInfo> snapshot) {
    if (snapshot.connectionState == ConnectionState.waiting) {
      return const Center(child: CircularProgressIndicator());
    }
    if (snapshot.hasError) return _ErrorState(onRetry: _refresh);
    final info = snapshot.data;
    if (info == null || info.isEmpty) {
      return Center(
        child: Text(
          widget.category.emptyMessage,
          style: const TextStyle(color: Color(0xFF888888)),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(top: 10),
        itemCount: info.files.length + 1,
        separatorBuilder: (_, index) => index == 0
            ? const SizedBox(height: 10)
            : const Divider(height: 1, indent: 16),
        itemBuilder: (context, index) {
          if (index == 0) {
            return Container(
              color: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Text(
                '${info.fileCount} 个文件，共 ${formatBytes(info.totalBytes)}',
                style: const TextStyle(fontSize: 13, color: Color(0xFF666666)),
              ),
            );
          }
          final file = info.files[index - 1];
          return Container(
            color: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                const Icon(
                  Icons.insert_drive_file_outlined,
                  color: Color(0xFF888888),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        file.relativePath,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '${formatBytes(file.sizeBytes)} · ${DateFormat('yyyy-MM-dd HH:mm').format(file.modifiedAt)}',
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFF888888),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.onRetry});

  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: TextButton.icon(
        onPressed: onRetry,
        icon: const Icon(Icons.refresh),
        label: const Text('读取失败，点击重试'),
      ),
    );
  }
}

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}
