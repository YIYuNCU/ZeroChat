import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;

/// 图片服务
/// 负责图片选择、复制到本地、路径管理
class ImageService {
  static final ImageService _instance = ImageService._internal();
  factory ImageService() => _instance;
  ImageService._internal();

  static ImageService get instance => _instance;

  final ImagePicker _picker = ImagePicker();
  String? _imagesDir;

  /// 初始化
  static Future<void> init() async {
    final appDir = await getApplicationDocumentsDirectory();
    instance._imagesDir = '${appDir.path}/images';

    // 确保目录存在
    final dir = Directory(instance._imagesDir!);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    debugPrint('ImageService: Initialized at ${instance._imagesDir}');
  }

  /// 获取图片目录
  String get imagesDir => _imagesDir ?? '';

  /// 选择单张图片
  Future<String?> pickImage({ImageSource source = ImageSource.gallery}) async {
    try {
      final XFile? image = await _picker.pickImage(
        source: source,
        maxWidth: 1920,
        maxHeight: 1920,
        imageQuality: 85,
      );

      if (image == null) return null;

      return await _copyToAppDir(image);
    } catch (e) {
      debugPrint('ImageService: Error picking image: $e');
      return null;
    }
  }

  /// 选择多张图片
  Future<List<String>> pickMultipleImages({int maxImages = 9}) async {
    try {
      final List<XFile> images = await _picker.pickMultiImage(
        maxWidth: 1920,
        maxHeight: 1920,
        imageQuality: 85,
        limit: maxImages,
      );

      final List<String> paths = [];
      for (final image in images) {
        final savedPath = await _copyToAppDir(image);
        if (savedPath != null) {
          paths.add(savedPath);
        }
      }

      return paths;
    } catch (e) {
      debugPrint('ImageService: Error picking multiple images: $e');
      return [];
    }
  }

  /// 复制图片到 App 私有目录
  Future<String?> _copyToAppDir(XFile xFile) async {
    try {
      if (_imagesDir == null) await init();

      // 生成唯一文件名
      final ext = path.extension(xFile.path);
      final fileName =
          '${DateTime.now().millisecondsSinceEpoch}_${xFile.name.hashCode}$ext';
      final destPath = '$_imagesDir/$fileName';

      // 复制文件
      final bytes = await xFile.readAsBytes();
      final destFile = File(destPath);
      await destFile.writeAsBytes(bytes);

      debugPrint('ImageService: Saved image to $destPath');
      return destPath;
    } catch (e) {
      debugPrint('ImageService: Error copying image: $e');
      return null;
    }
  }

  /// 删除图片
  Future<bool> deleteImage(String localPath) async {
    try {
      final file = File(localPath);
      if (await file.exists()) {
        await file.delete();
        debugPrint('ImageService: Deleted $localPath');
        return true;
      }
      return false;
    } catch (e) {
      debugPrint('ImageService: Error deleting image: $e');
      return false;
    }
  }

  /// 检查是否是本地路径
  static bool isLocalPath(String path) {
    return path.startsWith('/') ||
        path.contains('\\') ||
        path.startsWith('file://');
  }

  /// 检查文件是否存在
  static Future<bool> fileExists(String localPath) async {
    return File(localPath).exists();
  }
}
