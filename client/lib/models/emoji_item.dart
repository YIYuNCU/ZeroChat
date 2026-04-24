class EmojiItem {
  final String id;
  final String category;
  final String url;
  final String? tag;
  final String? filename;
  final bool isAi;

  const EmojiItem({
    required this.id,
    required this.category,
    required this.url,
    this.tag,
    this.filename,
    required this.isAi,
  });

  factory EmojiItem.fromAiJson(Map<String, dynamic> json) {
    return EmojiItem(
      id: (json['id'] ?? '').toString(),
      category: (json['category'] ?? '').toString(),
      url: (json['url'] ?? '').toString(),
      filename: json['filename']?.toString(),
      isAi: true,
    );
  }

  factory EmojiItem.fromUserJson(Map<String, dynamic> json) {
    return EmojiItem(
      id: (json['id'] ?? '').toString(),
      category: (json['category'] ?? '').toString(),
      url: (json['url'] ?? '').toString(),
      tag: json['tag']?.toString(),
      filename: json['filename']?.toString(),
      isAi: false,
    );
  }
}
