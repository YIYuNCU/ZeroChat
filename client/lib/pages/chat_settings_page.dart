import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import '../models/role.dart';
import '../models/message.dart';
import '../models/proactive_config.dart';
import '../services/role_service.dart';
import '../services/memory_service.dart';
import '../services/settings_service.dart';
import '../services/task_service.dart';
import '../services/secure_websocket_client.dart';
import '../core/message_store.dart';
import '../widgets/countdown_interval_dialog.dart';
import '../widgets/smart_avatar_image.dart';
import 'role_settings_page.dart';
import 'task_manager_page.dart';
import 'emoji_manager_page.dart';

/// 聊天设置页面
/// ZeroChat 风格的聊天信息页面
class ChatSettingsPage extends StatefulWidget {
  final String chatId;
  final String chatName;
  final Role? currentRole;
  final VoidCallback? onRoleChanged;
  final VoidCallback? onClearHistory;

  const ChatSettingsPage({
    super.key,
    required this.chatId,
    required this.chatName,
    this.currentRole,
    this.onRoleChanged,
    this.onClearHistory,
  });

  @override
  State<ChatSettingsPage> createState() => _ChatSettingsPageState();
}

class _ChatSettingsPageState extends State<ChatSettingsPage> {
  late Role _currentRole;
  List<String> _backendCoreMemory = [];

  /// 按 id 倒序排序记忆列表（最新的在最前），不依赖服务端返回顺序
  static List<Map<String, dynamic>> _sortMemoryDesc(
    List<Map<String, dynamic>> list,
  ) {
    int idOf(Map<String, dynamic> e) {
      final v = e['id'];
      if (v is int) return v;
      return int.tryParse('$v') ?? 0;
    }

    final sorted = List<Map<String, dynamic>>.from(list);
    sorted.sort((a, b) => idOf(b).compareTo(idOf(a)));
    return sorted;
  }

  @override
  void initState() {
    super.initState();
    _currentRole = widget.currentRole ?? RoleService.getCurrentRole();
    _loadBackendCoreMemory();
  }

  Future<void> _loadBackendCoreMemory() async {
    await MemoryService.refreshCoreMemoryFromBackend(roleId: _currentRole.id);
    if (!mounted) return;
    setState(() {
      _backendCoreMemory = MemoryService.getCoreMemory();
    });
  }

  Future<void> _persistCoreMemory(List<String> memories) async {
    // roles_memory_update 是权威写入，成功后本地直接采用同一份数据，
    // 无需回读（refreshCoreMemoryFromBackend）也无需整角色 upsert（updateRole）。
    await SecureWebSocketClient.instance.request('roles_memory_update', {
      'role_id': _currentRole.id,
      'core_memory': memories,
    });
    final updated = List<String>.from(memories);
    await MemoryService.setCoreMemoryLocal(updated);
    final updatedRole = _currentRole.copyWith(coreMemory: updated);
    await RoleService.updateRoleLocal(updatedRole);
    if (!mounted) return;
    setState(() {
      _backendCoreMemory = updated;
      _currentRole = updatedRole;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFEDEDED),
      appBar: AppBar(
        backgroundColor: const Color(0xFFEDEDED),
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        title: const Text(
          '聊天信息',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w500),
        ),
        leading: IconButton(
          onPressed: () => Navigator.pop(context),
          icon: const Icon(Icons.arrow_back_ios, size: 20),
        ),
      ),
      body: ListView(
        children: [
          const SizedBox(height: 10),

          // 头像和名称
          _buildSection([_buildAvatarItem()]),

          const SizedBox(height: 10),

          // 聊天背景
          _buildSection([
            _buildItem(
              title: '聊天背景',
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _currentRole.chatBackgroundUrl.isNotEmpty ? '角色专属' : '跟随全局',
                    style: const TextStyle(
                      color: Color(0xFF888888),
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(width: 4),
                  const Icon(
                    Icons.arrow_forward_ios,
                    size: 16,
                    color: Color(0xFFCCCCCC),
                  ),
                ],
              ),
              onTap: _showChatBackgroundOptions,
            ),
          ]),

          const SizedBox(height: 10),

          // 聊天记录
          _buildSection([
            _buildItem(
              title: '聊天记录',
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '${MessageStore.instance.getMessageCount(widget.chatId)} 条',
                    style: const TextStyle(
                      color: Color(0xFF888888),
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(width: 4),
                  const Icon(
                    Icons.arrow_forward_ios,
                    size: 16,
                    color: Color(0xFFCCCCCC),
                  ),
                ],
              ),
              onTap: _showChatHistory,
            ),
          ]),

          const SizedBox(height: 10),

          // 核心记忆
          _buildSection([
            _buildItem(
              title: '核心记忆',
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '${_backendCoreMemory.length} 条',
                    style: const TextStyle(
                      color: Color(0xFF888888),
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(width: 4),
                  const Icon(
                    Icons.arrow_forward_ios,
                    size: 16,
                    color: Color(0xFFCCCCCC),
                  ),
                ],
              ),
              onTap: _showCoreMemory,
            ),
          ]),

