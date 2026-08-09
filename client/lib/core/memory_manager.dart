import '../services/memory_service.dart';
import '../services/role_service.dart';

/// 记忆管理器
///
/// 核心记忆的总结与更新已完全迁移到服务端（见 server 记忆管线），
/// 客户端仅保留“读取核心记忆供请求使用”的取数接口。历史上的客户端
/// 自动总结路径（triggerSummarizeIfNeeded/_performSummarize 等）已无调用者，
/// 且其结果从未持久化，属死代码，已移除。
class MemoryManager {
  /// 获取用于 AI 请求的核心记忆（优先服务端同步值，回退当前角色本地值）。
  static List<String> getCoreMemoryForRequest() {
    final synced = MemoryService.getCoreMemory();
    if (synced.isNotEmpty) {
      return synced;
    }
    final role = RoleService.getCurrentRole();
    return role.coreMemory;
  }

  /// 获取指定角色的核心记忆。
  static List<String> getRoleCoreMemory(String roleId) {
    final role = RoleService.getRoleById(roleId);
    return role?.coreMemory ?? [];
  }
}
