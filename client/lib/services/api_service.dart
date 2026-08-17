import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import '../models/role.dart';
import 'settings_service.dart';
import 'secure_websocket_client.dart';

/// 后端 AI 与图片上传服务。
class ApiService {
  static const int _visionChunkSize = 64 * 1024;
  static const int _visionChunkMaxRetry = 3;

  /// 发送聊天消息到 AI 接口（使用角色参数）
  /// [message] 用户当前发送的消息
  /// [role] 当前使用的已保存角色。
  static Future<ApiResponse> sendChatMessageWithRole({
    required String message,
    required Role role,
  }) async {
    if (role.id == 'temp') {
      return ApiResponse.error('后端聊天请求必须使用已保存的角色');
    }
    return sendChatViaBackend(
      roleId: role.id,
      message: message,
    );
  }

  // ========== 后端集成 ==========

  /// 通过后端调用 AI（统一入口）
  /// [roleId] 角色 ID
  /// [eventType] 事件类型: chat, task, proactive, moment, comment
  /// [content] 消息内容
  /// [context] 额外上下文
  static Future<ApiResponse> callBackendAI({
    required String roleId,
    required String eventType,
    String content = '',
    Map<String, dynamic>? context,
    Duration timeout = const Duration(seconds: 8),
  }) async {
    try {
      final wsData = await SecureWebSocketClient.instance.request('ai_event', {
        'event': {
          'role_id': roleId,
          'event_type': eventType,
          'content': content,
          'context': context ?? <String, dynamic>{},
        },
      }, timeout: timeout);

      debugPrint(
        'ApiService: Backend AI call via websocket - $eventType for $roleId',
      );
      if (wsData['success'] == true && wsData['content'] != null) {
        final rawMetadata = wsData['metadata'];
        final metadata = rawMetadata is Map
            ? Map<String, dynamic>.from(rawMetadata)
            : null;
        return ApiResponse.success(
          wsData['content'].toString(),
          metadata: metadata,
        );
      }
      if (wsData['action']?.toString() == 'ignore') {
        return ApiResponse.ignored();
      }
      final wsError = wsData['error']?.toString();
      if (wsError != null && wsError.isNotEmpty) {
        return ApiResponse.error(wsError);
      }

      return ApiResponse.error('Unknown backend response');
    } catch (e) {
      debugPrint('ApiService: websocket backend call failed: $e');
      return ApiResponse.error('后端WebSocket不可用: $e');
    }
  }

  /// 通过后端发送聊天消息
  /// 这是 sendChatMessageWithRole 的后端版本
  static Future<ApiResponse> sendChatViaBackend({
    required String roleId,
    required String message,
    Map<String, dynamic>? context,
  }) async {
    return callBackendAI(
      roleId: roleId,
      eventType: 'chat',
      content: message,
      context: context,
      timeout: const Duration(seconds: 20),
    );
  }

  /// 通过任务机制提交聊天（异步：后端处理完后通过 WebSocket 推送结果）
  static Future<ChatSubmitResponse> submitChatTask({
    required String roleId,
    required String message,
    required String clientSubmissionId,
    Map<String, dynamic>? context,
  }) async {
    try {
      final mergedContext = Map<String, dynamic>.from(context ?? {});
      mergedContext['client_submission_id'] = clientSubmissionId;
      mergedContext['async'] = true; // 标记使用异步任务机制

      final wsData = await SecureWebSocketClient.instance.request(
        'ai_event',
        {
          'event': {
            'role_id': roleId,
            'event_type': 'chat',
            'content': message,
            'context': mergedContext,
          },
        },
        // Queue response can be delayed by backend load; avoid premature timeout-triggered reconnect.
        timeout: const Duration(seconds: 120),
      );

      // 后端接受异步任务，返回 task_id
      if (wsData['status'] == 'queued' && wsData['task_id'] != null) {
        return ChatSubmitResponse.queued(wsData['task_id'].toString());
      }

      // 后端同步返回（旧后端或不支持 async 时兜底）
      if (wsData['success'] == true && wsData['content'] != null) {
        final rawMetadata = wsData['metadata'];
        final metadata = rawMetadata is Map
            ? Map<String, dynamic>.from(rawMetadata)
            : null;
        return ChatSubmitResponse.completed(
          content: wsData['content'].toString(),
          metadata: metadata,
        );
      }

      if (wsData['action']?.toString() == 'ignore') {
        return ChatSubmitResponse.error('AI chose to ignore');
      }
      final wsError = wsData['error']?.toString();
      if (wsError != null && wsError.isNotEmpty) {
        return ChatSubmitResponse.error(wsError);
      }
      return ChatSubmitResponse.error('Unknown backend response');
    } catch (e) {
      debugPrint('ApiService: submitChatTask failed: $e');
      return ChatSubmitResponse.transportError('后端WebSocket不可用: $e');
    }
  }

