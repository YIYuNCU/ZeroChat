/// 用户模型
/// 用于表示应用中的用户
class User {
  final String id;
  final String nickname;
  final String? avatarUrl;
  final String? signature;
  final DateTime? lastOnline;

  User({
    required this.id,
    required this.nickname,
    this.avatarUrl,
    this.signature,
    this.lastOnline,
  });

  factory User.fromJson(Map<String, dynamic> json) {
    return User(
      id: json['id'] as String,
      nickname: json['nickname'] as String,
      avatarUrl: json['avatar_url'] as String?,
      signature: json['signature'] as String?,
      lastOnline: json['last_online'] != null
          ? DateTime.parse(json['last_online'] as String)
          : null,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'nickname': nickname,
      'avatar_url': avatarUrl,
      'signature': signature,
      'last_online': lastOnline?.toIso8601String(),
    };
  }
}
