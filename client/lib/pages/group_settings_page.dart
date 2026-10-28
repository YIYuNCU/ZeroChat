import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../models/group_chat.dart';
import '../models/role.dart';
import '../models/message.dart';
import '../services/group_chat_service.dart';
import '../services/role_service.dart';
import '../services/chat_list_service.dart';
import '../core/message_parts.dart';
import '../core/message_store.dart';
import '../models/voice_message.dart';
import '../widgets/member_avatars.dart';
import '../widgets/settings_group.dart';

/// 群聊设置页面
/// 管理群成员、群名称、解散群聊
class GroupSettingsPage extends StatefulWidget {
  final String groupId;

  const GroupSettingsPage({super.key, required this.groupId});

  @override
  State<GroupSettingsPage> createState() => _GroupSettingsPageState();
}

class _GroupSettingsPageState extends State<GroupSettingsPage> {
  static const Color _green = Color(0xFF07C160);
  static const Color _danger = Color(0xFFFA5151);

  GroupChat? _group;
  List<Role> _members = [];

  /// 成员移除模式：成员头像右上角出现红色减号，点击即可移出。
  bool _removeMode = false;

  @override
  void initState() {
    super.initState();
    _loadGroup();
  }

  void _loadGroup() {
    _group = GroupChatService.getGroup(widget.groupId);
    if (_group != null) {
      _members = _group!.memberIds
          .map((id) => RoleService.getRoleById(id))
          .whereType<Role>()
          .toList();
      if (_members.isEmpty) _removeMode = false;
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (_group == null) {
      return const Scaffold(body: Center(child: Text('群聊不存在')));
    }

    return Scaffold(
      backgroundColor: const Color(0xFFEDEDED),
      appBar: AppBar(
        backgroundColor: const Color(0xFFEDEDED),
        elevation: 0,
        scrolledUnderElevation: 0,
        title: const Text('群聊设置'),
        leading: IconButton(
          onPressed: () => Navigator.pop(context),
          icon: const Icon(Icons.arrow_back_ios, size: 20),
        ),
      ),
      body: ListView(
        children: [
          const SizedBox(height: 10),

          // 群成员
          _buildSection([
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        '群成员',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      Text(
                        '${_members.length}人',
                        style: const TextStyle(color: Color(0xFF888888)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _buildMemberGrid(),
                ],
              ),
            ),
          ]),

          const SizedBox(height: 10),

          // 群名称
          _buildSection([
            _buildItem(
              title: '群头像',
              trailing: GroupAvatar.forGroup(_group!, size: 36),
              onTap: _changeAvatar,
            ),
            const Divider(height: 1, indent: 16),
            _buildItem(
              title: '群聊名称',
              trailing: Text(
                _group!.name,
                style: const TextStyle(color: Color(0xFF888888)),
              ),
              onTap: _renameGroup,
            ),
          ]),

          const SizedBox(height: 10),

          // 聊天记录和记忆
          SettingsGroup(
            title: '聊天记录与记忆',
            subtitle:
                '${MessageStore.instance.getMessageCount(widget.groupId)} 条记录 · ${_group!.coreMemory.length} 条记忆',
            icon: Icons.history,
            children: [
              _buildItem(
                title: '聊天记录',
                trailing: Text(
                  '${MessageStore.instance.getMessageCount(widget.groupId)} 条',
                  style: const TextStyle(color: Color(0xFF888888)),
                ),
                onTap: _showChatHistory,
              ),
              const Divider(height: 1, indent: 16),
              _buildItem(
                title: '核心记忆总结轮数',
                trailing: Text(
                  '${_group!.summaryEveryNRounds} 轮',
                  style: const TextStyle(color: Color(0xFF888888)),
                ),
                onTap: _editSummaryRounds,
              ),
              const Divider(height: 1, indent: 16),
              _buildItem(
                title: '核心记忆',
                trailing: Text(
                  '${_group!.coreMemory.length} 条',
                  style: const TextStyle(color: Color(0xFF888888)),
                ),
                onTap: _showCoreMemory,
              ),
            ],
          ),

          const SizedBox(height: 10),

          // 防刷屏设置
          SettingsGroup(
            title: '防刷屏',
            subtitle:
                '冷却 ${_group!.cooldownSeconds} 秒 · 每分钟最多 ${_group!.maxRepliesPerMinute} 条',
            icon: Icons.speed,
            children: [
              _buildItem(
                title: 'AI 回复冷却',
                trailing: Text(
                  '${_group!.cooldownSeconds} 秒',
                  style: const TextStyle(color: Color(0xFF888888)),
                ),
                onTap: _editCooldown,
              ),
              const Divider(height: 1, indent: 16),
              _buildItem(
                title: '每分钟最大回复',
                trailing: Text(
                  '${_group!.maxRepliesPerMinute} 条',
                  style: const TextStyle(color: Color(0xFF888888)),
                ),
                onTap: _editMaxReplies,
              ),
            ],
          ),

          const SizedBox(height: 10),

          // AI 行为设置
          SettingsGroup(
            title: 'AI 行为',
            subtitle:
                '回复概率 ${(_group!.aiReplyProbability * 100).toInt()}% · 互相回复${_group!.allowAiToAiInteraction ? '开' : '关'}',
            icon: Icons.smart_toy_outlined,
            children: [
              _buildItem(
                title: 'AI 回复概率',
                trailing: Text(
                  '${(_group!.aiReplyProbability * 100).toInt()}%',
                  style: const TextStyle(color: Color(0xFF888888)),
                ),
                onTap: _editAiReplyProbability,
              ),
              const Divider(height: 1, indent: 16),
              _buildItem(
                title: 'AI 互相回复',
                trailing: Switch(
                  value: _group!.allowAiToAiInteraction,
                  onChanged: (value) async {
                    await GroupChatService.updateGroup(
                      _group!.copyWith(allowAiToAiInteraction: value),
                    );
                    _loadGroup();
                  },
                  activeThumbColor: const Color(0xFF07C160),
                ),
              ),
              const Divider(height: 1, indent: 16),
              _buildItem(
                title: '连续发言上限',
                trailing: Text(
                  '${_group!.maxConsecutiveSpeaks} 次',
                  style: const TextStyle(color: Color(0xFF888888)),
                ),
                onTap: _editMaxConsecutiveSpeaks,
              ),
            ],
          ),

          const SizedBox(height: 10),

          // 解散群聊
          _buildSection([
            InkWell(
              onTap: _confirmDissolve,
              child: const SizedBox(
                width: double.infinity,
                child: Padding(
                  padding: EdgeInsets.symmetric(vertical: 14),
                  child: Text(
                    '解散群聊',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 16, color: _danger),
                  ),
                ),
              ),
            ),
          ]),

          SizedBox(height: 30 + MediaQuery.of(context).padding.bottom),
        ],
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
    required String title,
    Widget? trailing,
    VoidCallback? onTap,
    Color? titleColor,
  }) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              title,
              style: TextStyle(fontSize: 16, color: titleColor ?? Colors.black),
            ),
            if (trailing != null)
              Row(
                children: [
                  trailing,
                  if (onTap != null) ...[
                    const SizedBox(width: 4),
                    const Icon(
                      Icons.arrow_forward_ios,
                      size: 14,
                      color: Color(0xFFCCCCCC),
                    ),
                  ],
                ],
              ),
          ],
        ),
      ),
    );
  }

  /// 成员宫格：每行 5 个，末尾带「添加」「移除」入口。
  Widget _buildMemberGrid() {
    const columns = 5;
    const spacing = 8.0;
    return LayoutBuilder(
      builder: (context, constraints) {
        final itemWidth =
            ((constraints.maxWidth - spacing * (columns - 1)) / columns)
                .floorToDouble();
        return Wrap(
          spacing: spacing,
          runSpacing: 14,
          children: [
            for (final role in _members)
              SizedBox(width: itemWidth, child: _buildMemberItem(role)),
            SizedBox(
              width: itemWidth,
              child: _buildActionTile(
                icon: Icons.add,
                label: '添加',
                onTap: _addMember,
              ),
            ),
            if (_members.isNotEmpty)
              SizedBox(
                width: itemWidth,
                child: _buildActionTile(
                  icon: Icons.remove,
                  label: _removeMode ? '完成' : '移除',
                  highlight: _removeMode,
                  onTap: () => setState(() => _removeMode = !_removeMode),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _buildMemberItem(Role role) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _removeMode ? () => _confirmRemoveMember(role) : null,
      onLongPress: () => _confirmRemoveMember(role),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Stack(
            clipBehavior: Clip.none,
            children: [
              RoleAvatar(role: role, size: 48),
              if (_removeMode)
                Positioned(
                  right: -5,
                  top: -5,
                  child: Container(
                    width: 18,
                    height: 18,
                    decoration: BoxDecoration(
                      color: _danger,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 1.5),
                    ),
                    child: const Icon(
                      Icons.remove,
                      size: 12,
                      color: Colors.white,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            role.name,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11, color: Color(0xFF555555)),
          ),
        ],
      ),
    );
  }

  Widget _buildActionTile({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool highlight = false,
  }) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: highlight ? _green.withValues(alpha: 0.08) : null,
              border: Border.all(
                color: highlight ? _green : const Color(0xFFDDDDDD),
              ),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Icon(
              icon,
              color: highlight ? _green : const Color(0xFF888888),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            maxLines: 1,
            style: TextStyle(
              fontSize: 11,
              color: highlight ? _green : const Color(0xFF888888),
            ),
          ),
        ],
      ),
    );
  }

  void _addMember() async {
    final availableRoles = RoleService.getAllRoles()
        .where(
          (r) =>
              !_group!.memberIds.contains(r.id) &&
              !RoleService.isToolRoleId(r.id) &&
              !r.archived,
        )
        .toList();

    if (availableRoles.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('没有更多可添加的角色')));
      return;
    }

    final selected = await showModalBottomSheet<List<Role>>(
      context: context,
      backgroundColor: Colors.white,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      builder: (context) => _AddMemberSheet(roles: availableRoles),
    );

    if (selected == null || selected.isEmpty) return;
    for (final role in selected) {
      await GroupChatService.addMember(_group!.id, role.id);
    }
    if (!mounted) return;
    _loadGroup();
  }

  void _confirmRemoveMember(Role role) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('移除成员'),
        content: Text('确定要将"${role.name}"移出群聊吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              await GroupChatService.removeMember(_group!.id, role.id);
              if (!mounted) return;
              _loadGroup();
            },
            child: const Text('移除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  /// 更换群头像：相册 / 拍照 / 恢复为成员头像宫格。
  void _changeAvatar() async {
    final hasCustom = (_group!.avatarUrl ?? '').isNotEmpty;
    final choice = await showModalBottomSheet<String>(
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
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('从相册选择'),
              onTap: () => Navigator.pop(context, 'gallery'),
            ),
            ListTile(
              leading: const Icon(Icons.camera_alt_outlined),
              title: const Text('拍照'),
              onTap: () => Navigator.pop(context, 'camera'),
            ),
            if (hasCustom)
              ListTile(
                leading: const Icon(Icons.restore, color: _danger),
                title: const Text('恢复默认头像', style: TextStyle(color: _danger)),
                onTap: () => Navigator.pop(context, 'reset'),
              ),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;

    try {
      if (choice == 'reset') {
        await GroupChatService.clearCustomAvatar(_group!.id);
      } else {
        final picked = await ImagePicker().pickImage(
          source: choice == 'camera' ? ImageSource.camera : ImageSource.gallery,
          maxWidth: 512,
          maxHeight: 512,
          imageQuality: 85,
        );
        if (picked == null) return;
        await GroupChatService.setCustomAvatar(_group!.id, picked.path);
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('更换群头像失败，请重试')));
      return;
    }
    if (!mounted) return;
    // 聊天列表、通讯录读取的是群聊服务里的最新头像，通知列表刷新即可。
    ChatListService.instance.refresh();
    _loadGroup();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(choice == 'reset' ? '已恢复默认头像' : '群头像已更新')),
    );
  }

  void _renameGroup() async {
    final controller = TextEditingController(text: _group!.name);

    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('修改群名'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 20,
          decoration: const InputDecoration(
            hintText: '输入新的群名',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (v) => Navigator.pop(context, v.trim()),
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
    controller.dispose();

    if (result != null && result.isNotEmpty && result != _group!.name) {
      await GroupChatService.renameGroup(_group!.id, result);
      // 聊天列表保存的是创建时的群名快照，这里同步后列表无需再依赖旧名称。
      ChatListService.instance.refresh();
      if (!mounted) return;
      _loadGroup();
    }
  }

  /// 通用步进器对话框：用于「冷却」「每分钟上限」「连续发言上限」等整数设置。
  Future<int?> _editStepper({
    required String title,
    required String description,
    required int value,
    required String unit,
    int min = 1,
    int? max,
  }) {
    return showDialog<int>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text(title),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(description),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    tooltip: '减少',
                    onPressed: value > min
                        ? () => setState(() => value--)
                        : null,
                    icon: const Icon(Icons.remove_circle_outline),
                  ),
                  SizedBox(
                    width: 80,
                    child: Text(
                      '$value $unit',
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 18),
                    ),
                  ),
                  IconButton(
                    tooltip: '增加',
                    onPressed: max == null || value < max
                        ? () => setState(() => value++)
                        : null,
                    icon: const Icon(Icons.add_circle_outline),
                  ),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, value),
              child: const Text('确定'),
            ),
          ],
        ),
      ),
    );
  }

  void _editCooldown() async {
    final result = await _editStepper(
      title: 'AI 回复冷却',
      description: '同一 AI 两次回复之间的最小间隔',
      value: _group!.cooldownSeconds,
      unit: '秒',
    );
    if (result == null) return;
    await GroupChatService.updateGroup(
      _group!.copyWith(cooldownSeconds: result),
    );
    if (!mounted) return;
    _loadGroup();
  }

  void _editMaxReplies() async {
    final result = await _editStepper(
      title: '每分钟最大回复',
      description: '防止 AI 刷屏，限制每分钟回复数',
      value: _group!.maxRepliesPerMinute,
      unit: '条',
    );
    if (result == null) return;
    await GroupChatService.updateGroup(
      _group!.copyWith(maxRepliesPerMinute: result),
    );
    if (!mounted) return;
    _loadGroup();
  }

  void _editAiReplyProbability() async {
    double value = _group!.aiReplyProbability;

    final result = await showDialog<double>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('AI 回复概率'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('AI 参与群聊回复的概率'),
              const SizedBox(height: 16),
              Text(
                '${(value * 100).toInt()}%',
                style: const TextStyle(fontSize: 24),
              ),
              Slider(
                value: value,
                min: 0.1,
                max: 1.0,
                divisions: 9,
                label: '${(value * 100).toInt()}%',
                onChanged: (v) => setState(() => value = v),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, value),
              child: const Text('确定'),
            ),
          ],
        ),
      ),
    );

    if (result != null) {
      await GroupChatService.updateGroup(
        _group!.copyWith(aiReplyProbability: result),
      );
      _loadGroup();
    }
  }

  void _editMaxConsecutiveSpeaks() async {
    final result = await _editStepper(
      title: '连续发言上限',
      description: '同一 AI 角色连续发言的最大次数',
      value: _group!.maxConsecutiveSpeaks,
      unit: '次',
      max: 5,
    );
    if (result == null) return;
    await GroupChatService.updateGroup(
      _group!.copyWith(maxConsecutiveSpeaks: result),
    );
    if (!mounted) return;
    _loadGroup();
  }

  // ========== 聊天记录和记忆功能 ==========

  void _showChatHistory() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            final messages = MessageStore.instance.getMessages(widget.groupId);

            return DraggableScrollableSheet(
              initialChildSize: 0.7,
              minChildSize: 0.3,
              maxChildSize: 0.9,
              expand: false,
              builder: (context, scrollController) {
                return Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            '聊天记录 (${messages.length} 条)',
                            style: const TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          if (messages.isNotEmpty)
                            TextButton(
                              onPressed: () async {
                                final confirm = await _confirmDestructive(
                                  '清空聊天记录',
                                  '确定要清空该群聊的所有聊天记录吗？此操作不可恢复。',
                                );
                                if (confirm != true) return;
                                await MessageStore.instance.clearMessages(
                                  widget.groupId,
                                );
                                setModalState(() {});
                                setState(() {});
                              },
                              child: const Text(
                                '清空',
                                style: TextStyle(color: Colors.red),
                              ),
                            ),
                        ],
                      ),
                    ),
                    const Divider(height: 1),
                    Expanded(
                      child: messages.isEmpty
                          ? const Center(
                              child: Text(
                                '暂无聊天记录',
                                style: TextStyle(color: Color(0xFF888888)),
                              ),
                            )
                          : ListView.builder(
                              controller: scrollController,
                              itemCount: messages.length,
                              itemBuilder: (context, index) {
                                final msg = messages[index];
                                return _buildMessageItem(msg, setModalState);
                              },
                            ),
                    ),
                  ],
                );
              },
            );
          },
        );
      },
    );
  }

  String _senderLabel(Message msg) {
    if (msg.senderId == 'me') return '我';
    return RoleService.getRoleById(msg.senderId)?.name ?? '未知成员';
  }

  /// 记录列表里的单行预览：图片/语音显示占位，文本只取对话部分。
  String _previewOf(Message msg) {
    switch (msg.type) {
      case MessageType.image:
      case MessageType.sticker:
        return '[图片]';
      case MessageType.voice:
        return VoiceMessage.previewLabel;
      default:
        final text = MessageParts.previewText(
          msg.content,
          isUserMessage: msg.senderId == 'me',
        );
        return text.trim().isEmpty ? msg.content : text;
    }
  }

  Widget _buildSenderAvatar(Message msg, double size) {
    if (msg.senderId == 'me') {
      return ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: Container(
          width: size,
          height: size,
          color: const Color(0xFF7EB7E7),
          child: Icon(Icons.person, color: Colors.white, size: size * 0.6),
        ),
      );
    }
    final role = RoleService.getRoleById(msg.senderId);
    if (role != null) return RoleAvatar(role: role, size: size);
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: Container(
        width: size,
        height: size,
        color: const Color(0xFFBBBBBB),
        child: Icon(Icons.person_off, color: Colors.white, size: size * 0.55),
      ),
    );
  }

  String _formatHistoryTime(DateTime t) {
    final now = DateTime.now();
    final hm =
        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    if (t.year == now.year && t.month == now.month && t.day == now.day) {
      return hm;
    }
    return '${t.month}/${t.day} $hm';
  }

  Widget _buildMessageItem(Message msg, StateSetter setModalState) {
    return ListTile(
      onTap: () => _showFullMessage(msg),
      leading: _buildSenderAvatar(msg, 40),
      title: Text(
        _senderLabel(msg),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 13, color: Color(0xFF888888)),
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Text(
          _previewOf(msg),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 15, color: Colors.black87),
        ),
      ),
      trailing: Text(
        _formatHistoryTime(msg.timestamp),
        style: const TextStyle(fontSize: 12, color: Color(0xFFBBBBBB)),
      ),
    );
  }

  void _showFullMessage(Message msg) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            _buildSenderAvatar(msg, 32),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _senderLabel(msg),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 16),
                  ),
                  Text(
                    _formatHistoryTime(msg.timestamp),
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.normal,
                      color: Color(0xFF999999),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        content: SingleChildScrollView(
          child: SelectableText(
            msg.content,
            style: const TextStyle(fontSize: 15, height: 1.5),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  void _editSummaryRounds() async {
    int value = _group!.summaryEveryNRounds;

    final result = await showDialog<int>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('核心记忆总结轮数'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('每隔多少轮对话后自动总结核心记忆'),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    onPressed: value > 5
                        ? () => setState(() => value -= 5)
                        : null,
                    icon: const Icon(Icons.remove_circle_outline),
                  ),
                  Text('$value 轮', style: const TextStyle(fontSize: 18)),
                  IconButton(
                    onPressed: value < 100
                        ? () => setState(() => value += 5)
                        : null,
                    icon: const Icon(Icons.add_circle_outline),
                  ),
                ],
              ),
              Slider(
                value: value.toDouble(),
                min: 5,
                max: 100,
                divisions: 19,
                label: '$value 轮',
                onChanged: (v) => setState(() => value = v.round()),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, value),
              child: const Text('确定'),
            ),
          ],
        ),
      ),
    );

    if (result != null) {
      await GroupChatService.updateGroup(
        _group!.copyWith(summaryEveryNRounds: result),
      );
      _loadGroup();
    }
  }

  void _showCoreMemory() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            final memories = _group!.coreMemory;

            return DraggableScrollableSheet(
              initialChildSize: 0.6,
              minChildSize: 0.3,
              maxChildSize: 0.9,
              expand: false,
              builder: (context, scrollController) {
                return Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            '核心记忆 (${memories.length} 条)',
                            style: const TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          Row(
                            children: [
                              TextButton.icon(
                                onPressed: () => _addCoreMemory(setModalState),
                                icon: const Icon(Icons.add, size: 18),
                                label: const Text('添加'),
                              ),
                              if (memories.isNotEmpty)
                                TextButton(
                                  onPressed: () async {
                                    final confirm = await _confirmDestructive(
                                      '清空核心记忆',
                                      '确定要清空该群聊的所有核心记忆吗？此操作不可恢复。',
                                    );
                                    if (confirm != true) return;
                                    await GroupChatService.updateGroup(
                                      _group!.clearCoreMemory(),
                                    );
                                    _loadGroup();
                                    setModalState(() {});
                                    setState(() {});
                                  },
                                  child: const Text(
                                    '清空',
                                    style: TextStyle(color: Colors.red),
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const Divider(height: 1),
                    Expanded(
                      child: memories.isEmpty
                          ? const Center(
                              child: Text(
                                '暂无核心记忆\n点击"添加"来创建',
                                textAlign: TextAlign.center,
                                style: TextStyle(color: Color(0xFF888888)),
                              ),
                            )
                          : ListView.builder(
                              controller: scrollController,
                              itemCount: memories.length,
                              itemBuilder: (context, index) {
                                return ListTile(
                                  title: Text(memories[index]),
                                  trailing: IconButton(
                                    icon: const Icon(
                                      Icons.delete_outline,
                                      color: Colors.red,
                                    ),
                                    onPressed: () async {
                                      await GroupChatService.updateGroup(
                                        _group!.removeCoreMemory(index),
                                      );
                                      _loadGroup();
                                      setModalState(() {});
                                      setState(() {});
                                    },
                                  ),
                                );
                              },
                            ),
                    ),
                  ],
                );
              },
            );
          },
        );
      },
    );
  }

  void _addCoreMemory(StateSetter setModalState) async {
    final controller = TextEditingController();

    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('添加核心记忆'),
        content: TextField(
          controller: controller,
          maxLines: 3,
          decoration: const InputDecoration(
            hintText: '例如：用户喜欢编程',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('添加'),
          ),
        ],
      ),
    );

    if (result != null && result.isNotEmpty) {
      await GroupChatService.updateGroup(_group!.addCoreMemory(result));
      _loadGroup();
      setModalState(() {});
      setState(() {});
    }
  }

  /// 危险操作二次确认（取消 / 红色确认）。
  Future<bool?> _confirmDestructive(String title, String content) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(content),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  void _confirmDissolve() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('解散群聊'),
        content: const Text('确定要解散群聊吗？此操作不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              await GroupChatService.deleteGroup(_group!.id);
              ChatListService.instance.removeFromList(_group!.id);
              if (context.mounted) {
                Navigator.pop(context, true);
              }
            },
            child: const Text('解散', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }
}