  /// 检查后端是否可用
  static Future<bool> isBackendAvailable() async {
    try {
      final response = await SecureWebSocketClient.instance.request(
        'health',
        const <String, dynamic>{},
        timeout: const Duration(seconds: 3),
      );
      return response['status']?.toString() == 'healthy';
    } catch (e) {
      return false;
    }
  }

  /// 读取、压缩并分块上传一张图片，返回 upload_id（不触发 chat_vision）。
  /// 供聚合流程（tool 模式）将图片随 ai_event 一起提交时复用。
  static Future<String> uploadVisionImage({required String imagePath}) async {
    final file = await _readImageFile(imagePath);
    final compressed = _compressImageBytes(file, imagePath);
    return _uploadVisionImageInChunks(
      imageBytes: compressed.$1,
      mimeType: compressed.$2,
    );
  }

  /// 图片识别聊天（通过后端调用 vision API）
  static Future<String> chatWithImage({
    required String imagePath,
    required String userPrompt,
    required String rolePersona,
    String? roleId,
  }) async {
    try {
      // 读取图片并转为 base64
      final file = await _readImageFile(imagePath);
      final compressed = _compressImageBytes(file, imagePath);
      final imageBytes = compressed.$1;
      final mimeType = compressed.$2;

      final uploadId = await _uploadVisionImageInChunks(
        imageBytes: imageBytes,
        mimeType: mimeType,
      );

      final response = await SecureWebSocketClient.instance
          .request('chat_vision', {
            'upload_id': uploadId,
            'mime_type': mimeType,
            'user_prompt': userPrompt,
            'system_prompt': rolePersona,
            'role_id': roleId,
            'run_mode': SettingsService.instance.visionMode,
          }, timeout: const Duration(seconds: 120));
      return response['reply']?.toString() ?? '图片识别失败';
    } catch (e) {
      debugPrint('chatWithImage error: $e');
      return '图片识别失败：$e';
    }
  }

  static Future<String> _uploadVisionImageInChunks({
    required List<int> imageBytes,
    required String mimeType,
  }) async {
    if (imageBytes.isEmpty) {
      throw Exception('image bytes empty');
    }

    final uploadId = _buildVisionUploadId(imageBytes);
    final totalChunks = (imageBytes.length / _visionChunkSize).ceil();
    final initResp = await SecureWebSocketClient.instance
        .request('vision_upload_init', {
          'upload_id': uploadId,
          'total_chunks': totalChunks,
          'mime_type': mimeType,
          'file_size': imageBytes.length,
        }, timeout: const Duration(seconds: 20));

    final resolvedUploadId = initResp['upload_id']?.toString() ?? '';
    if (resolvedUploadId.isEmpty) {
      throw Exception('upload init failed: upload_id missing');
    }

    final uploadedChunkSet = <int>{};
    final uploadedRaw = initResp['uploaded_chunks'];
    if (uploadedRaw is List) {
      for (final item in uploadedRaw) {
        final index = int.tryParse(item.toString());
        if (index != null && index >= 0 && index < totalChunks) {
          uploadedChunkSet.add(index);
        }
      }
    }

    final completed = initResp['completed'] == true;
    if (!completed) {
      for (int chunkIndex = 0; chunkIndex < totalChunks; chunkIndex++) {
        if (uploadedChunkSet.contains(chunkIndex)) {
          continue;
        }
        final start = chunkIndex * _visionChunkSize;
        final end = (start + _visionChunkSize > imageBytes.length)
            ? imageBytes.length
            : start + _visionChunkSize;
        final chunkBytes = imageBytes.sublist(start, end);
        final chunkBase64 = base64Encode(chunkBytes);

        int attempt = 0;
        while (true) {
          attempt += 1;
          try {
            await SecureWebSocketClient.instance
                .request('vision_upload_chunk', {
                  'upload_id': resolvedUploadId,
                  'chunk_index': chunkIndex,
                  'chunk_base64': chunkBase64,
                }, timeout: const Duration(seconds: 20));
            break;
          } catch (e) {
            if (attempt >= _visionChunkMaxRetry) {
              throw Exception(
                'chunk upload failed at index=$chunkIndex, attempts=$attempt, error=$e',
              );
            }
            await Future<void>.delayed(Duration(milliseconds: 250 * attempt));
          }
        }
      }

      await SecureWebSocketClient.instance.request('vision_upload_commit', {
        'upload_id': resolvedUploadId,
      }, timeout: const Duration(seconds: 30));
    }

    return resolvedUploadId;
  }

