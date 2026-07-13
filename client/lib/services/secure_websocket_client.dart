import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

import 'notification_service.dart';
import 'settings_service.dart';
import 'secure_backend_client.dart';
import 'wake_lock_service.dart';

class SecureWebSocketClient {
  SecureWebSocketClient._() {
    _startConnectivityMonitor();
  }

  static final SecureWebSocketClient instance = SecureWebSocketClient._();

  static const Duration _defaultRequestTimeout = Duration(seconds: 15);
  static const Duration _connectTimeout = Duration(seconds: 20);
  static const int _maxRequestRetries = 3;
  static const Duration _heartbeatInterval = Duration(seconds: 25);
  static const Duration _connectivityReconnectDebounce = Duration(seconds: 3);
  static const Duration _baseReconnectDelay = Duration(seconds: 1);
  static const Duration _maxReconnectDelay = Duration(seconds: 60);
  static const int _maxReconnectBackoffCount = 8;

  WebSocket? _socket;
  StreamSubscription<dynamic>? _subscription;
  Timer? _heartbeatTimer;
  StreamSubscription<dynamic>? _connectivitySubscription;
  Timer? _connectivityReconnectTimer;

  int _reconnectBackoffCount = 0;
  int _heartbeatFailCount = 0;
  Timer? _reconnectTimer;

  final Map<String, Completer<Map<String, dynamic>>> _pending =
      <String, Completer<Map<String, dynamic>>>{};
    final StreamController<Map<String, dynamic>> _serverPushController =
      StreamController<Map<String, dynamic>>.broadcast();

  Completer<void>? _connectingCompleter;
  int _requestSeq = 0;

  /// Called after a successful reconnection (not first connect).
  /// Used by ChatController to recover missed pushes.
  void Function()? onReconnected;

  bool get isConnected => _socket != null && _socket!.readyState == WebSocket.open;
  Stream<Map<String, dynamic>> get serverPushStream => _serverPushController.stream;

  Future<void> ensureConnected() async {
    final existing = _socket;
    if (existing != null && existing.readyState == WebSocket.open) {
      _resetBackoff();
      return;
    }

    if (existing != null && existing.readyState != WebSocket.open) {
      _handleDisconnect('socket not open (state=${existing.readyState})');
    }

    if (_connectingCompleter != null) {
      try {
        await _connectingCompleter!.future;
        return;
      } catch (_) {
        // 首个连接失败，降级继续尝试新连接
      }
    }

    // Exponential backoff delay before attempting connection
    final delay = _computeReconnectDelay();
    if (delay > Duration.zero) {
      debugPrint('SecureWebSocketClient: backoff waiting ${delay.inSeconds}s before reconnect');
      await Future.delayed(delay);
    }

    final completer = Completer<void>();
    _connectingCompleter = completer;

    try {
      final wsUri = _buildWsUri(
        backendUrl: SettingsService.instance.backendUrl,
      );

      final socket = await WebSocket.connect(
        wsUri.toString(),
        headers: {'X-Auth-Token': SettingsService.instance.backendAuthToken},
      ).timeout(_connectTimeout);

      final wasReconnection = _reconnectBackoffCount > 0;
      _resetBackoff();
      _socket = socket;
      _subscription = socket.listen(
        _handleIncoming,
        onError: (Object error, StackTrace stackTrace) {
          debugPrint('SecureWebSocketClient: stream error: $error');
          _handleDisconnect(error.toString());
        },
        onDone: () {
          _handleDisconnect('socket closed');
        },
      );

      _startHeartbeat();
      completer.complete();
      if (wasReconnection && onReconnected != null) {
        onReconnected!();
      }
    } catch (e) {
      _bumpBackoff();
      _handleDisconnect('connect failed: $e');
      completer.completeError(e);
      rethrow;
    } finally {
      _connectingCompleter = null;
    }
  }

  Future<Map<String, dynamic>> request(
    String action,
    Map<String, dynamic> payload, {
    Duration timeout = _defaultRequestTimeout,
  }) async {
    final requestId = _nextRequestId();
    Object? lastError;

    for (int attempt = 0; attempt <= _maxRequestRetries; attempt += 1) {
      try {
        return await _sendRequestOnce(
          action,
          payload,
          requestId: requestId,
          timeout: timeout,
        );
      } catch (e) {
        lastError = e;
        final shouldRetry = attempt < _maxRequestRetries && _shouldRetryRequestError(e);
        if (!shouldRetry) {
          rethrow;
        }

        debugPrint(
          'SecureWebSocketClient: request retry for $action (attempt ${attempt + 2}/${_maxRequestRetries + 1}), error: $e',
        );
        await _reconnectForRetry();
      }
    }

    throw lastError ?? Exception('WebSocket request failed: $action');
  }

