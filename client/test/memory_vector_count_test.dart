import 'package:flutter_test/flutter_test.dart';
import 'package:zerochat/services/memory_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('向量记忆计数按角色隔离', () {
    test('显式 roleId 读写互不影响', () {
      MemoryService.setVectorMemoryCountFor('role-large', 250);
      MemoryService.setVectorMemoryCountFor('role-small', 3);

      expect(MemoryService.vectorMemoryCountFor('role-large'), 250);
      expect(MemoryService.vectorMemoryCountFor('role-small'), 3);
      expect(MemoryService.vectorMemoryCountFor('role-unknown'), 0);
    });

    test('兼容 getter/setter 委托给全局当前角色，不影响其它角色缓存', () {
      MemoryService.setVectorMemoryCountFor('role-other', 42);
      MemoryService.vectorMemoryCount = 9;

      expect(MemoryService.vectorMemoryCount, 9);
      expect(MemoryService.vectorMemoryCountFor('role-other'), 42);
    });
  });

  group('MemoryPageSession 服务端总数', () {
    test('pageTotalCount 解析 count 字段，缺失/非法时返回 null', () {
      expect(MemoryService.pageTotalCount({'count': 250}), 250);
      expect(MemoryService.pageTotalCount({'count': '250'}), 250);
      expect(MemoryService.pageTotalCount({'count': 12.0}), 12);
      expect(MemoryService.pageTotalCount({'count': -1}), isNull);
      expect(MemoryService.pageTotalCount({'count': 'abc'}), isNull);
      expect(MemoryService.pageTotalCount(<String, dynamic>{}), isNull);
      expect(MemoryService.pageTotalCount(null), isNull);
    });

    test('多页合并时保留最新非空 count', () {
      int? total;
      total = MemoryService.mergePageTotalCount(total, {'count': 250});
      expect(total, 250);

      // 后续页缺 count（例如 reset_required 响应）时保留旧值
      total = MemoryService.mergePageTotalCount(total, {
        'reset_required': true,
      });
      expect(total, 250);

      // 新页返回 count 时以最新值为准（例如删除后重新拉取）
      total = MemoryService.mergePageTotalCount(total, {'count': 120});
      expect(total, 120);
    });

    test('MemoryPageSession 的 totalCount 初始为空，等待分页响应填充', () {
      final pager = MemoryPageSession('role-x');
      expect(pager.totalCount, isNull);
    });
  });
}
