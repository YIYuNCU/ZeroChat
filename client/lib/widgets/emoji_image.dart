import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../services/emoji_transfer_service.dart';
import '../services/secure_websocket_client.dart';

/// Renders protected emoji references from the local transfer cache.
class EmojiImage extends StatefulWidget {
  final String source;
  final BoxFit fit;
  final Map<String, String>? headers;
  final int? cacheWidth;
  final Widget loading;
  final Widget error;

  @visibleForTesting
  final Future<String?> Function(String reference)? resolveLocalPath;

  @visibleForTesting
  final Stream<void>? reconnectStream;

  const EmojiImage({
    super.key,
    required this.source,
    required this.error,
    this.fit = BoxFit.contain,
    this.headers,
    this.cacheWidth,
    this.loading = const Center(
      child: SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
    ),
    this.resolveLocalPath,
    this.reconnectStream,
  });

  @override
  State<EmojiImage> createState() => _EmojiImageState();
}

class _EmojiImageState extends State<EmojiImage> {
  static const int _maxRetries = 5;

  Future<String?>? _localPathFuture;
  StreamSubscription<void>? _reconnectSubscription;
  Timer? _retryTimer;
  int _retryCount = 0;
  bool _resolved = false;
  bool _repairing = false;

  bool get _isTransferReference =>
      EmojiTransferService.isTransferReference(widget.source);

  @override
  void initState() {
    super.initState();
    _configureTransfer();
  }

  @override
  void didUpdateWidget(covariant EmojiImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source) {
      _resetTransfer();
      _configureTransfer();
    }
  }

  void _configureTransfer() {
    if (!_isTransferReference) return;
    _startResolution();
    _reconnectSubscription =
        (widget.reconnectStream ??
                SecureWebSocketClient.instance.onReconnectedStream)
            .listen((_) => _retryImmediately());
  }

  void _resetTransfer() {
    _retryTimer?.cancel();
    _retryTimer = null;
    _reconnectSubscription?.cancel();
    _reconnectSubscription = null;
    _retryCount = 0;
    _resolved = false;
    _repairing = false;
    _localPathFuture = null;
  }

  void _startResolution() {
    final reference = widget.source;
    _localPathFuture = _resolveLocalPath(reference);
  }

  Future<String?> _resolveLocalPath(String reference) async {
    final resolver =
        widget.resolveLocalPath ?? EmojiTransferService.resolveLocalPath;
    final localPath = await resolver(reference);
    if (!mounted || reference != widget.source) {
      return localPath;
    }
    if (localPath != null) {
      _resolved = true;
    } else {
      _scheduleRetry();
    }
    return localPath;
  }

  void _scheduleRetry() {
    if (!mounted || _retryTimer != null || _retryCount >= _maxRetries) {
      return;
    }
    final delaySeconds = 1 << _retryCount;
    _retryCount += 1;
    _retryTimer = Timer(Duration(seconds: delaySeconds), () {
      _retryTimer = null;
      _retryImmediately();
    });
  }

  void _retryImmediately() {
    if (!mounted || _resolved || !_isTransferReference) return;
    _retryTimer?.cancel();
    _retryTimer = null;
    setState(_startResolution);
  }

  Widget _handleFileError(String path) {
    if (!_repairing && _retryCount < _maxRetries) {
      _repairing = true;
      final reference = widget.source;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted || reference != widget.source) return;
        await FileImage(File(path)).evict();
        if (widget.resolveLocalPath == null) {
          await EmojiTransferService.invalidate(reference);
        }
        if (!mounted || reference != widget.source) return;
        _resolved = false;
        _repairing = false;
        _scheduleRetry();
      });
    }
    return widget.error;
  }

  @override
  void dispose() {
    _resetTransfer();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_isTransferReference) {
      return Image.network(
        widget.source,
        headers: widget.headers,
        fit: widget.fit,
        cacheWidth: widget.cacheWidth,
        errorBuilder: (_, _, _) => widget.error,
      );
    }

    return FutureBuilder<String?>(
      future: _localPathFuture,
      builder: (context, snapshot) {
        final localPath = snapshot.data;
        if (localPath == null) {
          return snapshot.connectionState == ConnectionState.waiting
              ? widget.loading
              : widget.error;
        }
        return Image.file(
          File(localPath),
          fit: widget.fit,
          cacheWidth: widget.cacheWidth,
          errorBuilder: (_, _, _) => _handleFileError(localPath),
        );
      },
    );
  }
}