  Future<Map<String, dynamic>> _sendRequestOnce(
    String action,
    Map<String, dynamic> payload, {
    required String requestId,
    required Duration timeout,
  }) async {
    await ensureConnected();

    final completer = Completer<Map<String, dynamic>>();
    _pending[requestId] = completer;

    final encryptedPayload = SecureBackendClient.encryptPayloadForTransfer(
      payload,
    );

    final frame = <String, dynamic>{
      'request_id': requestId,
      'action': action,
      'payload': encryptedPayload,
    };

    try {
      await WakeLockService.acquireShort(
        duration: _resolveRequestWakeLockDuration(timeout),
        reason: 'request_$action',
      );
      final socket = _socket;
      if (socket == null) {
        throw const SocketException('WebSocket disconnected before send');
      }
      socket.add(jsonEncode(frame));
    } catch (e) {
      _pending.remove(requestId);
      rethrow;
    }

    return completer.future.timeout(
      timeout,
      onTimeout: () {
        _pending.remove(requestId);
        throw TimeoutException(
          'WebSocket request timeout: $action',
          timeout,
        );
      },
    );
  }

  bool _shouldRetryRequestError(Object error) {
    if (error is TimeoutException || error is SocketException || error is WebSocketException) {
      return true;
    }

    final text = error.toString().toLowerCase();
    return text.contains('socket') ||
        text.contains('connect failed') ||
        text.contains('disconnected') ||
        text.contains('connection closed');
  }

  Future<void> _reconnectForRetry() async {
    await ensureConnected().catchError((_) {});
  }

  Future<void> recoverConnectionWithoutClose({String reason = 'auto_recover'}) async {
    _handleDisconnect('recover_without_close:$reason');
    await ensureConnected();
  }

  Future<void> close() async {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;

    _reconnectTimer?.cancel();
    _reconnectTimer = null;

    await _subscription?.cancel();
    _subscription = null;

    await _socket?.close();
    _socket = null;

    _failAllPending('socket closed');
  }

  Duration _resolveRequestWakeLockDuration(Duration timeout) {
    final bounded = timeout.inSeconds.clamp(8, 90);
    return Duration(seconds: bounded + 6);
  }

  Uri _buildWsUri({required String backendUrl}) {
    final uri = Uri.parse(backendUrl);
    final wsScheme = uri.scheme == 'https' ? 'wss' : 'ws';

    return Uri(
      scheme: wsScheme,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
      path: '/ws/secure',
    );
  }

  String _nextRequestId() {
    _requestSeq += 1;
    return '${DateTime.now().microsecondsSinceEpoch}_$_requestSeq';
  }

  void _handleIncoming(dynamic raw) {
    try {
      final map = jsonDecode(raw.toString());
      if (map is! Map) {
        return;
      }
      final data = Map<String, dynamic>.from(map);
      final event = data['event']?.toString() ?? '';
      if (event == 'heartbeat_ack') {
        return;
      }

      if (event == 'server_push') {
        try {
          final encryptedPayload = data['data'];
          final decrypted = SecureBackendClient.decryptPayloadFromTransfer(
            encryptedPayload,
          );
          final payloadMap = decrypted is Map
              ? Map<String, dynamic>.from(decrypted)
              : <String, dynamic>{'value': decrypted};

          _serverPushController.add({
            'event': event,
            'type': data['type']?.toString(),
            ...payloadMap,
          });
        } catch (e) {
          debugPrint('SecureWebSocketClient: decode server push failed: $e');
        }
        return;
      }

      final requestId = data['request_id']?.toString() ?? '';
      if (requestId.isEmpty) {
        return;
      }

      final completer = _pending.remove(requestId);
      if (completer == null || completer.isCompleted) {
        return;
      }

      final ok = data['ok'] == true;
      if (!ok) {
        String errorText = data['error']?.toString() ?? 'unknown websocket error';
        try {
          final encryptedError = data['data'];
          if (encryptedError != null) {
            final decryptedError = SecureBackendClient.decryptPayloadFromTransfer(
              encryptedError,
            );
            if (decryptedError is Map) {
              final map = Map<String, dynamic>.from(decryptedError);
              final maybeError = map['error']?.toString();
              if (maybeError != null && maybeError.isNotEmpty) {
                errorText = maybeError;
              }
            }
          }
        } catch (_) {
          // Ignore decrypt failure and keep fallback error text.
        }
        completer.completeError(Exception(errorText));
        return;
      }

      final encryptedResult = data['data'];
      final decrypted = SecureBackendClient.decryptPayloadFromTransfer(
        encryptedResult,
      );
      if (decrypted is Map<String, dynamic>) {
        completer.complete(decrypted);
      } else if (decrypted is Map) {
        completer.complete(Map<String, dynamic>.from(decrypted));
      } else {
        completer.complete({'value': decrypted});
      }
    } catch (e) {
      debugPrint('SecureWebSocketClient: decode incoming failed: $e');
    }
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(_heartbeatInterval, (Timer timer) {
      unawaited(_sendHeartbeatFrame());
    });
  }

