# Core Module Documentation

本文件描述 core 目录的职责与各文件的函数说明，包含：函数名、参数、作用、返回值、调用者。

## chat_controller.dart

功能说明：聊天核心引擎，统一负责消息流转、AI 调度、分段发送、群聊逻辑、记忆触发与通知更新；UI 层不应直接调用 AI、记忆或分段逻辑。

### Functions

- ChatController.init()
  - 参数：无
  - 作用：初始化消息存储
  - 返回：Future<void>
  - 调用者：应用初始化流程（外部模块）

- ChatController.initChat(String chatId, {bool isGroup=false, List<String>? memberIds})
  - 参数：chatId、isGroup、memberIds
  - 作用：确保消息加载，建立或更新 ChatContext，刷新流
  - 返回：Future<ChatContext>
  - 调用者：_sendBatchedMessages()、sendUserImageMessage()、createGroupChat()、外部聊天页进入流程

- ChatController.getContext(String chatId)
  - 参数：chatId
  - 作用：获取已缓存的上下文
  - 返回：ChatContext?
  - 调用者：外部模块（UI/服务）

- ChatController.getMessageCount(String chatId)
  - 参数：chatId
  - 作用：读取 MessageStore 的消息总数
  - 返回：int
  - 调用者：onChatPageEnter()、外部模块

- ChatController.createMessage({required String senderId, required String receiverId, required String content, Message? quotedMessage})
  - 参数：senderId、receiverId、content、quotedMessage
  - 作用：统一构建消息对象（含引用）
  - 返回：Message
  - 调用者：sendUserMessage()、_callAI()错误分支、外部模块可能复用

- ChatController.sendUserMessage(String chatId, String content, {Message? quotedMessage})
  - 参数：chatId、content、quotedMessage
  - 作用：写入用户消息，合并等待后批量发送
  - 返回：Future<void>
  - 调用者：外部模块（输入框/聊天页）

- ChatController._sendBatchedMessages(String chatId)
  - 参数：chatId
  - 作用：合并队列消息，更新上下文，触发记忆总结，异步处理单聊/群聊
  - 返回：Future<void>
  - 调用者：sendUserMessage()定时器回调、sendUserMessage()等待时间为 0 时直接调用

- ChatController.sendUserImageMessage(String chatId, String imagePath)
  - 参数：chatId、imagePath
  - 作用：写入图片消息并触发图像理解回复
  - 返回：Future<void>
  - 调用者：外部模块（图片发送入口）

- ChatController._processImageMessageInBackground(String chatId, String imagePath, bool isGroup)
  - 参数：chatId、imagePath、isGroup
  - 作用：选择角色、调用 vision API，发送分段回复
  - 返回：Future<void>
  - 调用者：sendUserImageMessage()

- ChatController.sendUserMessageWithQuote(String chatId, String content, String quotedMessageId, String quotedContent)
  - 参数：chatId、content、quotedMessageId、quotedContent
  - 作用：根据 id 查找引用消息后发送
  - 返回：Future<void>
  - 调用者：外部模块（引用回复入口）

- ChatController._processMessageInBackground(String chatId, String content, bool isGroup)
  - 参数：chatId、content、isGroup
  - 作用：后台处理单聊或群聊，清理处理状态与聊天列表
  - 返回：void
  - 调用者：_sendBatchedMessages()

- ChatController.onChatPageEnter(String chatId)
  - 参数：chatId
  - 作用：加载消息、清未读、刷新流、同步角色数据
  - 返回：Future<void>
  - 调用者：外部模块（聊天页进入）

- ChatController.onChatPageExit(String chatId)
  - 参数：chatId
  - 作用：退出日志
  - 返回：void
  - 调用者：外部模块（聊天页退出）

- ChatController.markChatUnread(String chatId)
  - 参数：chatId
  - 作用：设置未读标记并通知聊天列表
  - 返回：void
  - 调用者：外部模块

- ChatController.deleteChatFromList(String chatId)
  - 参数：chatId
  - 作用：从聊天列表移除
  - 返回：void
  - 调用者：外部模块

