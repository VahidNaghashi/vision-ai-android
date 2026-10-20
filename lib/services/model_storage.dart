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
        'ab7838cdfc8f77e54d8ca45eadceb20452d9f01e4bfade03e5dce27911b27e42',
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

  static final RegExp _contentRangePattern = RegExp(r'^bytes (\d+)-(\d+)/(\d+)$');

  static int? _contentLength(Headers headers) {
    return int.tryParse(headers.value(Headers.contentLengthHeader) ?? '');
  }

  /// Downloads to a persistent .download file. Only a size-checked and (where
  /// configured) SHA-256 verified file is promoted to its final model path.
  /// A failed/cancelled transfer retains its bytes for the next attempt.
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
        // Keep 416 for our explicit recovery path.
        validateStatus: (status) =>
            status != null && ((status >= 200 && status < 300) || status == 416),
      ),
    );

    try {
      // At most one restart if a partial file cannot be resumed.
      for (var attempt = 0; attempt < 2; attempt++) {
        final previousBytes = await partial.exists() ? await partial.length() : 0;
        final response = await dio.get<ResponseBody>(
          model.url,
          options: Options(
            responseType: ResponseType.stream,
            headers: previousBytes > 0
                ? <String, String>{'Range': 'bytes=$previousBytes-'}
                : null,
          ),
          cancelToken: cancelToken,
        );
        final status = response.statusCode;

        if (status == 416) {
          // May happen when an earlier transfer completed but app was killed
          // before verification/rename. Validate the retained file first.
          if (previousBytes >= model.minimumBytes) {
            try {
              await _verify(partial, model);
              await _promote(partial, destination);
              return destination.path;
            } on StateError {
              // An incorrect partial must be replaced, not appended.
            }
          }
          if (attempt == 0) {
            if (await partial.exists()) await partial.delete();
            continue;
          }
          throw StateError('Server rejected download range (HTTP 416).');
        }

        if (status != 200 && status != 206) {
          throw StateError('Unexpected download status: HTTP $status');
        }

        var offset = 0;
        int? total;
        if (status == 206) {
          final rawRange = response.headers.value('content-range');
          final match = rawRange == null ? null : _contentRangePattern.firstMatch(rawRange);
          if (match == null || previousBytes == 0 ||
              int.parse(match.group(1)!) != previousBytes) {
            throw StateError('Invalid Content-Range in resume response: $rawRange');
          }
          offset = previousBytes;
          total = int.parse(match.group(3)!);
        } else {
          // Server ignored Range. Start a fresh download rather than appending
          // duplicate data to the existing partial file.
          total = _contentLength(response.headers);
        }

        // A streamed response must be consumed (or its connection released).
        // RandomAccessFile lets us resume without allocating GBs in memory.
        final sink = await partial.open(mode: offset > 0 ? FileMode.append : FileMode.write);
        var received = offset;
        try {
          onProgress(received, total ?? -1);
          await for (final chunk in response.data!.stream) {
            if (cancelToken?.isCancelled == true) {
              throw DioException(
                requestOptions: response.requestOptions,
                type: DioExceptionType.cancel,
                error: 'Download cancelled',
              );
            }
            await sink.writeFrom(chunk);
            received += chunk.length;
            onProgress(received, total ?? -1);
          }
          await sink.flush();
        } finally {
          await sink.close();
        }

        final size = await partial.length();
        if (total != null && size != total) {
          throw StateError('Transfer incomplete: $size of $total bytes. Retry to resume.');
        }
        await _verify(partial, model);
        await _promote(partial, destination);
        return destination.path;
      }
      throw StateError('Unable to resume download. Please retry.');
    } finally {
      dio.close();
      // Intentionally keep .download on error, cancellation or checksum failure.
    }
  }

  static Future<void> _verify(File file, ModelSpec model) async {
    final size = await file.length();
    if (size < model.minimumBytes) {
      throw StateError('Downloaded file too small ($size bytes). Retry to resume.');
    }
    if (model.sha256Hex != null) {
      final actual = (await sha256.bind(file.openRead()).first).toString().toLowerCase();
      final expected = model.sha256Hex!.toLowerCase();
      if (actual != expected) {
        throw StateError('SHA-256 mismatch. Partial file kept for diagnosis. '
            'Expected: $expected; actual: $actual; bytes: $size. '
            'Use resetDownload() to discard it before redownloading.');
      }
    }
  }

  static Future<void> _promote(File partial, File destination) async {
    if (await destination.exists()) await destination.delete();
    await partial.rename(destination.path);
  }

  /// Explicitly discard the temporary file when a hash mismatch is confirmed.
  /// Does not remove an installed, verified model.
  static Future<void> resetDownload(ModelSpec model) async {
    final file = await modelFile(model);
    final partial = File('${file.path}.download');
    if (await partial.exists()) await partial.delete();
  }

  static Future<void> delete(ModelSpec model) async {
    final file = await modelFile(model);
    if (await file.exists()) await file.delete();
    await resetDownload(model);
  }
}
