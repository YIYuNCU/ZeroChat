import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zerochat/services/memory_service.dart';
import 'package:zerochat/services/storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await StorageService.init();
  });

  test('appendJsonMemoryPair 保留最近 maxJsonMemoryEntries 条（FIFO 截断）', () async {
    const roleId = 'role-cap';
    // 追加远超上限的条目；每次追加 user+assistant 两条。
    final pairs = MemoryService.maxJsonMemoryEntries; // 200 pairs -> 400 entries
    for (var i = 0; i < pairs; i++) {
      await MemoryService.appendJsonMemoryPair(
        roleId: roleId,
        userContent: 'user-$i',
        assistantContent: 'assistant-$i',
        requestId: 'req-$i',
      );
    }

    final entries = MemoryService.getJsonMemoryEntries(roleId);
    // 不得超过上限
    expect(entries.length, MemoryService.maxJsonMemoryEntries);
    // 保留的是最新的条目：最后一条应来自最后一次追加
    expect(entries.last['content'], 'assistant-${pairs - 1}');
  });

  test('clearJsonMemory 清空指定角色的 JSON 记忆', () async {
    const roleId = 'role-clear';
    await MemoryService.appendJsonMemoryPair(
      roleId: roleId,
      userContent: 'hello',
      assistantContent: 'hi',
      requestId: 'req-1',
    );
    expect(MemoryService.getJsonMemoryEntries(roleId), isNotEmpty);

    await MemoryService.clearJsonMemory(roleId);
    expect(MemoryService.getJsonMemoryEntries(roleId), isEmpty);
  });

  test('setCoreMemoryLocal 更新本地缓存且不抛出（无网络）', () async {
    await MemoryService.setCoreMemoryLocal(['记忆A', '记忆B']);
    expect(MemoryService.getCoreMemory(), ['记忆A', '记忆B']);
    // 再次覆盖
    await MemoryService.setCoreMemoryLocal(['记忆C']);
    expect(MemoryService.getCoreMemory(), ['记忆C']);
  });
}
