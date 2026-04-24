import 'package:flutter/material.dart';
import '../services/moments_service.dart';
import 'moments_page.dart';

/// 发现页
/// 朋友圈功能入口
class DiscoverPage extends StatefulWidget {
  const DiscoverPage({super.key});

  @override
  State<DiscoverPage> createState() => _DiscoverPageState();
}

class _DiscoverPageState extends State<DiscoverPage> {
  @override
  void initState() {
    super.initState();
    MomentsService.instance.addListener(_onMomentsChanged);
  }

  @override
  void dispose() {
    MomentsService.instance.removeListener(_onMomentsChanged);
    super.dispose();
  }

  void _onMomentsChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFEDEDED),
      body: SafeArea(
        child: ListView(
          children: [
            const SizedBox(height: 10),

            // ========== 第一组：社交 ==========
            _buildSection([
              _buildItem(
                icon: Icons.camera_outlined,
                iconColor: const Color(0xFFFF9500),
                title: '朋友圈',
                badge: MomentsService.instance.unreadCount,
                onTap: () => _openMoments(),
              ),
            ]),

            const SizedBox(height: 10),
          ],
        ),
      ),
    );
  }

  Widget _buildSection(List<Widget> children) {
    return Container(
      color: Colors.white,
      child: Column(children: children),
    );
  }

  Widget _buildItem({
    required IconData icon,
    required Color iconColor,
    required String title,
    int badge = 0,
    VoidCallback? onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            // 图标
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: iconColor,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Icon(icon, color: Colors.white, size: 18),
            ),
            const SizedBox(width: 12),
            // 标题
            Expanded(child: Text(title, style: const TextStyle(fontSize: 16))),
            // 红点/未读数
            if (badge > 0)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: const Color(0xFFFA5151),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  badge > 99 ? '99+' : badge.toString(),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            const SizedBox(width: 8),
            // 箭头
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

  void _openMoments() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const MomentsPage()),
    );
    // 返回后强制刷新 UI 以更新红点状态
    if (mounted) setState(() {});
  }
}