          const SizedBox(height: 10),

          // 短期记忆（对话历史）
          _buildSection([
            _buildItem(
              title: '短期记忆',
              trailing: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '对话历史',
                    style: TextStyle(color: Color(0xFF888888), fontSize: 15),
                  ),
                  SizedBox(width: 4),
                  Icon(
                    Icons.arrow_forward_ios,
                    size: 16,
                    color: Color(0xFFCCCCCC),
                  ),
                ],
              ),
              onTap: _showShortTermMemory,
            ),
          ]),

          const SizedBox(height: 10),

          // 向量记忆（长期语义记忆）
          _buildSection([
            _buildItem(
              title: '向量记忆',
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '${MemoryService.vectorMemoryCount} 条',
                    style: const TextStyle(
                      color: Color(0xFF888888),
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(width: 4),
                  const Icon(
                    Icons.arrow_forward_ios,
                    size: 16,
                    color: Color(0xFFCCCCCC),
                  ),
                ],
              ),
              onTap: _showVectorMemoryOptions,
            ),
          ]),

          const SizedBox(height: 10),

          // Token 用量统计
          _buildSection([
            _buildItem(
              title: 'Token 用量',
              trailing: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '用量与缓存',
                    style: TextStyle(color: Color(0xFF888888), fontSize: 15),
                  ),
                  SizedBox(width: 4),
                  Icon(
                    Icons.arrow_forward_ios,
                    size: 16,
                    color: Color(0xFFCCCCCC),
                  ),
                ],
              ),
              onTap: _showTokenUsage,
            ),
          ]),

          const SizedBox(height: 10),

          // 安静时间（全局设置）
          _buildSection([_buildQuietTimeItem()]),

          const SizedBox(height: 10),

          // 主动消息配置
          _buildSection([
            _buildItem(
              title: '主动消息',
              trailing: Switch(
                value: _currentRole.proactiveConfig.enabled,
                onChanged: (value) => _toggleProactiveMessage(value),
                activeColor: const Color(0xFF07C160),
              ),
            ),
            if (_currentRole.proactiveConfig.enabled) ...[
              const Divider(height: 1, indent: 16),
              _buildItem(
                title: '触发提示词',
                trailing: const Icon(
                  Icons.arrow_forward_ios,
                  size: 16,
                  color: Color(0xFFCCCCCC),
                ),
                onTap: _editProactivePrompt,
              ),
              const Divider(height: 1, indent: 16),
              _buildItem(
                title: '倒计时区间',
                trailing: Text(
                  _formatProactiveInterval(_currentRole.proactiveConfig),
                  style: const TextStyle(color: Color(0xFF888888)),
                ),
                onTap: _editProactiveCountdown,
              ),
            ],
          ]),

          const SizedBox(height: 10),

          // 定时任务
          _buildSection([
            _buildItem(
              title: '定时任务',
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '${TaskService.getTasksForChat(widget.chatId).where((t) => !t.isCompleted).length} 个',
                    style: const TextStyle(
                      color: Color(0xFF888888),
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(width: 4),
                  const Icon(
                    Icons.arrow_forward_ios,
                    size: 16,
                    color: Color(0xFFCCCCCC),
                  ),
                ],
              ),
              onTap: _openTaskManager,
            ),
          ]),

          const SizedBox(height: 10),

          // 外挂 JSON 记录
          _buildSection([
            _buildItem(
              title: '外挂记录',
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _currentRole.attachedJsonContent != null
                        ? '已导入 (${_currentRole.attachedJsonContent!.length} 字)'
                        : '未导入',
                    style: const TextStyle(
                      color: Color(0xFF888888),
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(width: 4),
                  const Icon(
                    Icons.arrow_forward_ios,
                    size: 16,
                    color: Color(0xFFCCCCCC),
                  ),
                ],
              ),
              onTap: _showAttachedJsonOptions,
            ),
          ]),

          const SizedBox(height: 10),

          // 角色设置入口
          _buildSection([
            _buildItem(
              title: '角色设置',
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _currentRole.name,
                    style: const TextStyle(
                      color: Color(0xFF888888),
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(width: 4),
                  const Icon(
                    Icons.arrow_forward_ios,
                    size: 16,
                    color: Color(0xFFCCCCCC),
                  ),
                ],
              ),
              onTap: _openRoleSettings,
            ),
            const Divider(height: 1, indent: 16),
            _buildItem(
              title: '表情管理',
              trailing: const Icon(
                Icons.arrow_forward_ios,
                size: 16,
                color: Color(0xFFCCCCCC),
              ),
              onTap: _openEmojiManager,
            ),
          ]),

          const SizedBox(height: 10),

          // 清空聊天记录
          _buildSection([
            _buildItem(
              title: '清空聊天记录',
              titleColor: const Color(0xFFFA5151),
              onTap: _confirmClearHistory,
            ),
          ]),

          const SizedBox(height: 30),
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

  Widget _buildAvatarItem() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      child: Row(
        children: [
          _buildAvatar(),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.chatName,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '角色: ${_currentRole.name}',
                  style: const TextStyle(
                    fontSize: 14,
                    color: Color(0xFF888888),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAvatar() {
    final colors = [
      const Color(0xFF7EB7E7),
      const Color(0xFF95EC69),
      const Color(0xFFFFB347),
      const Color(0xFFFF7B7B),
      const Color(0xFFB19CD9),
    ];
    final colorIndex = _currentRole.name.hashCode.abs() % colors.length;

    if (_currentRole.avatarUrl != null && _currentRole.avatarUrl!.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: SmartAvatarImage(
          remoteUrl: _currentRole.avatarUrl!,
          cacheKey: 'role_${_currentRole.id}_avatar',
          backendHash: _currentRole.avatarHash,
          width: 60,
          height: 60,
          fit: BoxFit.cover,
          fallbackBuilder: () => _buildDefaultAvatar(colors[colorIndex]),
        ),
      );
    }
    return _buildDefaultAvatar(colors[colorIndex]);
  }

  Widget _buildDefaultAvatar(Color color) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: Container(
        width: 60,
        height: 60,
        color: color,
        child: Center(
          child: Text(
            _currentRole.name.isNotEmpty
                ? _currentRole.name[0].toUpperCase()
                : '?',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 28,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ),
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
            if (trailing != null) trailing,
          ],
        ),
      ),
    );
  }

  Widget _buildQuietTimeItem() {
    final settings = TaskService.getQuietTimeSettings();
    final enabled = settings['enabled'] as bool;
    final start = settings['start_hour'] as int;
    final end = settings['end_hour'] as int;

    return InkWell(
      onTap: _showQuietTimePicker,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('安静时间', style: TextStyle(fontSize: 16)),
                if (enabled)
                  Text(
                    '$start:00 - $end:00',
                    style: const TextStyle(
                      fontSize: 13,
                      color: Color(0xFF888888),
                    ),
                  ),
              ],
            ),
            Switch(
              value: enabled,
              activeColor: const Color(0xFF07C160),
              onChanged: (value) {
                TaskService.setQuietTime(
                  enabled: value,
                  startHour: start,
                  endHour: end,
                );
                setState(() {});
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showQuietTimePicker() async {
    final settings = TaskService.getQuietTimeSettings();
    int startHour = settings['start_hour'] as int;
    int endHour = settings['end_hour'] as int;

    await showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Center(
                      child: Text(
                        '设置安静时间',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),

                    // 开始时间
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('开始时间', style: TextStyle(fontSize: 16)),
                        GestureDetector(
                          onTap: () async {
                            final time = await showTimePicker(
                              context: context,
                              initialTime: TimeOfDay(
                                hour: startHour,
                                minute: 0,
                              ),
                            );
                            if (time != null) {
                              setModalState(() {
                                startHour = time.hour;
                              });
                            }
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFFF5F5F5),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              '$startHour:00',
                              style: const TextStyle(
                                fontSize: 16,
                                color: Color(0xFF07C160),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 16),

                    // 结束时间
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('结束时间', style: TextStyle(fontSize: 16)),
                        GestureDetector(
                          onTap: () async {
                            final time = await showTimePicker(
                              context: context,
                              initialTime: TimeOfDay(hour: endHour, minute: 0),
                            );
                            if (time != null) {
                              setModalState(() {
                                endHour = time.hour;
                              });
                            }
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFFF5F5F5),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              '$endHour:00',
                              style: const TextStyle(
                                fontSize: 16,
                                color: Color(0xFF07C160),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 24),

                    // 确定按钮
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: () {
                          TaskService.setQuietTime(
                            enabled: true,
                            startHour: startHour,
                            endHour: endHour,
                          );
                          Navigator.pop(context);
                          setState(() {});
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF07C160),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                        child: const Text('确定', style: TextStyle(fontSize: 16)),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _showChatBackgroundOptions() async {
    await showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.photo_library_outlined),
                title: const Text('设置角色专属背景'),
                onTap: () async {
                  Navigator.pop(context);
                  await _pickRoleBackgroundImage();
                },
              ),
              ListTile(
                leading: const Icon(Icons.layers_clear_outlined),
                title: const Text('恢复跟随全局背景'),
                onTap: () async {
                  Navigator.pop(context);
                  await _clearRoleBackground();
                },
              ),
              ListTile(
                leading: const Icon(Icons.info_outline),
                title: Text(
                  _currentRole.chatBackgroundUrl.isNotEmpty
                      ? '当前: 角色专属背景'
                      : '当前: 全局背景',
                  style: const TextStyle(color: Color(0xFF888888)),
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  Future<void> _pickRoleBackgroundImage() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: false,
    );
    if (result == null || result.files.single.path == null) {
      return;
    }

    final path = result.files.single.path!;
    _currentRole = _currentRole.copyWith(chatBackgroundUrl: path);
    await RoleService.updateRole(_currentRole);
    if (!mounted) {
      return;
    }
    setState(() {});
    widget.onRoleChanged?.call();
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('已设置角色专属聊天背景')));
  }

  Future<void> _clearRoleBackground() async {
    if (_currentRole.chatBackgroundUrl.isEmpty) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('当前已是全局背景')));
      return;
    }

    _currentRole = _currentRole.copyWith(chatBackgroundUrl: '');
    await RoleService.updateRole(_currentRole);
    if (!mounted) {
      return;
    }
    setState(() {});
    widget.onRoleChanged?.call();
    final globalBg = SettingsService.instance.chatBackgroundUrl;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(globalBg.isEmpty ? '已恢复默认背景' : '已恢复为全局背景')),
    );
  }

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
            // 使用 MessageStore 获取消息，倒序显示（最新在最前）
            final currentMessages = MessageStore.instance
                .getMessages(widget.chatId)
                .reversed
                .toList();

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
                            '聊天记录 (${currentMessages.length} 条)',
                            style: const TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          if (currentMessages.isNotEmpty)
                            TextButton(
                              onPressed: () async {
                                await MessageStore.instance.clearMessages(
                                  widget.chatId,
                                );
                                MemoryService.clearShortTermMemory(
                                  widget.chatId,
                                );
                                setModalState(() {});
                                widget.onClearHistory?.call();
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
                      child: currentMessages.isEmpty
                          ? const Center(
                              child: Text(
                                '暂无聊天记录',
                                style: TextStyle(color: Color(0xFF888888)),
                              ),
                            )
                          : ListView.builder(
                              controller: scrollController,
                              itemCount: currentMessages.length,
                              itemBuilder: (context, index) {
                                final msg = currentMessages[index];
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

  Widget _buildMessageItem(Message msg, StateSetter setModalState) {
    final isSender = msg.senderId == 'me';
    return Dismissible(
      key: Key(msg.id),
      direction: DismissDirection.endToStart,
      background: Container(
        color: Colors.red,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 16),
        child: const Icon(Icons.delete, color: Colors.white),
      ),
      confirmDismiss: (direction) async {
        // 添加二次确认
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('删除消息'),
            content: const Text('确定要删除这条消息吗？'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('删除', style: TextStyle(color: Colors.red)),
              ),
            ],
          ),
        );
        if (confirmed == true) {
          await MessageStore.instance.deleteMessage(widget.chatId, msg.id);
          setModalState(() {});
          // 注意：这里不要调用 onClearHistory，因为那会清空所有消息
        }
        return false; // 不自动移除，手动刷新列表
      },
      child: ListTile(
        onTap: () => _showFullMessage(msg),
        leading: CircleAvatar(
          backgroundColor: isSender
              ? const Color(0xFF95EC69)
              : const Color(0xFF7EB7E7),
          child: Icon(
            isSender ? Icons.person : Icons.smart_toy,
            color: Colors.white,
            size: 20,
          ),
        ),
        title: Text(msg.content, maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          '${msg.timestamp.hour}:${msg.timestamp.minute.toString().padLeft(2, '0')}',
          style: const TextStyle(fontSize: 12),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.edit_outlined, size: 18, color: Color(0xFF888888)),
              onPressed: () async {
                final edited = await _editTextDialog('编辑消息', msg.content);
                if (edited != null && edited.isNotEmpty && edited != msg.content) {
                  await MessageStore.instance.updateMessage(
                    widget.chatId,
                    msg.id,
                    content: edited,
                  );
                  setModalState(() {});
                }
              },
            ),
            const Icon(Icons.chevron_right, color: Color(0xFFCCCCCC)),
          ],
        ),
      ),
    );
  }

  /// 显示消息全文
  void _showFullMessage(Message msg) {
    final isSender = msg.senderId == 'me';
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            CircleAvatar(
              radius: 16,
              backgroundColor: isSender
                  ? const Color(0xFF95EC69)
                  : const Color(0xFF7EB7E7),
              child: Icon(
                isSender ? Icons.person : Icons.smart_toy,
                color: Colors.white,
                size: 16,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              isSender ? '我' : _currentRole.name,
              style: const TextStyle(fontSize: 16),
            ),
            const Spacer(),
            Text(
              '${msg.timestamp.hour}:${msg.timestamp.minute.toString().padLeft(2, '0')}',
              style: const TextStyle(fontSize: 12, color: Color(0xFF888888)),
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

  void _showTokenUsage() {
    Map<String, dynamic>? stats;
    bool loading = true;

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
            Future<void> reload() async {
              final data = await MemoryService.getUsageStats(
                roleId: _currentRole.id,
              );
              if (!mounted) return;
              setModalState(() {
                stats = data;
                loading = false;
              });
            }

            if (loading) {
              reload();
            }

            final byModel =
                (stats?['by_model'] as List?)
                    ?.whereType<Map>()
                    .map((e) => e.cast<String, dynamic>())
                    .toList() ??
                <Map<String, dynamic>>[];
            final last = (stats?['last'] as Map?)?.cast<String, dynamic>();

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
                          const Text(
                            'Token 用量',
                            style: TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          TextButton(
                            onPressed: () async {
                              final confirm = await _confirmDialog(
                                '重置统计',
                                '确定要清零该角色的 Token 用量统计吗？',
                              );
                              if (confirm == true) {
                                await MemoryService.resetUsageStats(
                                  roleId: _currentRole.id,
                                );
                                await reload();
                              }
                            },
                            child: const Text(
                              '重置',
                              style: TextStyle(color: Colors.red),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Divider(height: 1),
                    Expanded(
                      child: loading
                          ? const Center(child: CircularProgressIndicator())
                          : ListView(
                              controller: scrollController,
                              padding: const EdgeInsets.all(16),
                              children: _buildUsageContent(byModel, last),
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

  List<Widget> _buildUsageContent(
    List<Map<String, dynamic>> byModel,
    Map<String, dynamic>? last,
  ) {
    int asInt(Map<String, dynamic> m, String k) {
      final v = m[k];
      if (v is int) return v;
      return int.tryParse('$v') ?? 0;
    }

    // 平均值：字段 / 请求次数，向上四舍五入取整；次数为 0 时显示 —
    String avg(Map<String, dynamic> m, String field) {
      final count = asInt(m, 'request_count');
      if (count <= 0) return '—';
      return '${(asInt(m, field) / count).round()}';
    }

    final widgets = <Widget>[];

    if (byModel.isEmpty) {
      widgets.add(
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 24),
          child: Center(
            child: Text(
              '暂无用量数据',
              style: TextStyle(fontSize: 14, color: Color(0xFF888888)),
            ),
          ),
        ),
      );
    }

    for (var i = 0; i < byModel.length; i++) {
      final m = byModel[i];
      final model = '${m['model'] ?? ''}'.trim();
      final hit = asInt(m, 'cache_hit_tokens');
      final miss = asInt(m, 'cache_miss_tokens');
      final hitRate = (hit + miss) > 0
          ? '${(hit * 100 / (hit + miss)).toStringAsFixed(1)}%'
          : '—';

      if (i > 0) widgets.add(const SizedBox(height: 20));
      widgets.addAll([
        Text(
          model.isEmpty ? '未知' : model,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        _usageRow('请求次数', '${asInt(m, 'request_count')}'),
        _usageRow('总 tokens', '${asInt(m, 'total_tokens')}'),
        _usageRow('缓存命中率', hitRate),
        _usageRow('平均总 tokens', avg(m, 'total_tokens')),
        _usageRow('平均输入 tokens', avg(m, 'prompt_tokens')),
        _usageRow('平均输出 tokens', avg(m, 'completion_tokens')),
        _usageRow('平均缓存 tokens', avg(m, 'cache_hit_tokens')),
      ]);
    }

    if (last != null) {
      widgets.addAll([
        const SizedBox(height: 20),
        const Text(
          '最近一次',
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        _usageRow('输入 tokens', '${asInt(last, 'prompt_tokens')}'),
        _usageRow('输出 tokens', '${asInt(last, 'completion_tokens')}'),
        _usageRow('总 tokens', '${asInt(last, 'total_tokens')}'),
        _usageRow('缓存命中 tokens', '${asInt(last, 'cache_hit_tokens')}'),
        _usageRow('缓存未命中 tokens', '${asInt(last, 'cache_miss_tokens')}'),
        if ('${last['model'] ?? ''}'.isNotEmpty)
          _usageRow('模型', '${last['model']}'),
        if ('${last['timestamp'] ?? ''}'.isNotEmpty)
          _usageRow(
            '时间',
            '${last['timestamp']}'.replaceFirst('T', ' ').split('.').first,
          ),
      ]);
    }

    return widgets;
  }

  Widget _usageRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: const TextStyle(fontSize: 14, color: Color(0xFF888888)),
          ),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: const TextStyle(fontSize: 14),
            ),
          ),
        ],
      ),
    );
  }

  void _showShortTermMemory() {
    List<Map<String, dynamic>> items = [];
    bool loading = true;

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
            Future<void> reload({bool forceFullRefresh = false}) async {
              final list = await MemoryService.getShortTermFromBackend(
                roleId: _currentRole.id,
                forceFullRefresh: forceFullRefresh,
              );
              if (!mounted) return;
              setModalState(() {
                items = list;
                loading = false;
              });
            }

            if (loading) {
              reload();
            }

            return DraggableScrollableSheet(
              initialChildSize: 0.7,
              minChildSize: 0.3,
              maxChildSize: 0.95,
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
                            '短期记忆 (${items.length} 条)',
                            style: const TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: const Icon(Icons.refresh, size: 20, color: Color(0xFF888888)),
                                tooltip: '增量刷新',
                                onPressed: () => reload(),
                              ),
                              if (items.isNotEmpty)
                                TextButton(
                                  onPressed: () async {
                                    final confirm = await _confirmDialog(
                                      '清空短期记忆',
                                      '确定要清空所有短期对话记忆吗？这会删除后端保存的对话历史，AI 将失去近期上下文。',
                                    );
                                    if (confirm == true) {
                                      await MemoryService.clearShortTermBackend(
                                        roleId: _currentRole.id,
                                      );
                                      await reload(forceFullRefresh: true);
                                    }
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
                      child: loading
                          ? const Center(child: CircularProgressIndicator())
                          : items.isEmpty
                          ? const Center(
                              child: Text(
                                '暂无短期记忆',
                                style: TextStyle(color: Color(0xFF888888)),
                              ),
                            )
                          : ListView.builder(
                              controller: scrollController,
                              itemCount: items.length,
                              itemBuilder: (context, index) {
                                return _buildShortTermTile(
                                  items[index],
                                  () => reload(),
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

  Widget _buildShortTermTile(
    Map<String, dynamic> item,
    Future<void> Function() reload,
  ) {
    final id = item['id'] is int
        ? item['id'] as int
        : int.tryParse('${item['id']}') ?? -1;
    final role = '${item['role'] ?? ''}';
    final origin = '${item['origin'] ?? ''}';
    final message = MemoryService.extractShortTermMessage(item['content']);
    final isUser = role == 'user';
    final roleLabel = isUser ? '用户' : 'AI';

    return ListTile(
      leading: CircleAvatar(
        radius: 16,
        backgroundColor: isUser
            ? const Color(0xFF07C160)
            : const Color(0xFFBBBBBB),
        child: Text(
          roleLabel,
          style: const TextStyle(fontSize: 11, color: Colors.white),
        ),
      ),
      title: Text(message, maxLines: 4, overflow: TextOverflow.ellipsis),
      subtitle: origin.isNotEmpty && origin != 'zerochat'
          ? Text(
              origin,
              style: const TextStyle(fontSize: 12, color: Color(0xFFAAAAAA)),
            )
          : null,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.edit_outlined, color: Color(0xFF888888)),
            onPressed: id < 0
                ? null
                : () async {
                    final edited = await _editTextDialog('编辑短期记忆', message);
                    if (edited != null &&
                        edited.isNotEmpty &&
                        edited != message) {
                      final ok = await MemoryService.updateShortTermEntry(
                        id,
                        edited,
                        roleId: _currentRole.id,
                      );
                      if (ok) await reload();
                    }
                  },
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline, color: Colors.red),
            onPressed: id < 0
                ? null
                : () async {
                    await MemoryService.deleteShortTermEntry(
                      id,
                      roleId: _currentRole.id,
                    );
                    await reload();
                  },
          ),
        ],
      ),
    );
  }

  void _showVectorMemoryOptions() {
    List<Map<String, dynamic>> items = [];
    bool loading = true;

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
            Future<void> reload() async {
              final list = await MemoryService.listVectorMemories(
                roleId: _currentRole.id,
              );
              if (!mounted) return;
              setModalState(() {
                items = _sortMemoryDesc(list);
                loading = false;
              });
              setState(() {});
            }

            if (loading) {
              // 首次构建时触发加载
              reload();
            }

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
                            '向量记忆 (${items.length} 条)',
                            style: const TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          if (items.isNotEmpty)
                            TextButton(
                              onPressed: () async {
                                final confirm = await _confirmDialog(
                                  '清空向量记忆',
                                  '确定要清空所有向量记忆吗？这将删除 AI 自动生成的语义记忆。',
                                );
                                if (confirm == true) {
                                  await MemoryService.clearVectorMemory();
                                  await reload();
                                }
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
                      child: loading
                          ? const Center(child: CircularProgressIndicator())
                          : items.isEmpty
                          ? const Center(
                              child: Text(
                                'AI 会在对话中自动生成语义记忆\n暂无向量记忆',
                                textAlign: TextAlign.center,
                                style: TextStyle(color: Color(0xFF888888)),
                              ),
                            )
                          : ListView.builder(
                              controller: scrollController,
                              itemCount: items.length,
                              itemBuilder: (context, index) {
                                final item = items[index];
                                final id = item['id'] is int
                                    ? item['id'] as int
                                    : int.tryParse('${item['id']}') ?? -1;
                                final text = '${item['text'] ?? ''}';
                                final source = '${item['source'] ?? ''}';
                                return ListTile(
                                  title: Text(
                                    text,
                                    maxLines: 3,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  subtitle: source.isNotEmpty
                                      ? Text(
                                          source,
                                          style: const TextStyle(
                                            fontSize: 12,
                                            color: Color(0xFFAAAAAA),
                                          ),
                                        )
                                      : null,
                                  trailing: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      IconButton(
                                        icon: const Icon(
                                          Icons.edit_outlined,
                                          color: Color(0xFF888888),
                                        ),
                                        onPressed: id < 0
                                            ? null
                                            : () async {
                                                final edited =
                                                    await _editTextDialog(
                                                      '编辑向量记忆',
                                                      text,
                                                    );
                                                if (edited != null &&
                                                    edited.isNotEmpty &&
                                                    edited != text) {
                                                  final ok =
                                                      await MemoryService.updateVectorMemory(
                                                        id,
                                                        edited,
                                                        roleId: _currentRole.id,
                                                      );
                                                  if (ok) await reload();
                                                }
                                              },
                                      ),
                                      IconButton(
                                        icon: const Icon(
                                          Icons.delete_outline,
                                          color: Colors.red,
                                        ),
                                        onPressed: id < 0
                                            ? null
                                            : () async {
                                                await MemoryService.deleteVectorMemory(
                                                  id,
                                                  roleId: _currentRole.id,
                                                );
                                                await reload();
                                              },
                                      ),
                                    ],
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

  /// 通用确认对话框
  Future<bool?> _confirmDialog(String title, String content) {
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

  /// 通用文本编辑对话框
  Future<String?> _editTextDialog(String title, String initial) {
    final controller = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          maxLines: 5,
          minLines: 1,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
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
            final memories = _backendCoreMemory;

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
                                    await _persistCoreMemory(const <String>[]);
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
                                  trailing: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      IconButton(
                                        icon: const Icon(
                                          Icons.edit_outlined,
                                          color: Color(0xFF888888),
                                        ),
                                        onPressed: () => _editCoreMemory(
                                          index,
                                          memories[index],
                                          setModalState,
                                        ),
                                      ),
                                      IconButton(
                                        icon: const Icon(
                                          Icons.delete_outline,
                                          color: Colors.red,
                                        ),
                                        onPressed: () async {
                                          final newMemories = List<String>.from(
                                            memories,
                                          )..removeAt(index);
                                          await _persistCoreMemory(newMemories);
                                          setModalState(() {});
                                          setState(() {});
                                        },
                                      ),
                                    ],
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
      final newMemories = List<String>.from(_backendCoreMemory);
      if (!newMemories.contains(result)) {
        newMemories.add(result);
      }
      await _persistCoreMemory(newMemories);
      setModalState(() {});
      setState(() {});
    }
  }

  void _editCoreMemory(
    int index,
    String oldMemory,
    StateSetter setModalState,
  ) async {
    final controller = TextEditingController(text: oldMemory);

    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('编辑核心记忆'),
        content: TextField(
          controller: controller,
          maxLines: 3,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );

    if (result != null && result.isNotEmpty && result != oldMemory) {
      final newMemory = List<String>.from(_backendCoreMemory);
      newMemory[index] = result;
      await _persistCoreMemory(newMemory);
      setModalState(() {});
      setState(() {});
    }
  }

  /// 编辑核心记忆总结轮数（角色独立）
  void _editMemoryRounds() async {
    int value = _currentRole.summaryEveryNRounds;

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
      // 更新角色的总结轮数（角色独立设置）
      _currentRole = _currentRole.copyWith(summaryEveryNRounds: result);
      await RoleService.updateRole(_currentRole);
      setState(() {});
    }
  }

  void _confirmClearHistory() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空聊天记录'),
        content: const Text('确定要清空所有聊天记录吗？此操作不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () async {
              await MessageStore.instance.clearMessages(widget.chatId);
              MemoryService.clearShortTermMemory(widget.chatId);
              widget.onClearHistory?.call();
              Navigator.pop(context);
              Navigator.pop(context);
            },
            child: const Text('清空', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  void _openRoleSettings() async {
    final result = await Navigator.push<Role>(
      context,
      MaterialPageRoute(
        builder: (context) => RoleSettingsPage(role: _currentRole),
      ),
    );
    if (result != null) {
      await RoleService.updateRole(result);
      setState(() {
        _currentRole = result;
      });
      widget.onRoleChanged?.call();
    }
  }

  void _openEmojiManager() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => EmojiManagerPage(roleId: _currentRole.id),
      ),
    );
  }

  void _openTaskManager() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) =>
            TaskManagerPage(roleId: widget.chatId, roleName: _currentRole.name),
      ),
    ).then((_) => setState(() {})); // 刷新任务数量
  }

  // ========== 主动消息配置方法 ==========

  void _toggleProactiveMessage(bool enabled) async {
    // 先同步更新本地状态并重建，让开关立即响应；
    // 后端同步在后台进行，避免网络往返阻塞 UI。
    setState(() {
      _currentRole = _currentRole.copyWith(
        proactiveConfig: _currentRole.proactiveConfig.copyWith(enabled: enabled),
      );
    });
    await RoleService.updateRole(_currentRole);
  }

  void _editProactivePrompt() async {
    final controller = TextEditingController(
      text: _currentRole.proactiveConfig.triggerPrompt,
    );

    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('触发提示词'),
        content: TextField(
          controller: controller,
          maxLines: 5,
          decoration: const InputDecoration(
            hintText: '例如：请你模拟角色，给用户发消息...',
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
            child: const Text('保存'),
          ),
        ],
      ),
    );

    if (result != null && result.isNotEmpty) {
      _currentRole = _currentRole.copyWith(
        proactiveConfig: _currentRole.proactiveConfig.copyWith(
          triggerPrompt: result,
        ),
      );
      await RoleService.updateRole(_currentRole);
      setState(() {});
    }
  }

  void _editProactiveCountdown() async {
    final result = await showDialog<CountdownIntervalResult>(
      context: context,
      builder: (context) => CountdownIntervalDialog(
        initialMinMinutes: _currentRole.proactiveConfig.minIntervalMinutes,
        initialMaxMinutes: _currentRole.proactiveConfig.maxIntervalMinutes,
      ),
    );

    if (result != null) {
      _currentRole = _currentRole.copyWith(
        proactiveConfig: _currentRole.proactiveConfig.copyWith(
          minIntervalMinutes: result.minMinutes,
          maxIntervalMinutes: result.maxMinutes,
        ),
      );
      await RoleService.updateRole(_currentRole);
      setState(() {});
    }
  }

  String _formatProactiveInterval(ProactiveConfig config) {
    final minMinutes = config.minIntervalMinutes;
    final maxMinutes = config.maxIntervalMinutes;
    if (minMinutes >= 60 &&
        maxMinutes >= 60 &&
        minMinutes % 6 == 0 &&
        maxMinutes % 6 == 0) {
      String formatHours(int minutes) {
        final value = minutes / 60;
        return value == value.roundToDouble()
            ? value.toInt().toString()
            : value.toStringAsFixed(1);
      }

      return '${formatHours(minMinutes)}-${formatHours(maxMinutes)} 小时';
    }
    return '$minMinutes-$maxMinutes 分钟';
  }

  /// 导入外挂 JSON 文件
  void _importJsonFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json', 'txt'],
      );
      if (result == null || result.files.single.path == null) return;

      final file = File(result.files.single.path!);
      final content = await file.readAsString();

      if (content.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('文件内容为空')));
        }
        return;
      }

      // 更新角色
      final updated = _currentRole.copyWith(attachedJsonContent: content);
      await RoleService.updateRole(updated);
      setState(() {
        _currentRole = updated;
      });
      widget.onRoleChanged?.call();

      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('已导入 ${content.length} 字的记录')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('导入失败：$e')));
      }
    }
  }

  /// 清除外挂 JSON
  void _clearAttachedJson() async {
    final updated = _currentRole.copyWith(attachedJsonContent: '');
    // 设为空字符串后再设为 null
    final cleared = Role(
      id: updated.id,
      name: updated.name,
      description: updated.description,
      systemPrompt: updated.systemPrompt,
      avatarUrl: updated.avatarUrl,
      aiModel: updated.aiModel,
      aiApiUrl: updated.aiApiUrl,
      aiApiKey: updated.aiApiKey,
      aiTemperature: updated.aiTemperature,
      gender: updated.gender,
      menstruationCycle: updated.menstruationCycle,
      temperature: updated.temperature,
      topP: updated.topP,
      frequencyPenalty: updated.frequencyPenalty,
      presencePenalty: updated.presencePenalty,
      maxContextRounds: updated.maxContextRounds,
      allowWebSearch: updated.allowWebSearch,
      coreMemory: updated.coreMemory,
      summaryEveryNRounds: updated.summaryEveryNRounds,
      proactiveConfig: updated.proactiveConfig,
      stickerConfig: updated.stickerConfig,
    );
    await RoleService.updateRole(cleared);
    setState(() {
      _currentRole = cleared;
    });
    widget.onRoleChanged?.call();
  }

  /// 显示外挂 JSON 选项
  void _showAttachedJsonOptions() {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.file_upload),
              title: const Text('导入 JSON 文件'),
              subtitle: const Text('选择 .json 或 .txt 文件作为外挂记录'),
              onTap: () {
                Navigator.pop(ctx);
                _importJsonFile();
              },
            ),
            if (_currentRole.attachedJsonContent != null) ...[
              ListTile(
                leading: const Icon(Icons.visibility),
                title: const Text('查看内容'),
                subtitle: Text('${_currentRole.attachedJsonContent!.length} 字'),
                onTap: () {
                  Navigator.pop(ctx);
                  _showAttachedJsonContent();
                },
              ),
              ListTile(
                leading: const Icon(Icons.delete_outline, color: Colors.red),
                title: const Text(
                  '清除外挂记录',
                  style: TextStyle(color: Colors.red),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  _clearAttachedJson();
                },
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 显示外挂 JSON 内容
  void _showAttachedJsonContent() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => Container(
        height: MediaQuery.of(ctx).size.height * 0.7,
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '外挂记录内容',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              '共 ${_currentRole.attachedJsonContent?.length ?? 0} 字（只读）',
              style: const TextStyle(color: Color(0xFF888888), fontSize: 13),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: SingleChildScrollView(
                child: Text(
                  _currentRole.attachedJsonContent ?? '',
                  style: const TextStyle(fontSize: 14, fontFamily: 'monospace'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
