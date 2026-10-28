import 'dart:io';

import 'package:flutter/material.dart';

import '../models/group_chat.dart';
import '../models/role.dart';
import '../services/role_service.dart';
import 'smart_avatar_image.dart';

/// 角色头像：有远程头像时显示图片，否则显示名称首字的彩色方块。
/// 群聊相关页面（建群、群设置、通讯录、聊天列表）共用，避免各页重复实现。
class RoleAvatar extends StatelessWidget {
  final Role role;
  final double size;
  final double radius;

  const RoleAvatar({
    super.key,
    required this.role,
    this.size = 40,
    this.radius = 4,
  });

  static const List<Color> _palette = [
    Color(0xFF7EB7E7),
    Color(0xFF95EC69),
    Color(0xFFFFB347),
    Color(0xFFFF7B7B),
    Color(0xFFB19CD9),
  ];

  static Color colorFor(String name) =>
      _palette[name.hashCode.abs() % _palette.length];

  @override
  Widget build(BuildContext context) {
    final url = role.avatarUrl;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox(
        width: size,
        height: size,
        child: url != null && url.isNotEmpty
            ? SmartAvatarImage(
                remoteUrl: url,
                cacheKey: 'role_${role.id}_avatar',
                backendHash: role.avatarHash,
                width: size,
                height: size,
                fit: BoxFit.cover,
                fallbackBuilder: _buildFallback,
              )
            : _buildFallback(),
      ),
    );
  }

  Widget _buildFallback() {
    return Container(
      width: size,
      height: size,
      color: colorFor(role.name),
      alignment: Alignment.center,
      child: Text(
        role.name.isNotEmpty ? role.name[0].toUpperCase() : '?',
        style: TextStyle(
          color: Colors.white,
          fontSize: size * 0.45,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

/// 群头像：设置了自定义头像时显示该图片，否则把前 9 位成员的头像拼成宫格
/// （类似微信群头像）。成员无法解析时退化为群图标。
class GroupAvatar extends StatelessWidget {
  final List<String> memberIds;

  /// 自定义头像的本地文件路径；文件丢失时自动回退到成员宫格。
  final String? customAvatarPath;
  final double size;
  final double radius;

  const GroupAvatar({
    super.key,
    required this.memberIds,
    this.customAvatarPath,
    this.size = 48,
    this.radius = 4,
  });

  GroupAvatar.forGroup(
    GroupChat group, {
    Key? key,
    double size = 48,
    double radius = 4,
  }) : this(
         key: key,
         memberIds: group.memberIds,
         customAvatarPath: group.avatarUrl,
         size: size,
         radius: radius,
       );

  static const double _padding = 2;
  static const double _gap = 1.5;

  @override
  Widget build(BuildContext context) {
    final roles = memberIds
        .map(RoleService.getRoleById)
        .whereType<Role>()
        .take(9)
        .toList();
    final fallback = roles.isEmpty ? _buildIcon() : _buildGrid(roles);
    final custom = customAvatarPath;

    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Container(
        width: size,
        height: size,
        color: const Color(0xFFD9D9D9),
        child: custom != null && custom.isNotEmpty
            ? Image.file(
                File(custom),
                key: ValueKey(custom),
                width: size,
                height: size,
                fit: BoxFit.cover,
                cacheWidth: (size * MediaQuery.devicePixelRatioOf(context))
                    .round(),
                errorBuilder: (_, _, _) => fallback,
              )
            : fallback,
      ),
    );
  }

  Widget _buildIcon() {
    return Container(
      color: const Color(0xFF07C160),
      alignment: Alignment.center,
      child: Icon(Icons.group, color: Colors.white, size: size * 0.5),
    );
  }

  Widget _buildGrid(List<Role> roles) {
    final columns = roles.length == 1
        ? 1
        : roles.length <= 4
        ? 2
        : 3;
    final inner = size - _padding * 2;
    final cell = ((inner - _gap * (columns - 1)) / columns).floorToDouble();

    return Padding(
      padding: const EdgeInsets.all(_padding),
      child: Wrap(
        alignment: WrapAlignment.center,
        runAlignment: WrapAlignment.center,
        spacing: _gap,
        runSpacing: _gap,
        children: [
          for (final role in roles)
            RoleAvatar(role: role, size: cell, radius: 1.5),
        ],
      ),
    );
  }
}