- ChatController.deleteMessage(String chatId, String messageId)
  - 参数：chatId、messageId
  - 作用：删除指定消息
  - 返回：Future<void>
  - 调用者：外部模块（长按删除等）

- ChatController.sendScheduledTaskMessage({required String chatId, required String roleId, required String taskContent, String? customPrompt})
  - 参数：chatId、roleId、taskContent、customPrompt
  - 作用：为任务提醒生成 AI 内容并发送
  - 返回：Future<void>
  - 调用者：外部模块（TaskService 调用约定）

- ChatController.createGroupChat(List<String> roleIds, {String? name})
  - 参数：roleIds、name
  - 作用：创建群聊并写入列表与上下文
  - 返回：Future<String>（群聊 id）
  - 调用者：外部模块（建群入口）

- ChatController.registerTypingCallback(String chatId, void Function(bool) callback)
  - 参数：chatId、callback
  - 作用：注册单聊 typing 状态回调
  - 返回：void
  - 调用者：外部模块（聊天页）

- ChatController.unregisterTypingCallback(String chatId)
  - 参数：chatId
  - 作用：取消 typing 回调
  - 返回：void
  - 调用者：外部模块

- ChatController.isProcessing(String chatId)
  - 参数：chatId
  - 作用：判断该 chat 是否正在处理
  - 返回：bool
  - 调用者：外部模块

- ChatController._handleSingleChat(String chatId, String userMessage)
  - 参数：chatId、userMessage
  - 作用：意图识别 + 副作用 + AI 调用 + 分段发送
  - 返回：Future<void>
  - 调用者：_processMessageInBackground()

- ChatController._handleGroupChat(String chatId, String userMessage)
  - 参数：chatId、userMessage
  - 作用：群聊调度角色、多轮 AI 互动与发送
  - 返回：Future<void>
  - 调用者：_processMessageInBackground()

- ChatController._callAI({required String chatId, required Role role, required String userMessage, required bool isGroup})
  - 参数：chatId、role、userMessage、isGroup
  - 作用：优先后端，失败降级直连，注入历史/记忆/朋友圈上下文
  - 返回：Future<String?>
  - 调用者：_handleSingleChat()、_handleGroupChat()

- ChatController._sendSegmentsQueued(String chatId, String roleId, String rawReply, {required bool isGroup})
  - 参数：chatId、roleId、rawReply、isGroup
  - 作用：按分段发送消息，处理通知、未读、表情包
  - 返回：Future<void>
  - 调用者：_handleSingleChat()、_handleGroupChat()、sendScheduledTaskMessage()、_processImageMessageInBackground()

- ChatController._showTypingWithDelay(String chatId, {required bool isGroup})
  - 参数：chatId、isGroup
  - 作用：延迟设置 typing（群聊不显示）
  - 返回：Future<void>
  - 调用者：_handleSingleChat()、_processImageMessageInBackground()

- ChatController._hideTyping(String chatId)
  - 参数：chatId
  - 作用：关闭 typing
  - 返回：void
  - 调用者：_handleSingleChat()、_sendSegmentsQueued()、_processImageMessageInBackground()

- ChatController._setTyping(String chatId, bool isTyping)
  - 参数：chatId、isTyping
  - 作用：触发 typing 回调
  - 返回：void
  - 调用者：_showTypingWithDelay()、_hideTyping()、_sendSegmentsQueued()

- ChatController._updateChatList(String chatId)
  - 参数：chatId
  - 作用：刷新聊天列表的最后消息与时间
  - 返回：void
  - 调用者：_processMessageInBackground()、sendScheduledTaskMessage()、_processImageMessageInBackground()

- ChatController._getMessageDisplayText(Message message)
  - 参数：message
  - 作用：为聊天列表生成预览文本
  - 返回：String
  - 调用者：_updateChatList()

## group_scheduler.dart

功能说明：群聊发言调度器，根据概率与关键词匹配选出参与回复的角色，并提供回复延迟策略。

### Functions

