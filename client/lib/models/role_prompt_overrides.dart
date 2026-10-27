import 'ai_model_profile.dart' show normalizePromptOverrides;

/// 角色 `metadata` 中存放按角色提示词覆盖的 key。
///
/// 结构与全局覆盖相同：`{prompt_id: {"__builtin__": 全文, "__base_version__": "<int>"}}`。
/// 服务端 `RoleUpdate.metadata` 是整体替换，所以写入时必须保留其他 key。
const String rolePromptOverridesMetadataKey = 'prompt_overrides';

/// 读取角色 metadata 里的按角色提示词覆盖；结构不正确的条目会被忽略。
Map<String, Map<String, String>> readRolePromptOverrides(
  Map<String, dynamic> metadata,
) => normalizePromptOverrides(metadata[rolePromptOverridesMetadataKey]);

/// 读取单个提示词在该角色上的覆盖（没有则返回空映射）。
Map<String, String> readRolePromptOverride(
  Map<String, dynamic> metadata,
  String promptId,
) => readRolePromptOverrides(metadata)[promptId] ?? const <String, String>{};

/// 返回写入某个提示词覆盖后的新 metadata（不修改入参）。
///
/// - `override` 为空映射：删除该提示词的覆盖；
/// - 删除后 `prompt_overrides` 为空：从 metadata 中移除该 key；
/// - metadata 里其他 key（以及其他提示词的覆盖）保持不变。
Map<String, dynamic> writeRolePromptOverride(
  Map<String, dynamic> metadata,
  String promptId,
  Map<String, String> override,
) {
  final next = Map<String, dynamic>.of(metadata);
  final overrides = <String, Map<String, String>>{
    for (final entry in readRolePromptOverrides(metadata).entries)
      entry.key: Map<String, String>.of(entry.value),
  };
  if (override.isEmpty) {
    overrides.remove(promptId);
  } else {
    overrides[promptId] = Map<String, String>.of(override);
  }
  if (overrides.isEmpty) {
    next.remove(rolePromptOverridesMetadataKey);
  } else {
    next[rolePromptOverridesMetadataKey] = overrides;
  }
  return next;
}