  Future<void> _sendHeartbeatFrame() async {
    final socket = _socket;
    if (socket == null) {
      return;
    }
    try {
      await WakeLockService.acquireShort(
        duration: const Duration(seconds: 10),
        reason: 'heartbeat',
      );
      socket.add(
        jsonEncode({
          'event': 'heartbeat',
          'timestamp': DateTime.now().toIso8601String(),
        }),
      );
      _heartbeatFailCount = 0;
    } catch (e) {
      _heartbeatFailCount += 1;
      debugPrint('SecureWebSocketClient: heartbeat failed ($_heartbeatFailCount): $e');
      if (_heartbeatFailCount >= 2) {
        _handleDisconnect('heartbeat failed after $_heartbeatFailCount attempts: $e');
      }
    }
  }

  void _startConnectivityMonitor() {
    if (!Platform.isAndroid) {
      return;
    }

    _connectivitySubscription?.cancel();
    _connectivitySubscription = Connectivity().onConnectivityChanged.listen(
      (dynamic result) {
        if (!_hasNetwork(result)) {
          return;
        }
        _scheduleConnectivityConnectionCheck();
      },
      onError: (Object error, StackTrace stackTrace) {
        debugPrint('SecureWebSocketClient: connectivity stream error: $error');
      },
    );
  }

  bool _hasNetwork(dynamic result) {
    if (result is ConnectivityResult) {
      return result != ConnectivityResult.none;
    }
    if (result is List<ConnectivityResult>) {
      return result.any((ConnectivityResult item) => item != ConnectivityResult.none);
    }
    if (result is Iterable) {
      return result.any((dynamic item) => item != ConnectivityResult.none);
    }
    return true;
  }

  void _scheduleConnectivityConnectionCheck() {
    _connectivityReconnectTimer?.cancel();
    _connectivityReconnectTimer = Timer(
      _connectivityReconnectDebounce,
      () {
        unawaited(_checkConnectionAfterNetworkChange());
      },
    );
  }

  Future<void> _checkConnectionAfterNetworkChange() async {
    if (_socket == null) {
      try {
        await ensureConnected();
      } catch (e) {
        debugPrint(
          'SecureWebSocketClient: reconnect failed after connectivity change: $e',
        );
      }
      return;
    }

    try {
      await request(
        'health',
        const <String, dynamic>{},
        timeout: const Duration(seconds: 4),
      );
    } catch (e) {
      debugPrint(
        'SecureWebSocketClient: connection check failed after connectivity change, reconnecting: $e',
      );
      try {
        _handleDisconnect('connectivity_check_failed');
        await ensureConnected();
      } catch (e2) {
        debugPrint(
          'SecureWebSocketClient: reconnect failed after connection check: $e2',
        );
      }
    }
  }

  void _handleDisconnect(String reason) {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;

    _subscription?.cancel();
    _subscription = null;

    _socket = null;
    _failAllPending(reason);

    _scheduleReconnect(reason);
  }

  void _scheduleReconnect(String reason) {
    _reconnectTimer?.cancel();
    final delay = _computeReconnectDelay();
    debugPrint(
      'SecureWebSocketClient: scheduling reconnect in ${delay.inSeconds}s (reason: $reason)',
    );
    _reconnectTimer = Timer(delay, () {
      _reconnectTimer = null;
      unawaited(ensureConnected().catchError((_) {}));
    });
  }

  Duration _computeReconnectDelay() {
    if (_reconnectBackoffCount <= 0) return Duration.zero;
    final clamped = _reconnectBackoffCount.clamp(0, _maxReconnectBackoffCount);
    // 2^clamped seconds with jitter (±25%)
    final base = (_baseReconnectDelay.inMilliseconds << clamped).toDouble();
    final jitter = 0.75 + 0.5 * (DateTime.now().millisecondsSinceEpoch % 100) / 100.0;
    final delay = (base * jitter).clamp(
      _baseReconnectDelay.inMilliseconds.toDouble(),
      _maxReconnectDelay.inMilliseconds.toDouble(),
    );
    return Duration(milliseconds: delay.round());
  }

  void _resetBackoff() {
    final wasDisconnected = _reconnectBackoffCount > 0;
    _reconnectBackoffCount = 0;
    _heartbeatFailCount = 0;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    if (wasDisconnected) {
      unawaited(NotificationService.instance.clearConnectionLostNotification());
    }
  }

  void _bumpBackoff() {
    if (_reconnectBackoffCount < _maxReconnectBackoffCount) {
      _reconnectBackoffCount += 1;
    }
    // 退避达到 3 次以上时通知用户连接已断开
    if (_reconnectBackoffCount >= 3) {
      unawaited(NotificationService.instance.showConnectionLostNotification());
    }
  }

  void _failAllPending(String reason) {
    final entries = List<MapEntry<String, Completer<Map<String, dynamic>>>>.from(
      _pending.entries,
    );
    _pending.clear();

    for (final entry in entries) {
      if (!entry.value.isCompleted) {
        entry.value.completeError(Exception(reason));
      }
    }
  }
}