- GroupScheduler.selectRespondingRoles({required List<String> memberIds, required String userMessage, String? lastSpeakerRoleId, Map<String,int>? consecutiveCounts, double replyProbability=0.6, int maxConsecutiveSpeaks=2})
  - 参数：memberIds、userMessage、lastSpeakerRoleId、consecutiveCounts、replyProbability、maxConsecutiveSpeaks
  - 作用：筛选可回复角色、应用关键词增益与随机选择
  - 返回：ScheduleResult
  - 调用者：ChatController._handleGroupChat()

- GroupScheduler._extractKeywords(String message)
  - 参数：message
  - 作用：基于触发词表提取关键词
  - 返回：Set<String>
  - 调用者：selectRespondingRoles()

- GroupScheduler._getRoleKeywords(Role role)
  - 参数：role
  - 作用：从角色名与描述匹配关键词
  - 返回：Set<String>
  - 调用者：selectRespondingRoles()

- GroupScheduler._hasKeywordMatch(Set<String> messageKeywords, Set<String> roleKeywords)
  - 参数：messageKeywords、roleKeywords
  - 作用：判断是否有交集
  - 返回：bool
  - 调用者：selectRespondingRoles()

- GroupScheduler.getReplyDelay(int roleIndex)
  - 参数：roleIndex
  - 作用：生成与角色顺序相关的延迟
  - 返回：int（毫秒）
  - 调用者：ChatController._handleGroupChat()

## memory_manager.dart

功能说明：核心记忆自动总结与更新，按消息间隔触发，静默写入角色记忆。

### Functions

- MemoryManager.setSummarizeEveryNRounds(int rounds)
  - 参数：rounds
  - 作用：设置总结轮数与触发间隔
  - 返回：void
  - 调用者：外部模块（设置页）、ChatController.summaryEveryNRounds 的 setter

- MemoryManager.shouldAutoSummarize(String chatId)
  - 参数：chatId
  - 作用：判断是否达到总结触发点
  - 返回：bool
  - 调用者：triggerSummarizeIfNeeded()

- MemoryManager.triggerSummarizeIfNeeded(String chatId)
  - 参数：chatId
  - 作用：满足条件时异步触发总结
  - 返回：Future<void>
  - 调用者：ChatController._sendBatchedMessages()

- MemoryManager._performSummarize(String chatId)
  - 参数：chatId
  - 作用：拉取近期对话、调用 AI 总结并写入角色记忆
  - 返回：Future<void>
  - 调用者：triggerSummarizeIfNeeded()、manualSummarize()

- MemoryManager._buildChatText(List<Message> messages)
  - 参数：messages
  - 作用：构建对话文本
  - 返回：String
  - 调用者：_performSummarize()

- MemoryManager._parseSummary(String summary)
  - 参数：summary
  - 作用：解析 AI 总结为记忆列表
  - 返回：List<String>
  - 调用者：_performSummarize()

- MemoryManager.manualSummarize(String chatId)
  - 参数：chatId
  - 作用：手动触发总结
  - 返回：Future<void>
  - 调用者：外部模块（管理入口）

- MemoryManager.getCoreMemoryForRequest()
  - 参数：无
  - 作用：获取当前角色核心记忆
  - 返回：List<String>
  - 调用者：ChatController.sendScheduledTaskMessage()、ChatController._callAI()

- MemoryManager.getRoleCoreMemory(String roleId)
  - 参数：roleId
  - 作用：获取指定角色核心记忆
  - 返回：List<String>
  - 调用者：外部模块

## message_store.dart

功能说明：消息单一真实来源，提供流订阅、读写、持久化与后端同步。

### Functions

- MessageStore.init()
  - 参数：无
  - 作用：加载全部聊天记录
  - 返回：Future<void>
  - 调用者：ChatController.init()、外部初始化流程

- MessageStore.ensureLoaded(String chatId)
  - 参数：chatId
  - 作用：按需加载指定聊天消息
  - 返回：Future<void>
  - 调用者：ChatController.initChat()、ChatController.onChatPageEnter()、watchMessages()

