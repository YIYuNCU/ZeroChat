/// Payload-free application transport counters. Values never contain URLs,
/// tokens, prompts or message text. Resettable for repeatable bandwidth checks.
class TransferMetrics {
  static final Map<String, Map<String, int>> _values = {};
  static void record(
    String action, {
    int sent = 0,
    int received = 0,
    bool request = false,
  }) {
    final values = _values.putIfAbsent(
      action,
      () => {'requests': 0, 'sent_bytes': 0, 'received_bytes': 0},
    );
    values['requests'] = values['requests']! + (request ? 1 : 0);
    values['sent_bytes'] = values['sent_bytes']! + sent;
    values['received_bytes'] = values['received_bytes']! + received;
  }

  static Map<String, Map<String, int>> snapshot() => {
    for (final entry in _values.entries) entry.key: Map.of(entry.value),
  };
  static void reset() => _values.clear();
  static void cacheHit(String action, {bool conditional = false}) {
    record(action);
    final key = conditional ? 'conditional_hits' : 'cache_hits';
    _values[action]![key] = (_values[action]![key] ?? 0) + 1;
  }
}
