import 'package:flutter/painting.dart';

import 'avatar_cache_service.dart';
import 'emoji_transfer_service.dart';

/// Coordinates bounded in-memory and on-disk media caches.
class MediaCacheService {
  MediaCacheService._();

  static const int imageCacheMaximumSize = 100;
  static const int imageCacheMaximumBytes = 64 * 1024 * 1024;

  static void configureImageCache() {
    final imageCache = PaintingBinding.instance.imageCache;
    imageCache.maximumSize = imageCacheMaximumSize;
    imageCache.maximumSizeBytes = imageCacheMaximumBytes;
  }

  static void clearInMemoryImageCache() {
    final imageCache = PaintingBinding.instance.imageCache;
    imageCache.clear();
    imageCache.clearLiveImages();
  }

  /// Cleans existing media files after startup without delaying the first frame.
  static Future<void> trimDiskCaches() {
    return Future.wait([
      AvatarCacheService.trimToBudget(),
      EmojiTransferService.trimToBudget(),
    ]);
  }
}