- MessageStore.watchMessages(String chatId)
  - 参数：chatId
  - 作用：订阅消息流并立即推送历史消息
  - 返回：Stream<List<Message>>
  - 调用者：外部模块（聊天 UI）

- MessageStore.refreshStream(String chatId)
  - 参数：chatId
  - 作用：强制刷新消息流
  - 返回：void
  - 调用者：ChatController.initChat()、ChatController.onChatPageEnter()

- MessageStore._notifyMessageUpdate(String chatId)
  - 参数：chatId
  - 作用：向订阅者推送更新并通知监听
  - 返回：void
  - 调用者：addMessage()、addMessages()、deleteMessage()、clearMessages()、refreshStream()

- MessageStore.addMessage(String chatId, Message message)
  - 参数：chatId、message
  - 作用：追加消息、保存、广播更新并后台同步
  - 返回：Future<void>
  - 调用者：ChatController、ProactiveMessageScheduler、外部模块

- MessageStore.addMessages(String chatId, List<Message> messages)
  - 参数：chatId、messages
  - 作用：批量追加并保存
  - 返回：Future<void>
  - 调用者：外部模块（批量导入等）

- MessageStore.deleteMessage(String chatId, String messageId)
  - 参数：chatId、messageId
  - 作用：删除消息并同步后端
  - 返回：Future<void>
  - 调用者：ChatController.deleteMessage()

- MessageStore._syncDeleteMessageToBackend(String chatId, String messageId)
  - 参数：chatId、messageId
  - 作用：向后端删除消息
  - 返回：Future<void>
  - 调用者：deleteMessage()

- MessageStore.getMessages(String chatId)
  - 参数：chatId
  - 作用：获取全部消息（只读）
  - 返回：List<Message>
  - 调用者：ChatController.sendUserMessageWithQuote()、外部模块

- MessageStore.getMessage(String chatId, String messageId)
  - 参数：chatId、messageId
  - 作用：获取单条消息
  - 返回：Message?
  - 调用者：外部模块

- MessageStore.getRecentMessages(String chatId, int count)
  - 参数：chatId、count
  - 作用：获取最近 N 条消息
  - 返回：List<Message>
  - 调用者：外部模块

- MessageStore.getRecentRounds(String chatId, int rounds)
  - 参数：chatId、rounds
  - 作用：获取最近 N 轮对话
  - 返回：List<Message>
  - 调用者：ChatController._callAI()、ChatController.sendScheduledTaskMessage()、MemoryManager._performSummarize()

- MessageStore.getMessageCount(String chatId)
  - 参数：chatId
  - 作用：返回消息数量
  - 返回：int
  - 调用者：ChatController.getMessageCount()、ChatController.initChat()、MemoryManager.shouldAutoSummarize()

- MessageStore.getLastMessage(String chatId)
  - 参数：chatId
  - 作用：获取最后一条消息
  - 返回：Message?
  - 调用者：ChatController._updateChatList()

- MessageStore.clearMessages(String chatId)
  - 参数：chatId
  - 作用：清空消息并保存
  - 返回：Future<void>
  - 调用者：外部模块

- MessageStore.getUnreadCount(String chatId)
  - 参数：chatId
  - 作用：获取未读数
  - 返回：int
  - 调用者：外部模块

- MessageStore.incrementUnread(String chatId, {int count=1})
  - 参数：chatId、count
  - 作用：增加未读数
  - 返回：void
  - 调用者：ChatController._sendSegmentsQueued()、ProactiveMessageScheduler._sendAsRoleMessage()

- MessageStore.clearUnread(String chatId)
  - 参数：chatId
  - 作用：清空未读数
  - 返回：void
  - 调用者：ChatController.onChatPageEnter()

- MessageStore.setUnread(String chatId, int count)
  - 参数：chatId、count
  - 作用：设置未读数
  - 返回：void
  - 调用者：ChatController.markChatUnread()

- MessageStore._loadAllMessages()
  - 参数：无
  - 作用：加载全部聊天的历史消息
  - 返回：Future<void>
  - 调用者：init()

