import 'package:flutter/material.dart';
import '../models/favorite_collection.dart';
import '../services/favorite_service.dart';
import 'favorite_detail_page.dart';

/// 收藏列表页面
/// 显示收藏合集，支持标签筛选
class FavoritesPage extends StatefulWidget {
  const FavoritesPage({super.key});

  @override
  State<FavoritesPage> createState() => _FavoritesPageState();
}

class _FavoritesPageState extends State<FavoritesPage> {
  /// 选中的标签（用于筛选）
  final Set<String> _selectedTags = {};

  @override
  void initState() {
    super.initState();
    FavoriteService.instance.addListener(_onFavoritesChanged);
  }

  @override
  void dispose() {
    FavoriteService.instance.removeListener(_onFavoritesChanged);
    super.dispose();
  }

  void _onFavoritesChanged() {
    if (mounted) setState(() {});
  }

  /// 获取筛选后的收藏列表
  List<FavoriteCollection> get _filteredCollections {
    if (_selectedTags.isEmpty) {
      return FavoriteService.instance.collections;
    }
    return FavoriteService.instance.filterByTags(_selectedTags.toList());
  }

  @override
  Widget build(BuildContext context) {
    final allTags = FavoriteService.instance.allTags;
    final collections = _filteredCollections;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFFEDEDED),
        foregroundColor: const Color(0xFF000000),
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        title: const Text(
          '收藏',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w500),
        ),
        leading: IconButton(
          onPressed: () => Navigator.pop(context),
          icon: const Icon(Icons.arrow_back_ios, size: 20),
        ),
      ),
      body: Container(
        color: const Color(0xFFEDEDED),
        child: Column(
          children: [
            // 标签筛选
            if (allTags.isNotEmpty) _buildTagFilter(allTags),
            // 收藏列表
            Expanded(
              child: collections.isEmpty
                  ? _buildEmptyState()
                  : _buildCollectionList(collections),
            ),
          ],
        ),
      ),
    );
  }

  /// 构建标签筛选栏
  Widget _buildTagFilter(Set<String> allTags) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      color: Colors.white,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            // 全部
            _buildTagChip('全部', isAll: true),
            const SizedBox(width: 8),
            ...allTags.map(
              (tag) => Padding(
                padding: const EdgeInsets.only(right: 8),
                child: _buildTagChip(tag),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTagChip(String label, {bool isAll = false}) {
    final isSelected = isAll
        ? _selectedTags.isEmpty
        : _selectedTags.contains(label);

    return GestureDetector(
      onTap: () {
        setState(() {
          if (isAll) {
            _selectedTags.clear();
          } else {
            if (_selectedTags.contains(label)) {
              _selectedTags.remove(label);
            } else {
              _selectedTags.add(label);
            }
          }
        });
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFF07C160) : const Color(0xFFF5F5F5),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            color: isSelected ? Colors.white : const Color(0xFF666666),
          ),
        ),
      ),
    );
  }

  /// 构建空状态
  Widget _buildEmptyState() {
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.star_border, size: 64, color: Color(0xFFCCCCCC)),
          SizedBox(height: 16),
          Text(
            '暂无收藏',
            style: TextStyle(color: Color(0xFF888888), fontSize: 16),
          ),
          SizedBox(height: 8),
          Text(
            '长按消息可多选收藏',
            style: TextStyle(color: Color(0xFFBBBBBB), fontSize: 14),
          ),
        ],
      ),
    );
  }

  /// 构建收藏列表
  Widget _buildCollectionList(List<FavoriteCollection> collections) {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: collections.length,
      itemBuilder: (context, index) {
        final collection = collections[index];
        return _buildCollectionItem(collection);
      },
    );
  }

  /// 构建收藏项
  Widget _buildCollectionItem(FavoriteCollection collection) {
    final preview = collection.preview;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => _openDetail(collection),
          onLongPress: () => _showDeleteConfirm(collection),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 标题和时间
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        collection.title,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(
                      _formatTime(collection.createdAt),
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFFBBBBBB),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                // 预览（前两条消息）
                ...preview.map(
                  (line) => Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: Text(
                      line,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        color: Color(0xFF888888),
                      ),
                    ),
                  ),
                ),
                // 标签
                if (collection.tags.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 4,
                    runSpacing: 4,
                    children: collection.tags
                        .map(
                          (tag) => Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFFF0F0F0),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              tag,
                              style: const TextStyle(
                                fontSize: 11,
                                color: Color(0xFF666666),
                              ),
                            ),
                          ),
                        )
                        .toList(),
                  ),
                ],
                // 消息数量
                const SizedBox(height: 4),
                Text(
                  '共 ${collection.messages.length} 条',
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xFFBBBBBB),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _openDetail(FavoriteCollection collection) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => FavoriteDetailPage(collectionId: collection.id),
      ),
    );
  }

  void _showDeleteConfirm(FavoriteCollection collection) {
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
              FavoriteService.instance.deleteCollection(collection.id);
              Navigator.pop(context);
            },
            child: const Text('删除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  String _formatTime(DateTime time) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final targetDay = DateTime(time.year, time.month, time.day);

    if (targetDay == today) {
      return '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
    } else if (targetDay == today.subtract(const Duration(days: 1))) {
      return '昨天';
    } else if (now.difference(time).inDays < 7) {
      const weekdays = ['周日', '周一', '周二', '周三', '周四', '周五', '周六'];
      return weekdays[time.weekday % 7];
    } else {
      return '${time.month}/${time.day}';
    }
  }
}
