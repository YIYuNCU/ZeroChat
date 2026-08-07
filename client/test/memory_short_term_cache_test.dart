import 'package:flutter_test/flutter_test.dart';
import 'package:zerochat/services/memory_service.dart';

void main() {
  test('short-term cache retains only the latest bounded entries', () {
    final entries = List<Map<String, dynamic>>.generate(
      MemoryService.maxShortTermCacheEntries + 25,
      (index) => {'id': index + 1, 'content': 'entry-$index'},
    ).reversed.toList();

    final retained = MemoryService.retainLatestShortTermCacheEntries(entries);

    expect(retained, hasLength(MemoryService.maxShortTermCacheEntries));
    expect(retained.first['id'], 26);
    expect(retained.last['id'], MemoryService.maxShortTermCacheEntries + 25);
  });
}