- MessageStore._loadMessages(String chatId)
  - 参数：chatId
  - 作用：加载指定聊天消息（含旧格式迁移）
  - 返回：Future<void>
  - 调用者：ensureLoaded()、_loadAllMessages()

- MessageStore._loadMessagesLegacy(String chatId)
  - 参数：chatId
  - 作用：读取旧格式并迁移到新格式
  - 返回：Future<void>
  - 调用者：_loadMessages()

- MessageStore._saveMessages(String chatId)
  - 参数：chatId
  - 作用：保存指定聊天消息并更新 chatIds
  - 返回：Future<void>
  - 调用者：addMessage()、addMessages()、deleteMessage()、clearMessages()、_loadMessagesLegacy()

- MessageStore._syncMessageToBackend(String chatId, Message message)
  - 参数：chatId、message
  - 作用：后台同步新增消息
  - 返回：void
  - 调用者：addMessage()

- MessageStore.toApiHistory(List<Message> messages)
  - 参数：messages
  - 作用：转换为 API 历史记录格式
  - 返回：List<Map<String,String>>
  - 调用者：ChatController._callAI()、ChatController.sendScheduledTaskMessage()

- MessageStore.dispose()
  - 参数：无
  - 作用：释放流控制器
  - 返回：void
  - 调用者：框架生命周期

## moments_scheduler.dart

功能说明：AI 朋友圈自动发布与互动调度器，含定时检查、发布、点赞、评论与回复。

### Functions

- MomentsScheduler.init()
  - 参数：无
  - 作用：启动调度器
  - 返回：Future<void>
  - 调用者：应用初始化流程

- MomentsScheduler._startScheduler()
  - 参数：无
  - 作用：设置周期定时器与首次延迟触发
  - 返回：void
  - 调用者：init()

- MomentsScheduler._onSchedulerTick()
  - 参数：无
  - 作用：按概率触发发布/互动/回复
  - 返回：void
  - 调用者：_startScheduler() 定时回调

- MomentsScheduler._triggerAIPost()
  - 参数：无
  - 作用：按冷却策略选角色并发布
  - 返回：Future<void>
  - 调用者：_onSchedulerTick()

- MomentsScheduler.generateAndPostMoment(Role role)
  - 参数：role
  - 作用：生成朋友圈内容并发布
  - 返回：Future<MomentPost?>
  - 调用者：_triggerAIPost()、外部模块（可能手动触发）

- MomentsScheduler._buildPostPrompt(Role role)
  - 参数：role
  - 作用：生成发布 prompt
  - 返回：String
  - 调用者：generateAndPostMoment()

- MomentsScheduler._triggerAIInteraction()
  - 参数：无
  - 作用：选择帖子并随机点赞/评论
  - 返回：Future<void>
  - 调用者：_onSchedulerTick()

- MomentsScheduler._performLike(Role role, MomentPost post)
  - 参数：role、post
  - 作用：执行点赞
  - 返回：Future<void>
  - 调用者：_triggerAIInteraction()

- MomentsScheduler._performComment(Role role, MomentPost post)
  - 参数：role、post
  - 作用：生成并提交评论
  - 返回：Future<void>
  - 调用者：_triggerAIInteraction()

- MomentsScheduler._buildCommentPrompt(Role role, MomentPost post)
  - 参数：role、post
  - 作用：生成评论 prompt
  - 返回：String
  - 调用者：_performComment()

- MomentsScheduler._triggerAIReplyToUserComment()
  - 参数：无
  - 作用：找用户评论并回复
  - 返回：Future<void>
  - 调用者：_onSchedulerTick()

- MomentsScheduler.getUserRecentMoments({int limit=3})
  - 参数：limit
  - 作用：获取用户最近朋友圈
  - 返回：List<MomentPost>
  - 调用者：buildMomentsAwarenessContext()

- MomentsScheduler.buildMomentsAwarenessContext()
  - 参数：无
  - 作用：生成弱上下文提示
  - 返回：String?
  - 调用者：ChatController._callAI()