/// 添加成员底部面板：可多选，点「添加」一次性加入。
class _AddMemberSheet extends StatefulWidget {
  final List<Role> roles;

  const _AddMemberSheet({required this.roles});

  @override
  State<_AddMemberSheet> createState() => _AddMemberSheetState();
}

class _AddMemberSheetState extends State<_AddMemberSheet> {
  static const Color _green = Color(0xFF07C160);
  final Set<String> _selected = {};

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.of(context).size.height * 0.7;
    return SafeArea(
      child: SizedBox(
        height: height,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: Row(
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('取消'),
                  ),
                  const Expanded(
                    child: Text(
                      '添加成员',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: _selected.isEmpty
                        ? null
                        : () => Navigator.pop(
                            context,
                            widget.roles
                                .where((r) => _selected.contains(r.id))
                                .toList(),
                          ),
                    child: Text(
                      _selected.isEmpty ? '添加' : '添加(${_selected.length})',
                      style: TextStyle(
                        color: _selected.isEmpty
                            ? const Color(0xFFCCCCCC)
                            : _green,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView.builder(
                itemCount: widget.roles.length,
                itemBuilder: (context, index) {
                  final role = widget.roles[index];
                  final checked = _selected.contains(role.id);
                  return InkWell(
                    onTap: () => setState(() {
                      if (!_selected.remove(role.id)) _selected.add(role.id);
                    }),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 10,
                      ),
                      child: Row(
                        children: [
                          Icon(
                            checked
                                ? Icons.check_circle
                                : Icons.radio_button_unchecked,
                            size: 22,
                            color: checked ? _green : const Color(0xFFCCCCCC),
                          ),
                          const SizedBox(width: 12),
                          RoleAvatar(role: role, size: 40),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              role.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 16),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
