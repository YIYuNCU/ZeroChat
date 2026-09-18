import 'dart:io';
import 'package:flutter/material.dart';
import '../services/remote_media_cache.dart';
import '../services/settings_service.dart';
import '../services/secure_backend_client.dart';

class RemoteMediaBackground extends StatelessWidget {
  const RemoteMediaBackground({
    super.key,
    required this.url,
    required this.child,
  });
  final String url;
  final Widget child;
  @override
  Widget build(BuildContext context) => ColoredBox(
    color: const Color(0xFFEDEDED),
    child: Stack(
      fit: StackFit.expand,
      children: [
        if (url.isNotEmpty)
          Positioned.fill(
            child: url.startsWith('http')
                ? RemoteMediaImage(
                    url,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => const SizedBox.shrink(),
                  )
                : Image.file(
                    File(url),
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => const SizedBox.shrink(),
                  ),
          ),
        child,
      ],
    ),
  );
}

class RemoteMediaImage extends StatefulWidget {
  const RemoteMediaImage(
    this.url, {
    super.key,
    this.width,
    this.height,
    this.fit,
    this.cacheWidth,
    this.errorBuilder,
    this.headers,
  });
  final String url;
  final double? width, height;
  final BoxFit? fit;
  final int? cacheWidth;
  final ImageErrorWidgetBuilder? errorBuilder;
  final Map<String, String>? headers;
  @override
  State<RemoteMediaImage> createState() => _RemoteMediaImageState();
}

class _RemoteMediaImageState extends State<RemoteMediaImage> {
  late Future<File?> _file;
  bool _repaired = false;
  String _scope = '';
  void _refresh() {
    final scope =
        '${SettingsService.instance.backendUrl}|${SecureBackendClient.cacheIdentity}';
    if (scope == _scope) return;
    _scope = scope;
    setState(() {
      _repaired = false;
      _file = RemoteMediaCache.resolve(widget.url);
    });
  }

  @override
  void initState() {
    super.initState();
    _scope =
        '${SettingsService.instance.backendUrl}|${SecureBackendClient.cacheIdentity}';
    _file = RemoteMediaCache.resolve(widget.url);
    SettingsService.instance.addListener(_refresh);
  }

  @override
  void dispose() {
    SettingsService.instance.removeListener(_refresh);
    super.dispose();
  }

  @override
  void didUpdateWidget(RemoteMediaImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _repaired = false;
      _file = RemoteMediaCache.resolve(widget.url);
    }
  }

  Widget _error(BuildContext context, Object error, StackTrace? stack) {
    if (!_repaired) {
      _repaired = true;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        await RemoteMediaCache.evict(widget.url);
        if (mounted) {
          setState(() {
            _file = RemoteMediaCache.resolve(widget.url);
          });
        }
      });
    }
    return widget.errorBuilder?.call(context, error, stack) ??
        const Icon(Icons.broken_image_outlined);
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<File?>(
    key: ValueKey('${widget.url}|$_scope'),
    future: _file,
    builder: (context, snapshot) {
      if (snapshot.data != null) {
        return Image.file(
          snapshot.data!,
          width: widget.width,
          height: widget.height,
          fit: widget.fit,
          cacheWidth: widget.cacheWidth,
          errorBuilder: _error,
        );
      }
      if (snapshot.connectionState == ConnectionState.done) {
        return widget.errorBuilder?.call(
              context,
              snapshot.error ?? StateError('Image unavailable'),
              null,
            ) ??
            const Icon(Icons.broken_image_outlined);
      }
      return SizedBox(width: widget.width, height: widget.height);
    },
  );
}
