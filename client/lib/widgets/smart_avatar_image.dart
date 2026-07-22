import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../services/avatar_cache_service.dart';

class SmartAvatarImage extends StatefulWidget {
  final String? remoteUrl;
  final String cacheKey;
  final String? backendHash;
  final double width;
  final double height;
  final BoxFit fit;
  final Widget Function()? fallbackBuilder;

  const SmartAvatarImage({
    super.key,
    required this.remoteUrl,
    required this.cacheKey,
    this.backendHash,
    required this.width,
    required this.height,
    this.fit = BoxFit.cover,
    this.fallbackBuilder,
  });

  @override
  State<SmartAvatarImage> createState() => _SmartAvatarImageState();
}

class _SmartAvatarImageState extends State<SmartAvatarImage> {
  String? _localPath;
  bool _hasFailed = false;

  @override
  void initState() {
    super.initState();
    // 先同步查内存解析表：命中则首帧直接显示图片，消除回退图标闪烁。
    final url = widget.remoteUrl;
    if (url != null && url.isNotEmpty && url.startsWith('http')) {
      _localPath = AvatarCacheService.peekResolvedPath(
        cacheKey: widget.cacheKey,
        remoteUrl: url,
        backendHash: widget.backendHash,
      );
    }
    // 仍需异步确认（刷新 LRU、处理首次未命中/hash 变化），但已避免闪烁。
    if (_localPath == null) {
      _resolvePath();
    } else {
      // 已有内存命中，仅在后台刷新 LRU 时间戳，不触发可见的加载态。
      _resolvePath(silent: true);
    }
  }

  @override
  void didUpdateWidget(covariant SmartAvatarImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.remoteUrl != widget.remoteUrl ||
        oldWidget.backendHash != widget.backendHash ||
        oldWidget.cacheKey != widget.cacheKey) {
      _hasFailed = false;
      _resolvePath();
    }
  }

  /// [silent] 为 true 时，已有内存命中路径，仅后台刷新，成功后若路径不变不重建。
  Future<void> _resolvePath({bool silent = false}) async {
    final url = widget.remoteUrl;
    if (url == null || url.isEmpty || !url.startsWith('http')) {
      debugPrint('SmartAvatarImage: invalid remoteUrl=$url for cacheKey=${widget.cacheKey}');
      if (mounted) {
        setState(() {
          _localPath = null;
          _hasFailed = true;
        });
      }
      return;
    }

    final local = await AvatarCacheService.resolveAvatarPath(
      cacheKey: widget.cacheKey,
      remoteUrl: url,
      backendHash: widget.backendHash,
    );

    if (!mounted) return;
    // 静默刷新且路径未变：无需 setState，避免多余重建。
    if (silent && local == _localPath) return;
    setState(() {
      _localPath = local;
      _hasFailed = local == null;
    });
    if (local == null) {
      debugPrint('SmartAvatarImage: failed to resolve avatar for $url');
    }
  }

  @override
  Widget build(BuildContext context) {
    final url = widget.remoteUrl;

    if (url == null || url.isEmpty) {
      return widget.fallbackBuilder?.call() ?? const SizedBox.shrink();
    }

    // 按显示尺寸 × 设备像素比解码，避免把全分辨率位图塞进图片缓存。
    final dpr = MediaQuery.maybeOf(context)?.devicePixelRatio ?? 1.0;
    final cacheW = (widget.width * dpr).round();
    final cacheH = (widget.height * dpr).round();

    if (!url.startsWith('http')) {
      debugPrint('SmartAvatarImage: treating non-http url as local file: $url');
      return Image.file(
        File(url),
        width: widget.width,
        height: widget.height,
        fit: widget.fit,
        cacheWidth: cacheW,
        cacheHeight: cacheH,
        errorBuilder: (_, __, ___) =>
            widget.fallbackBuilder?.call() ?? const SizedBox.shrink(),
      );
    }

    if (_localPath != null && _localPath!.isNotEmpty) {
      return Image.file(
        File(_localPath!),
        width: widget.width,
        height: widget.height,
        fit: widget.fit,
        cacheWidth: cacheW,
        cacheHeight: cacheH,
        errorBuilder: (_, __, ___) =>
            widget.fallbackBuilder?.call() ?? const SizedBox.shrink(),
      );
    }

    return widget.fallbackBuilder?.call() ?? const SizedBox.shrink();
  }
}
