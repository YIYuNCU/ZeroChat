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
    _resolvePath();
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

  Future<void> _resolvePath() async {
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

    if (!url.startsWith('http')) {
      debugPrint('SmartAvatarImage: treating non-http url as local file: $url');
      return Image.file(
        File(url),
        width: widget.width,
        height: widget.height,
        fit: widget.fit,
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
        errorBuilder: (_, __, ___) =>
            widget.fallbackBuilder?.call() ?? const SizedBox.shrink(),
      );
    }

    return widget.fallbackBuilder?.call() ?? const SizedBox.shrink();
  }
}
