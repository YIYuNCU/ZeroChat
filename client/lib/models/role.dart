import 'dart:convert';
import 'onebot_config.dart';
import 'proactive_config.dart';
import 'followup_config.dart';
import 'stats_config.dart';
import 'sticker.dart';

/// 角色模型
/// 用于 AI 角色的人设配置和参数设置
class Role {
  final String id;
  final String name;
  final String description;
  final String systemPrompt;
  final String? avatarUrl;
  final String? avatarHash;
  final String chatBackgroundUrl;

  final String aiModel;
  final String aiApiUrl;
  final String aiApiKey;
  final double aiTemperature;
  final String gender;
  final Map<String, dynamic> menstruationCycle;

  // AI 参数
  final double temperature;
  final double topP;
  final double frequencyPenalty;
  final double presencePenalty;
  final int maxContextRounds;
  final bool allowWebSearch;

  // 外挂 JSON 记录内容（只读，注入到聊天上下文）
  final String? attachedJsonContent;

  // 角色专属核心记忆
  final List<String> coreMemory;

  // 核心记忆总结轮数（角色独立）
  final int summaryEveryNRounds;

  // 主动消息配置（角色独立）
  final ProactiveConfig proactiveConfig;

  // 无回复续写配置（角色独立）
  final FollowupConfig followupConfig;

  // 表情包配置（角色独立）
  final StickerConfig stickerConfig;

  // OneBot V11 接口配置（角色独立）
  final OneBotConfig onebotConfig;

  // 数值系统配置（角色独立）
  final StatsConfig statsConfig;

  // 消息部分显隐（对话始终显示）
  final bool showAction;
  final bool showPsychology;
  final bool showStats;
  final bool showNoReply;

  // 是否已归档：归档后不能对话、不发朋友圈、不发主动消息
  final bool archived;

  final DateTime createdAt;
  final DateTime updatedAt;