  static String _buildVisionUploadId(List<int> imageBytes) {
    final digest = md5.convert(imageBytes).toString();
    return 'v1_${digest}_${imageBytes.length}';
  }

  /// 读取图片文件为字节数组
  static Future<List<int>> _readImageFile(String path) async {
    final file = File(path);
    return await file.readAsBytes();
  }

  static (List<int>, String) _compressImageBytes(
    List<int> rawBytes,
    String imagePath,
  ) {
    // 小图直接透传，避免不必要的处理
    const smallImageThreshold = 350 * 1024;
    final ext = imagePath.split('.').last.toLowerCase();
    final fallbackMimeType = ext == 'png' ? 'image/png' : 'image/jpeg';
    if (rawBytes.length <= smallImageThreshold) {
      return (rawBytes, fallbackMimeType);
    }

    try {
      final decoded = img.decodeImage(Uint8List.fromList(rawBytes));
      if (decoded == null) {
        return (rawBytes, fallbackMimeType);
      }

      // 约束最大边，降低上传体积与后端处理时延
      const maxSide = 1280;
      final resized = (decoded.width > maxSide || decoded.height > maxSide)
          ? img.copyResize(
              decoded,
              width: decoded.width >= decoded.height ? maxSide : null,
              height: decoded.height > decoded.width ? maxSide : null,
            )
          : decoded;

      // 统一转 jpeg，质量折中到 78，显著减少体积
      final jpgBytes = img.encodeJpg(resized, quality: 78);
      return (jpgBytes, 'image/jpeg');
    } catch (e) {
      debugPrint(
        'ApiService: image compress failed, fallback to raw bytes: $e',
      );
      return (rawBytes, fallbackMimeType);
    }
  }
}

/// API 响应封装
class ApiResponse {
  final bool success;
  final bool ignored;
  final String? content;
  final Map<String, dynamic>? metadata; // 后端返回的元信息（如 request_id）
  final String? error;

  ApiResponse._({
    required this.success,
    this.ignored = false,
    this.content,
    this.metadata,
    this.error,
  });

  factory ApiResponse.success(
    String content, {
    Map<String, dynamic>? metadata,
  }) {
    return ApiResponse._(success: true, content: content, metadata: metadata);
  }

  factory ApiResponse.error(String error) {
    return ApiResponse._(success: false, error: error);
  }

  factory ApiResponse.ignored() {
    return ApiResponse._(success: false, ignored: true);
  }
}

/// 异步聊天任务提交响应
class ChatSubmitResponse {
  final bool success;
  final String? taskId;
  final String status; // queued / completed / error
  final String? content;
  final Map<String, dynamic>? metadata;
  final String? error;
  final bool isTransportError;

  ChatSubmitResponse._({
    required this.success,
    this.taskId,
    required this.status,
    this.content,
    this.metadata,
    this.error,
    this.isTransportError = false,
  });

  factory ChatSubmitResponse.queued(String taskId) {
    return ChatSubmitResponse._(
      success: true,
      taskId: taskId,
      status: 'queued',
    );
  }

  factory ChatSubmitResponse.completed({
    required String content,
    Map<String, dynamic>? metadata,
  }) {
    return ChatSubmitResponse._(
      success: true,
      status: 'completed',
      content: content,
      metadata: metadata,
    );
  }

  factory ChatSubmitResponse.error(String error) {
    return ChatSubmitResponse._(success: false, status: 'error', error: error);
  }

  factory ChatSubmitResponse.transportError(String error) {
    return ChatSubmitResponse._(
      success: false,
      status: 'error',
      error: error,
      isTransportError: true,
    );
  }
}
