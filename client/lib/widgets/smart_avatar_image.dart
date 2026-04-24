import 'dart:io';

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
      _resolvePath();
    }
  }

  Future<void> _resolvePath() async {
    final url = widget.remoteUrl;
    if (url == null || url.isEmpty || !url.startsWith('http')) {
      if (mounted) {
        setState(() {
          _localPath = null;
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
    });
  }

  @override
  Widget build(BuildContext context) {
    final url = widget.remoteUrl;

    if (url == null || url.isEmpty) {
      return widget.fallbackBuilder?.call() ?? const SizedBox.shrink();
    }

    if (!url.startsWith('http')) {
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

    // Keep UI stable while cache download runs in AvatarCacheService.
    return widget.fallbackBuilder?.call() ?? const SizedBox.shrink();
  }
}
