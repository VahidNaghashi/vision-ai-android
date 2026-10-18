import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class ModelStorage {
  static const String modelName = 'SmolVLM2-500M.litertlm';
  static const String modelUrl =
      'https://huggingface.co/litert-community/SmolVLM2-500M/'
      'resolve/main/SmolVLM2-500M.litertlm';
  static const int minimumSize = 100 * 1024 * 1024;

  static Future<File> getModelFile() async {
    final directory = await getApplicationSupportDirectory();
    final modelDirectory = Directory(p.join(directory.path, 'models'));
    await modelDirectory.create(recursive: true);
    return File(p.join(modelDirectory.path, modelName));
  }

  static Future<String?> getInstalledModelPath() async {
    final file = await getModelFile();
    if (!await file.exists()) return null;
    if (await file.length() < minimumSize) return null;
    return file.path;
  }

  static Future<String> downloadModel({
    required void Function(int received, int total) onProgress,
    CancelToken? cancelToken,
  }) async {
    final current = await getInstalledModelPath();
    if (current != null) return current;
    final destination = await getModelFile();
    final temp = File('${destination.path}.download');
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 30),
        receiveTimeout: const Duration(minutes: 5),
        followRedirects: true,
        maxRedirects: 10,
      ),
    );
    try {
      if (await temp.exists()) await temp.delete();
      await dio.download(
        modelUrl,
        temp.path,
        cancelToken: cancelToken,
        onReceiveProgress: onProgress,
      );
      if (await temp.length() < minimumSize) {
        throw StateError('Downloaded model file is unexpectedly small.');
      }
      if (await destination.exists()) await destination.delete();
      await temp.rename(destination.path);
      return destination.path;
    } finally {
      dio.close();
      if (await temp.exists()) await temp.delete();
    }
  }
}
