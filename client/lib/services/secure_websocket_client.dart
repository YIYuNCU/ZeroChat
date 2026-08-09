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

  /// 前台/后台自适应心跳间隔。前台需要实时性，后台延长以省电；
  /// 服务端 WS 端点无应用级空闲超时，延长后台心跳安全。
  static const Duration _fallbackForegroundHeartbeatInterval =
      Duration(seconds: 25);
  static const Duration _fallbackBackgroundHeartbeatInterval =
      Duration(seconds: 60);

  /// 心跳发出后等待 heartbeat_ack 的最长时间；超时视为半掉线并重连。
  static const Duration _heartbeatAckTimeout = Duration(seconds: 10);
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

  /// 应用是否处于前台。影响心跳间隔与请求唤醒锁策略。
  bool _inForeground = true;

  /// pong 看门狗：心跳发出后等待 heartbeat_ack 的定时器与状态。
  Timer? _pongTimer;
  bool _awaitingPong = false;

  final Map<String, Completer<Map<String, dynamic>>> _pending =
      <String, Completer<Map<String, dynamic>>>{};
    final StreamController<Map<String, dynamic>> _serverPushController =
      StreamController<Map<String, dynamic>>.broadcast();
    final StreamController<void> _reconnectedController =
      StreamController<void>.broadcast();

  Completer<void>? _connectingCompleter;
  int _requestSeq = 0;
  int _connectionAttempts = 0;

  /// Called after a successful reconnection (not first connect).
  /// Used by ChatController to recover missed pushes.
  void Function()? onReconnected;

  bool get isConnected => _socket != null && _socket!.readyState == WebSocket.open;
  Stream<Map<String, dynamic>> get serverPushStream => _serverPushController.stream;

  /// Emits after every successful reconnection (not the first connect).
  /// Multiple subscribers can listen (e.g. RealtimeSyncService full re-sync).
  Stream<void> get onReconnectedStream => _reconnectedController.stream;

  Future<void> ensureConnected() async {
    // 未配置鉴权 token / 加密 secret 时不再回退到内置默认值，直接阻止连接，
    // 提示用户到设置页填写（避免用无效默认值反复失败连接）。
    if (!SecureBackendClient.isSecurityConfigured) {
      debugPrint(
        'SecureWebSocketClient: 后端鉴权未配置（Token/加密密钥为空），'
        '请在「设置 → 后端服务器」中填写后再连接。',
      );
      throw StateError('后端鉴权未配置，请先在设置中填写 Token 与加密密钥');
    }

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

    // 退避延迟只在 _scheduleReconnect 的定时器里应用一次；这里不再重复等待，
    // 避免经调度器进入时叠加两次退避。直接调用（如发送前保活）也应尽快连接。
    final completer = Completer<void>();
    _connectingCompleter = completer;

    final wasReconnection = _connectionAttempts > 0;
    _connectionAttempts += 1;

    try {
      final wsUri = _buildWsUri(
        backendUrl: SettingsService.instance.backendUrl,
      );

      final socket = await WebSocket.connect(
        wsUri.toString(),
        headers: {'X-Auth-Token': SettingsService.instance.backendAuthToken},
      ).timeout(_connectTimeout);

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
      if (wasReconnection) {
        if (onReconnected != null) {
          onReconnected!();
        }
        if (!_reconnectedController.isClosed) {
          _reconnectedController.add(null);
        }
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
      // 仅在后台申请请求唤醒锁；前台 CPU 本就处于唤醒状态无需持锁。
      if (!_inForeground) {
        await WakeLockService.acquireShort(
          duration: _resolveRequestWakeLockDuration(timeout),
          reason: 'request_$action',
        );
      }
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
    _cancelPongWatchdog();

    _reconnectTimer?.cancel();
    _reconnectTimer = null;

    await _subscription?.cancel();
    _subscription = null;

    await _socket?.close();
    _socket = null;

    _failAllPending('socket closed');
  }

  Duration _resolveRequestWakeLockDuration(Duration timeout) {
    final bounded = timeout.inSeconds.clamp(8, 60);
    return Duration(seconds: bounded + 2);
  }

  /// 判断主机是否为本机回环（本地开发允许明文）。
  static bool _isLoopbackHost(String host) {
    final h = host.toLowerCase();
    return h == 'localhost' || h == '127.0.0.1' || h == '::1';
  }

  Uri _buildWsUri({required String backendUrl}) {
    final uri = Uri.parse(backendUrl);
    final wsScheme = uri.scheme == 'https' ? 'wss' : 'ws';

    // 明文传输告警：非回环主机仍用 http/ws 时，鉴权 header 与流量将走明文，
    // 存在中间人窃听/篡改风险。本地回环放行以便开发调试。
    if (wsScheme == 'ws' && !_isLoopbackHost(uri.host)) {
      debugPrint(
        'SecureWebSocketClient: ⚠️ 正在通过明文 ws:// 连接非本机后端 '
        '(${uri.host})，鉴权 token 与消息内容不加密传输。建议后端启用 HTTPS/WSS。',
      );
    }

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
        // 收到 ack：关闭看门狗，重置失败计数，随后仍丢弃 payload。
        _cancelPongWatchdog();
        _heartbeatFailCount = 0;
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

  /// 从 SettingsService 读取当前应生效的心跳间隔（前台/后台不同）。
  /// SettingsService 在主隔离与后台隔离都会初始化，故两处均可用。
  Duration get _currentHeartbeatInterval {
    try {
      final seconds = _inForeground
          ? SettingsService.instance.foregroundHeartbeatSeconds
          : SettingsService.instance.backgroundHeartbeatSeconds;
      return Duration(seconds: seconds);
    } catch (_) {
      return _inForeground
          ? _fallbackForegroundHeartbeatInterval
          : _fallbackBackgroundHeartbeatInterval;
    }
  }

  /// 更新前台/后台状态。若心跳定时器在运行且状态发生变化，
  /// 以新的间隔重建定时器。
  void setForeground(bool value) {
    if (_inForeground == value) {
      return;
    }
    _inForeground = value;
    if (_heartbeatTimer != null) {
      _startHeartbeat();
    }
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _cancelPongWatchdog();
    _heartbeatTimer = Timer.periodic(_currentHeartbeatInterval, (Timer timer) {
      unawaited(_sendHeartbeatFrame());
    });
  }

  Future<void> _sendHeartbeatFrame() async {
    final socket = _socket;
    if (socket == null) {
      return;
    }

    // 上一轮心跳的 ack 仍未到达：连接已半掉线，主动断开重连。
    if (_awaitingPong) {
      _cancelPongWatchdog();
      _handleDisconnect('heartbeat_ack missing (previous heartbeat not acked)');
      return;
    }

    try {
      // 心跳发送是即时的 fire-and-forget：定时器触发时 CPU 已被调度唤醒，
      // 无需为此持有唤醒锁（此前的 10s 心跳锁是后台耗电的主要来源）。
      socket.add(
        jsonEncode({
          'event': 'heartbeat',
          'timestamp': DateTime.now().toIso8601String(),
        }),
      );
      _heartbeatFailCount = 0;
      _armPongWatchdog();
    } catch (e) {
      _heartbeatFailCount += 1;
      debugPrint('SecureWebSocketClient: heartbeat failed ($_heartbeatFailCount): $e');
      if (_heartbeatFailCount >= 2) {
        _handleDisconnect('heartbeat failed after $_heartbeatFailCount attempts: $e');
      }
    }
  }

  /// 心跳发出后启动 pong 看门狗；到期仍未收到 heartbeat_ack 即判定半掉线。
  void _armPongWatchdog() {
    _awaitingPong = true;
    _pongTimer?.cancel();
    _pongTimer = Timer(_heartbeatAckTimeout, () {
      _pongTimer = null;
      if (_awaitingPong) {
        _awaitingPong = false;
        _handleDisconnect('heartbeat_ack timeout');
      }
    });
  }

  void _cancelPongWatchdog() {
    _pongTimer?.cancel();
    _pongTimer = null;
    _awaitingPong = false;
  }

  void _startConnectivityMonitor() {
    // connectivity_plus 支持 iOS/macOS/Windows/Linux；下游已做 3s 防抖 +
    // health 探测优先于重连，桌面/VPN 的噪声事件不会误关健康连接。
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
    _cancelPongWatchdog();

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
