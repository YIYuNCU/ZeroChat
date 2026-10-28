import 'package:flutter/material.dart';
import '../models/role.dart';
import '../services/role_service.dart';
import '../services/group_chat_service.dart';
import '../services/chat_list_service.dart';
import '../widgets/member_avatars.dart';

/// 创建群聊页面
/// 选择多个角色创建群聊
class CreateGroupPage extends StatefulWidget {
  const CreateGroupPage({super.key});

  @override
  State<CreateGroupPage> createState() => _CreateGroupPageState();
}

class _CreateGroupPageState extends State<CreateGroupPage> {
  static const int _minMembers = 2;
  static const Color _green = Color(0xFF07C160);

  /// 保持选择顺序，已选条按点选先后排列。
  final List<String> _selectedIds = [];
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _searchController = TextEditingController();
  List<Role> _roles = [];
  String _keyword = '';
  bool _creating = false;

  bool get _canCreate => _selectedIds.length >= _minMembers && !_creating;

  @override
  void initState() {
    super.initState();
    // 工具角色是内部角色、归档角色不再参与聊天，都不应出现在可选成员里。
    _roles = RoleService.getAllRoles()
        .where((r) => !RoleService.isToolRoleId(r.id) && !r.archived)
        .toList();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  List<Role> get _filteredRoles {
    final keyword = _keyword.trim().toLowerCase();
    if (keyword.isEmpty) return _roles;
    return _roles
        .where(
          (r) =>
              r.name.toLowerCase().contains(keyword) ||
              r.description.toLowerCase().contains(keyword),
        )
        .toList();
  }

  Role? _roleById(String id) {
    for (final role in _roles) {
      if (role.id == id) return role;
    }
    return null;
  }

  void _toggle(Role role) {
    setState(() {
      if (!_selectedIds.remove(role.id)) {
        _selectedIds.add(role.id);
      }
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
        title: const Text('发起群聊'),
        leading: IconButton(
          onPressed: () => Navigator.pop(context),
          icon: const Icon(Icons.arrow_back_ios, size: 20),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Center(child: _buildConfirmButton()),
          ),
        ],
      ),
      body: Column(
        children: [
          _buildNameField(),
          _buildSelectedStrip(),
          _buildSearchField(),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                _selectedIds.length < _minMembers
                    ? '至少选择 $_minMembers 个角色（已选 ${_selectedIds.length}）'
                    : '已选择 ${_selectedIds.length} 个角色',
                style: const TextStyle(fontSize: 13, color: Color(0xFF888888)),
              ),
            ),
          ),
          Expanded(child: _buildRoleList()),
        ],
      ),
    );
  }

  Widget _buildConfirmButton() {
    final enabled = _canCreate;
    return Material(
      color: enabled ? _green : const Color(0xFFD8D8D8),
      borderRadius: BorderRadius.circular(4),
      child: InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: enabled ? _createGroup : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: _creating
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : Text(
                  '完成(${_selectedIds.length})',
                  style: TextStyle(
                    fontSize: 14,
                    color: enabled ? Colors.white : const Color(0xFF999999),
                  ),
                ),
        ),
      ),
    );
  }

  Widget _buildNameField() {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: TextField(
        controller: _nameController,
        maxLength: 20,
        textInputAction: TextInputAction.done,
        decoration: const InputDecoration(
          labelText: '群聊名称',
          hintText: '选填，默认为成员名称组合',
          counterText: '',
          prefixIcon: Icon(Icons.edit_outlined, size: 20),
          border: UnderlineInputBorder(),
          focusedBorder: UnderlineInputBorder(
            borderSide: BorderSide(color: _green, width: 1.5),
          ),
          floatingLabelStyle: TextStyle(color: _green),
        ),
      ),
    );
  }

  /// 已选成员横条：点击头像即可取消，避免在长列表里来回找。
  Widget _buildSelectedStrip() {
    if (_selectedIds.isEmpty) return const SizedBox.shrink();
    return Container(
      color: Colors.white,
      margin: const EdgeInsets.only(top: 8),
      height: 72,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        itemCount: _selectedIds.length,
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (context, index) {
          final role = _roleById(_selectedIds[index]);
          if (role == null) return const SizedBox.shrink();
          return Tooltip(
            message: '移除 ${role.name}',
            child: GestureDetector(
              onTap: () => _toggle(role),
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  RoleAvatar(role: role, size: 52),
                  Positioned(
                    right: -4,
                    top: -4,
                    child: Container(
                      width: 16,
                      height: 16,
                      decoration: const BoxDecoration(
                        color: Color(0xFFB0B0B0),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.close,
                        size: 11,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildSearchField() {
    return Container(
      color: Colors.white,
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: TextField(
        controller: _searchController,
        onChanged: (v) => setState(() => _keyword = v),
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          hintText: '搜索角色',
          isDense: true,
          filled: true,
          fillColor: const Color(0xFFF2F2F2),
          prefixIcon: const Icon(Icons.search, size: 20),
          suffixIcon: _keyword.isEmpty
              ? null
              : IconButton(
                  tooltip: '清除',
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () {
                    _searchController.clear();
                    setState(() => _keyword = '');
                  },
                ),
          contentPadding: const EdgeInsets.symmetric(vertical: 10),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: BorderSide.none,
          ),
        ),
      ),
    );
  }

  Widget _buildRoleList() {
    final roles = _filteredRoles;
    if (roles.isEmpty) {
      return Center(
        child: Text(
          _roles.isEmpty ? '暂无可选角色' : '没有匹配的角色',
          style: const TextStyle(fontSize: 14, color: Color(0xFF999999)),
        ),
      );
    }
    return ListView.builder(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).padding.bottom),
      itemCount: roles.length,
      itemBuilder: (context, index) => _buildRoleRow(roles[index]),
    );
  }

  Widget _buildRoleRow(Role role) {
    final isSelected = _selectedIds.contains(role.id);
    return Material(
      color: Colors.white,
      child: InkWell(
        onTap: () => _toggle(role),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: const BoxDecoration(
            border: Border(
              bottom: BorderSide(color: Color(0xFFEEEEEE), width: 0.5),
            ),
          ),
          child: Row(
            children: [
              Icon(
                isSelected ? Icons.check_circle : Icons.radio_button_unchecked,
                color: isSelected ? _green : const Color(0xFFCCCCCC),
                size: 22,
              ),
              const SizedBox(width: 12),
              RoleAvatar(role: role, size: 40),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      role.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 16),
                    ),
                    if (role.description.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          role.description,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 13,
                            color: Color(0xFF888888),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _createGroup() async {
    if (!_canCreate) return;
    setState(() => _creating = true);

    try {
      final selectedRoles = _selectedIds
          .map(_roleById)
          .whereType<Role>()
          .toList();
      final customName = _nameController.text.trim();
      final groupName = customName.isNotEmpty
          ? customName
          : selectedRoles.map((r) => r.name).take(3).join('、') +
                (selectedRoles.length > 3 ? '...' : '');

      final group = await GroupChatService.createGroup(
        name: groupName,
        memberIds: List<String>.of(_selectedIds),
      );

      ChatListService.instance.getOrCreateChat(
        id: group.id,
        name: group.name,
        isGroup: true,
        memberIds: group.memberIds,
      );

      if (mounted) {
        Navigator.pop(context, true);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _creating = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('创建群聊失败，请重试')));
    }
  }
}