- MomentsScheduler._formatTimeAgo(DateTime time)
  - 参数：time
  - 作用：格式化相对时间
  - 返回：String
  - 调用者：buildMomentsAwarenessContext()

- MomentsScheduler.dispose()
  - 参数：无
  - 作用：停止调度器
  - 返回：void
  - 调用者：框架生命周期/外部管理逻辑

## proactive_message_scheduler.dart

功能说明：按角色配置调度主动消息，支持冷启动补偿、静默时间避让与分段发送。

### Functions

- ProactiveMessageScheduler.init()
  - 参数：无
  - 作用：冷启动补偿并为所有角色排程
  - 返回：Future<void>
  - 调用者：应用初始化流程

- ProactiveMessageScheduler._checkAndCompensate()
  - 参数：无
  - 作用：补偿已过期触发时间
  - 返回：Future<void>
  - 调用者：init()

- ProactiveMessageScheduler._scheduleAllRoles()
  - 参数：无
  - 作用：遍历并调度启用角色
  - 返回：void
  - 调用者：init()

- ProactiveMessageScheduler.scheduleForRole(String roleId)
  - 参数：roleId
  - 作用：为角色计算/保存触发时间并设置计时器
  - 返回：void
  - 调用者：_scheduleAllRoles()、onRoleConfigChanged()、_triggerProactiveMessage()后续重排

- ProactiveMessageScheduler.cancelForRole(String roleId)
  - 参数：roleId
  - 作用：取消指定角色计时器
  - 返回：void
  - 调用者：scheduleForRole()、onRoleConfigChanged()

- ProactiveMessageScheduler.cancelAll()
  - 参数：无
  - 作用：取消全部计时器
  - 返回：void
  - 调用者：外部模块（退出/重置）

- ProactiveMessageScheduler._generateNextTriggerTime(ProactiveConfig config)
  - 参数：config
  - 作用：生成随机触发时间
  - 返回：DateTime
  - 调用者：scheduleForRole()

- ProactiveMessageScheduler._saveNextTriggerTime(String roleId, DateTime triggerTime)
  - 参数：roleId、triggerTime
  - 作用：保存触发时间到角色配置
  - 返回：Future<void>
  - 调用者：scheduleForRole()

- ProactiveMessageScheduler._triggerProactiveMessage(String roleId)
  - 参数：roleId
  - 作用：检查安静时间后调用 AI 生成并发送
  - 返回：Future<void>
  - 调用者：_checkAndCompensate()、scheduleForRole()计时器回调

- ProactiveMessageScheduler._sendAsRoleMessage(String chatId, Role role, String content)
  - 参数：chatId、role、content
  - 作用：按分段写入消息并更新未读
  - 返回：Future<void>
  - 调用者：_triggerProactiveMessage()

- ProactiveMessageScheduler.onRoleConfigChanged(String roleId)
  - 参数：roleId
  - 作用：角色配置变化时重新随机倒计时
  - 返回：void
  - 调用者：外部模块（角色设置页）

## segment_sender.dart

功能说明：分段发送工具，按 "$" 分割并模拟真人聊天延迟。

### Functions

- SegmentSender.splitMessage(String content)
  - 参数：content
  - 作用：按 "$" 分段并清理空片段
  - 返回：List<String>
  - 调用者：ChatController._sendSegmentsQueued()、ProactiveMessageScheduler._sendAsRoleMessage()、sendInSegments()

- SegmentSender.getRandomDelay()
  - 参数：无
  - 作用：生成 300–1199ms 的随机延迟
  - 返回：int
  - 调用者：sendInSegments()、ProactiveMessageScheduler._sendAsRoleMessage()

- SegmentSender.sendInSegments({required String content, required Future<void> Function(String segment, bool isLast) onSegment, void Function(bool isTyping)? onTypingChange})
  - 参数：content、onSegment、onTypingChange
  - 作用：顺序分段发送并插入延迟
  - 返回：Future<void>
  - 调用者：外部模块（通用分段发送场景）
