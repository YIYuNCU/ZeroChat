import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:zerochat/core/refresh_queue.dart';

void main() {
  test(
    'coalesces a burst and retains one refresh arriving during a fetch',
    () async {
      final first = Completer<void>();
      final started = Completer<void>();
      var calls = 0;
      final queue = RefreshQueue(() async {
        calls++;
        if (calls == 1) {
          started.complete();
          await first.future;
        }
      });
      final done = queue.request();
      queue.request();
      await started.future;
      queue.request();
      queue.request();
      first.complete();
      await done;
      expect(calls, 2);
      queue.dispose();
    },
  );

  test('a failed fetch does not swallow a queued update', () async {
    var calls = 0;
    final gate = Completer<void>();
    final started = Completer<void>();
    final queue = RefreshQueue(() async {
      if (++calls == 1) {
        started.complete();
        await gate.future;
        throw StateError('offline');
      }
    });
    final done = queue.request();
    await started.future;
    queue.request();
    gate.complete();
    await done;
    expect(calls, 2);
    queue.dispose();
  });

  test('dispose cancels pending refreshes', () async {
    var calls = 0;
    final queue = RefreshQueue(() async {
      calls++;
    });
    final done = queue.request();
    queue.dispose();
    await done;
    expect(calls, 0);
  });
}