  Role({
    required this.id,
    required this.name,
    this.description = '',
    required this.systemPrompt,
    this.avatarUrl,
    this.avatarHash,
    this.chatBackgroundUrl = '',
    this.aiModel = 'deepseek-chat',
    this.aiApiUrl = '',
    this.aiApiKey = '',
    this.aiTemperature = 0.7,
    this.gender = 'men',
    Map<String, dynamic>? menstruationCycle,
    this.temperature = 0.7,
    this.topP = 1.0,
    this.frequencyPenalty = 0.0,
    this.presencePenalty = 0.0,
    this.maxContextRounds = 60,
    this.allowWebSearch = true,
    this.attachedJsonContent,
    List<String>? coreMemory,
    this.summaryEveryNRounds = 20,
    ProactiveConfig? proactiveConfig,
    FollowupConfig? followupConfig,
    StickerConfig? stickerConfig,
    OneBotConfig? onebotConfig,
    StatsConfig? statsConfig,
    this.showAction = true,
    this.showPsychology = true,
    this.showStats = true,
    this.showNoReply = false,
    this.archived = false,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) : coreMemory = coreMemory ?? [],
       menstruationCycle =
           menstruationCycle ??
           const {
             'cycle_length': 30,
             'period_length': 6,
             'last_period_start': '2026-01-24',
           },
       proactiveConfig = proactiveConfig ?? const ProactiveConfig(),
       followupConfig = followupConfig ?? const FollowupConfig(),
       stickerConfig = stickerConfig ?? const StickerConfig(),
       onebotConfig = onebotConfig ?? const OneBotConfig(),
       statsConfig = statsConfig ?? const StatsConfig(),
       createdAt = createdAt ?? DateTime.now(),
       updatedAt = updatedAt ?? DateTime.now();

  /// 创建默认角色
  factory Role.defaultRole() {
    return Role(
      id: 'default',
      name: 'AI 助手',
      description: '默认的 AI 助手角色',
      systemPrompt: '你是一个友好、有帮助的 AI 助手。请用中文回答问题。',
      gender: 'men',
    );
  }

  /// 复制并修改
  Role copyWith({
    String? id,
    String? name,
    String? description,
    String? systemPrompt,
    String? avatarUrl,
    String? avatarHash,
    String? chatBackgroundUrl,
    String? aiModel,
    String? aiApiUrl,
    String? aiApiKey,
    double? aiTemperature,
    String? gender,
    Map<String, dynamic>? menstruationCycle,
    double? temperature,
    double? topP,
    double? frequencyPenalty,
    double? presencePenalty,
    int? maxContextRounds,
    bool? allowWebSearch,
    String? attachedJsonContent,
    List<String>? coreMemory,
    int? summaryEveryNRounds,
    ProactiveConfig? proactiveConfig,
    FollowupConfig? followupConfig,
    StickerConfig? stickerConfig,
    OneBotConfig? onebotConfig,
    StatsConfig? statsConfig,
    bool? showAction,
    bool? showPsychology,
    bool? showStats,
    bool? showNoReply,
    bool? archived,
    DateTime? updatedAt,
  }) {
    return Role(
      id: id ?? this.id,
      name: name ?? this.name,
      description: description ?? this.description,
      systemPrompt: systemPrompt ?? this.systemPrompt,
      avatarUrl: avatarUrl ?? this.avatarUrl,
      avatarHash: avatarHash ?? this.avatarHash,
      chatBackgroundUrl: chatBackgroundUrl ?? this.chatBackgroundUrl,
      aiModel: aiModel ?? this.aiModel,
      aiApiUrl: aiApiUrl ?? this.aiApiUrl,
      aiApiKey: aiApiKey ?? this.aiApiKey,
      aiTemperature: aiTemperature ?? this.aiTemperature,
      gender: gender ?? this.gender,
      menstruationCycle: menstruationCycle ?? this.menstruationCycle,
      temperature: temperature ?? this.temperature,
      topP: topP ?? this.topP,
      frequencyPenalty: frequencyPenalty ?? this.frequencyPenalty,
      presencePenalty: presencePenalty ?? this.presencePenalty,
      maxContextRounds: maxContextRounds ?? this.maxContextRounds,
      allowWebSearch: allowWebSearch ?? this.allowWebSearch,
      attachedJsonContent: attachedJsonContent ?? this.attachedJsonContent,
      coreMemory: coreMemory ?? this.coreMemory,
      summaryEveryNRounds: summaryEveryNRounds ?? this.summaryEveryNRounds,
      proactiveConfig: proactiveConfig ?? this.proactiveConfig,
      followupConfig: followupConfig ?? this.followupConfig,
      stickerConfig: stickerConfig ?? this.stickerConfig,
      onebotConfig: onebotConfig ?? this.onebotConfig,
      statsConfig: statsConfig ?? this.statsConfig,
      showAction: showAction ?? this.showAction,
      showPsychology: showPsychology ?? this.showPsychology,
      showStats: showStats ?? this.showStats,
      showNoReply: showNoReply ?? this.showNoReply,
      archived: archived ?? this.archived,
      createdAt: createdAt,
      updatedAt: updatedAt ?? DateTime.now(),
    );
  }

  /// 添加核心记忆
  Role addCoreMemory(String memory) {
    final newMemory = List<String>.from(coreMemory);
    if (!newMemory.contains(memory)) {
      newMemory.add(memory);
    }
    return copyWith(coreMemory: newMemory, updatedAt: DateTime.now());
  }

  /// 添加多条核心记忆
  Role addCoreMemories(List<String> memories) {
    final newMemory = List<String>.from(coreMemory);
    for (final memory in memories) {
      if (!newMemory.contains(memory) && memory.isNotEmpty) {
        newMemory.add(memory);
      }
    }
    return copyWith(coreMemory: newMemory, updatedAt: DateTime.now());
  }

  /// 清空核心记忆
  Role clearCoreMemory() {
    return copyWith(coreMemory: [], updatedAt: DateTime.now());
  }

  /// 删除单条核心记忆
  Role removeCoreMemory(int index) {
    if (index < 0 || index >= coreMemory.length) return this;
    final newMemory = List<String>.from(coreMemory);
    newMemory.removeAt(index);
    return copyWith(coreMemory: newMemory, updatedAt: DateTime.now());
  }

  factory Role.fromJson(Map<String, dynamic> json) {
    return Role(
      id: json['id'] as String,
      name: json['name'] as String,
      description: json['description'] as String? ?? '',
      systemPrompt: json['system_prompt'] as String,
      avatarUrl: json['avatar_url'] as String?,
      avatarHash: json['avatar_hash'] as String?,
      chatBackgroundUrl: json['chat_background_url'] as String? ?? '',
      aiModel: json['ai_model'] as String? ?? 'deepseek-chat',
      aiApiUrl: json['ai_api_url'] as String? ?? '',
      aiApiKey: json['ai_api_key'] as String? ?? '',
      aiTemperature:
          (json['ai_temperature'] as num?)?.toDouble() ??
          (json['temperature'] as num?)?.toDouble() ??
          0.7,
      gender: json['gender'] as String? ?? 'men',
      menstruationCycle:
          (json['menstruation_cycle'] as Map<String, dynamic>?) ??
          const {
            'cycle_length': 30,
            'period_length': 6,
            'last_period_start': '2026-01-24',
          },
      temperature:
          (json['temperature'] as num?)?.toDouble() ??
          (json['ai_temperature'] as num?)?.toDouble() ??
          0.7,
      topP: (json['top_p'] as num?)?.toDouble() ?? 1.0,
      frequencyPenalty: (json['frequency_penalty'] as num?)?.toDouble() ?? 0.0,
      presencePenalty: (json['presence_penalty'] as num?)?.toDouble() ?? 0.0,
      maxContextRounds: json['max_context_rounds'] as int? ?? 60,
      allowWebSearch: json['allow_web_search'] as bool? ?? true,
      attachedJsonContent: json['attached_json_content'] as String?,
      coreMemory: (json['core_memory'] as List<dynamic>?)?.cast<String>() ?? [],
      summaryEveryNRounds: json['summary_every_n_rounds'] as int? ?? 20,
      proactiveConfig: json['proactive_config'] != null
          ? ProactiveConfig.fromJson(
              json['proactive_config'] as Map<String, dynamic>,
            )
          : const ProactiveConfig(),
      followupConfig: json['followup_config'] != null
          ? FollowupConfig.fromJson(
              json['followup_config'] as Map<String, dynamic>,
            )
          : const FollowupConfig(),
      stickerConfig: json['sticker_config'] != null
          ? StickerConfig.fromJson(
              json['sticker_config'] as Map<String, dynamic>,
            )
          : const StickerConfig(),
      onebotConfig: json['onebot_config'] != null
          ? OneBotConfig.fromJson(
              json['onebot_config'] as Map<String, dynamic>,
            )
          : const OneBotConfig(),
      statsConfig: json['stats_config'] != null
          ? StatsConfig.fromJson(
              json['stats_config'] as Map<String, dynamic>,
            )
          : const StatsConfig(),
      showAction: json['show_action'] as bool? ?? true,
      showPsychology: json['show_psychology'] as bool? ?? true,
      showStats: json['show_stats'] as bool? ?? true,
      showNoReply: json['show_no_reply'] as bool? ?? false,
      archived: json['archived'] as bool? ?? false,
      createdAt: json['created_at'] != null
          ? DateTime.parse(json['created_at'] as String)
          : DateTime.now(),
      updatedAt: json['updated_at'] != null
          ? DateTime.parse(json['updated_at'] as String)
          : DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'description': description,
      'system_prompt': systemPrompt,
      'avatar_url': avatarUrl,
      'avatar_hash': avatarHash,
      'chat_background_url': chatBackgroundUrl,
      'ai_model': aiModel,
      'ai_api_url': aiApiUrl,
      'ai_api_key': aiApiKey,
      'ai_temperature': aiTemperature,
      'gender': gender,
      'menstruation_cycle': menstruationCycle,
      'temperature': temperature,
      'top_p': topP,
      'frequency_penalty': frequencyPenalty,
      'presence_penalty': presencePenalty,
      'max_context_rounds': maxContextRounds,
      'allow_web_search': allowWebSearch,
      'attached_json_content': attachedJsonContent,
      'core_memory': coreMemory,
      'summary_every_n_rounds': summaryEveryNRounds,
      'proactive_config': proactiveConfig.toJson(),
      'followup_config': followupConfig.toJson(),
      'sticker_config': stickerConfig.toJson(),
      'onebot_config': onebotConfig.toJson(),
      'stats_config': statsConfig.toJson(),
      'show_action': showAction,
      'show_psychology': showPsychology,
      'show_stats': showStats,
      'show_no_reply': showNoReply,
      'archived': archived,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  String toJsonString() => jsonEncode(toJson());

  static Role fromJsonString(String jsonStr) =>
      Role.fromJson(jsonDecode(jsonStr));
}
