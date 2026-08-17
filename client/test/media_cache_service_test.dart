import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zerochat/services/media_cache_service.dart';

void main() {
  testWidgets('configures a bounded decoded image cache', (tester) async {
    final imageCache = PaintingBinding.instance.imageCache;
    final previousMaximumSize = imageCache.maximumSize;
    final previousMaximumBytes = imageCache.maximumSizeBytes;
    addTearDown(() {
      imageCache.maximumSize = previousMaximumSize;
      imageCache.maximumSizeBytes = previousMaximumBytes;
    });

    MediaCacheService.configureImageCache();

    expect(imageCache.maximumSize, MediaCacheService.imageCacheMaximumSize);
    expect(
      imageCache.maximumSizeBytes,
      MediaCacheService.imageCacheMaximumBytes,
    );
  });
}
