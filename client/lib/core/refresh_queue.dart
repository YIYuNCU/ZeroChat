import 'dart:async';

/// Coalesces bursts while retaining an update received during an active fetch.
class RefreshQueue {
  RefreshQueue(this.refresh, {this.minGap = Duration.zero});

  final Future<void> Function() refresh;
  final Duration minGap;
  Future<void>? _running;
  bool _pending = false;
  bool _disposed = false;
  DateTime? _lastStart;

  Future<void> request() {
    if (_disposed) return Future.value();
    _pending = true;
    return _running ??= Future<void>.microtask(_drain).whenComplete(() {
      _running = null;
    });
  }

  Future<void> _drain() async {
    while (_pending && !_disposed) {
      final elapsed = _lastStart == null
          ? minGap
          : DateTime.now().difference(_lastStart!);
      if (elapsed < minGap) await Future<void>.delayed(minGap - elapsed);
      if (_disposed) return;
      _pending = false;
      _lastStart = DateTime.now();
      try {
        await refresh();
      } catch (_) {
        // Drain a queued update even if the preceding request failed.
        if (!_pending) rethrow;
      }
    }
  }

  void dispose() {
    _disposed = true;
    _pending = false;
  }
}
