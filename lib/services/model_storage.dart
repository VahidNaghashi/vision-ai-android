import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

enum VisionModel { smol, gemmaE2B }

class ModelSpec {
  const ModelSpec({
    required this.id,
    required this.title,
    required this.fileName,
    required this.url,
    required this.minimumBytes,
    required this.sizeLabel,
    this.sha256Hex,
  });

  final VisionModel id;
  final String title;
  final String fileName;
  final String url;
  final int minimumBytes;
  final String sizeLabel;
  final String? sha256Hex;
}

class ModelStorage {
  static const smol = ModelSpec(
    id: VisionModel.smol,
    title: 'SmolVLM2-500M',
    fileName: 'SmolVLM2-500M.litertlm',
    url:
        'https://huggingface.co/litert-community/SmolVLM2-500M/'
        'resolve/main/SmolVLM2-500M.litertlm',
    minimumBytes: 100 * 1024 * 1024,
    sizeLabel: '~361 MB',
  );

  static const gemma = ModelSpec(
    id: VisionModel.gemmaE2B,
    title: 'Gemma 4 E2B',
    fileName: 'gemma-4-E2B-it.litertlm',
    url:
        'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/'
        'resolve/f85d401db3cb8d5e119c199871ca17dfcdf70cca/'
        'gemma-4-E2B-it.litertlm',
    minimumBytes: 2 * 1024 * 1024 * 1024,
    sizeLabel: '~2.59 GB',
    sha256Hex:
        '181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c',
  );

  static const models = [smol, gemma];

  static Future<Directory> _modelDirectory() async {
    final support = await getApplicationSupportDirectory();
    final directory = Directory(p.join(support.path, 'models'));
    await directory.create(recursive: true);
    return directory;
  }

  static Future<File> modelFile(ModelSpec model) async {
    final directory = await _modelDirectory();
    return File(p.join(directory.path, model.fileName));
  }

  static Future<File> _selectionFile() async {
    final support = await getApplicationSupportDirectory();
    return File(p.join(support.path, 'selected_vision_model.txt'));
  }

  static Future<VisionModel> selectedModel() async {
    final file = await _selectionFile();
    if (!await file.exists()) return VisionModel.smol;
    final value = (await file.readAsString()).trim();
    return value == VisionModel.gemmaE2B.name
        ? VisionModel.gemmaE2B
        : VisionModel.smol;
  }

  static Future<void> saveSelectedModel(VisionModel model) async {
    final file = await _selectionFile();
    await file.writeAsString(model.name, flush: true);
  }

  static Future<String?> installedPath(ModelSpec model) async {
    final file = await modelFile(model);
    if (!await file.exists()) return null;
    if (await file.length() < model.minimumBytes) return null;
    return file.path;
  }

  static Future<bool> isInstalled(ModelSpec model) async =>
      await installedPath(model) != null;

  static Future<String> download(
    ModelSpec model, {
    required void Function(int received, int total) onProgress,
    CancelToken? cancelToken,
  }) async {
    final existing = await installedPath(model);
    if (existing != null) return existing;

    final destination = await modelFile(model);
    final partial = File('${destination.path}.download');
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 40),
        receiveTimeout: const Duration(minutes: 5),
        followRedirects: true,
        maxRedirects: 10,
      ),
    );
    try {
      if (await partial.exists()) await partial.delete();
      await dio.download(
        model.url,
        partial.path,
        cancelToken: cancelToken,
        onReceiveProgress: onProgress,
      );
      if (await partial.length() < model.minimumBytes) {
        throw StateError('Downloaded file is smaller than expected.');
      }
      if (model.sha256Hex != null) {
        final digest = await sha256.bind(partial.openRead()).first;
        if (digest.toString().toLowerCase() != model.sha256Hex) {
          throw StateError(
            'SHA-256 verification failed. Try downloading again.',
          );
        }
      }
      if (await destination.exists()) await destination.delete();
      await partial.rename(destination.path);
      return destination.path;
    } finally {
      dio.close();
      if (await partial.exists()) await partial.delete();
    }
  }

  static Future<void> delete(ModelSpec model) async {
    final file = await modelFile(model);
    if (await file.exists()) await file.delete();
  }
}
