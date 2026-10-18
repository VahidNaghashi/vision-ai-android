import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:litertlm/litertlm.dart';

String cleanGeneratedText(String text) {
  var result = text.trim();

  // Remove consecutive repetitions of the final word.
  // Example: "The sofa is beige beige."
  //       -> "The sofa is beige."
  final repeatedWord = RegExp(
    r'\b(\w+)[,.!?]?\s+\1([,.!?]?)$',
    caseSensitive: false,
  );

  while (repeatedWord.hasMatch(result)) {
    result = result.replaceFirstMapped(
      repeatedWord,
      (match) => '${match.group(1)}${match.group(2)}',
    );
  }

  return result;
}

// All model operations stay in this isolate. Never send native Engine or
// Conversation objects across isolates.
Future<void> vlmWorker(SendPort mainPort) async {
  final requests = ReceivePort();
  mainPort.send(requests.sendPort);
  Engine? engine;

  try {
    await for (final raw in requests) {
      final request = Map<String, dynamic>.from(raw as Map);
      final id = request['id'] as int;
      final command = request['command'] as String;

      try {
        switch (command) {
          case 'load':
            await engine?.dispose();
            engine = null;
            final candidate = Engine(
              engineConfig: EngineConfig(
                modelPath: request['modelPath'] as String,
                backend: Backend.cpu(),
                visionBackend: Backend.cpu(),
                maxNumImages: 1,
                maxNumTokens: 2048,
              ),
            );
            try {
              await candidate.initialize();
              engine = candidate;
              mainPort.send({'id': id, 'type': 'done', 'success': true});
            } catch (_) {
              await candidate.dispose();
              rethrow;
            }
            break;

          case 'analyze':
            if (engine == null) throw StateError('Model is not loaded.');
            final imagePath = request['imagePath'] as String;
            final question = request['question'] as String;
            final history = (request['history'] as List)
                .map((e) => Map<String, String>.from(e as Map))
                .toList();
            final recent = history.length > 4
                ? history.sublist(history.length - 4)
                : history;
            final previousContext = recent
                .map((turn) => turn['text'] ?? '')
                .where((text) => text.isNotEmpty)
                .join(' ');

            final prompt = previousContext.isEmpty
                ? '$question\nAnswer briefly and directly. Answer only the new question. Do not repeat the question or previous discussion.'
                : '''
            Look at the attached image.

            Earlier discussion for context:
            $previousContext

            New question: $question

            ''';
            final conversation = await engine.createConversation();
            final output = StringBuffer();
            final stopwatch = Stopwatch()..start();
            try {
              await for (final message in conversation.sendMessageStream(
                Message.userContents(
                  Contents([
                    Content.text(prompt),
                    Content.imageFile(imagePath),
                  ]),
                ),
                maxOutputTokens: 128,
              )) {
                final piece = message.text;
                if (piece.isEmpty) continue;
                output.write(piece);
                mainPort.send({'id': id, 'type': 'chunk', 'text': piece});
              }
              stopwatch.stop();
              final rawAnswer = output.toString().trim();
              final cleanedAnswer = cleanGeneratedText(rawAnswer);

              debugPrint('Raw answer: $rawAnswer');
              debugPrint('Cleaned answer: $cleanedAnswer');

              mainPort.send({
                'id': id,
                'type': 'done',
                'success': true,
                'result': cleanedAnswer,
                'elapsedMs': stopwatch.elapsedMilliseconds,
              });
            } finally {
              await conversation.dispose();
            }
            break;

          case 'dispose':
            await engine?.dispose();
            engine = null;
            mainPort.send({'id': id, 'type': 'done', 'success': true});
            return;

          default:
            throw ArgumentError('Unknown command: $command');
        }
      } catch (e) {
        mainPort.send({
          'id': id,
          'type': 'done',
          'success': false,
          'error': e.toString(),
        });
      }
    }
  } finally {
    await engine?.dispose();
    requests.close();
  }
}

class VlmService {
  Isolate? _worker;
  ReceivePort? _inbox;
  ReceivePort? _exitPort;
  ReceivePort? _errorPort;
  StreamSubscription<dynamic>? _inboxSubscription;
  StreamSubscription<dynamic>? _exitSubscription;
  StreamSubscription<dynamic>? _errorSubscription;
  SendPort? _sendPort;
  Future<void>? _starting;
  int _nextId = 0;
  bool _loaded = false;
  bool _disposed = false;
  final _pending = <int, Completer<Map<dynamic, dynamic>>>{};
  final _chunks = <int, void Function(String)>{};

  bool get isLoaded => _loaded;

  Future<void> _start() {
    if (_sendPort != null) return Future.value();
    return _starting ??= _spawn();
  }

  Future<void> _spawn() async {
    final inbox = ReceivePort();
    final exits = ReceivePort();
    final errors = ReceivePort();
    _inbox = inbox;
    _exitPort = exits;
    _errorPort = errors;
    final ready = Completer<SendPort>();

    void failOutstanding(Object error) {
      if (!ready.isCompleted) ready.completeError(error);
      for (final pending in _pending.values) {
        if (!pending.isCompleted) pending.completeError(error);
      }
      _pending.clear();
      _chunks.clear();
      _loaded = false;
    }

    _inboxSubscription = inbox.listen((raw) {
      if (raw is SendPort) {
        _sendPort = raw;
        if (!ready.isCompleted) ready.complete(raw);
        return;
      }
      if (raw is! Map) return;
      final id = raw['id'] as int?;
      if (id == null) return;
      if (raw['type'] == 'chunk') {
        try {
          _chunks[id]?.call(raw['text'] as String? ?? '');
        } catch (error) {
          debugPrint('UI stream callback error: $error');
        }
        return;
      }
      _chunks.remove(id);
      final waiting = _pending.remove(id);
      if (waiting != null && !waiting.isCompleted) waiting.complete(raw);
    });
    _exitSubscription = exits.listen((_) {
      if (!_disposed) {
        failOutstanding(StateError('VLM worker unexpectedly exited.'));
      }
      _sendPort = null;
      _worker = null;
    });
    _errorSubscription = errors.listen((raw) {
      failOutstanding(StateError('VLM worker error: $raw'));
    });

    try {
      _worker = await Isolate.spawn(
        vlmWorker,
        inbox.sendPort,
        onExit: exits.sendPort,
        onError: errors.sendPort,
      );
      await ready.future;
    } catch (_) {
      await _shutdownPorts();
      rethrow;
    }
  }

  Future<Map<dynamic, dynamic>> _request(
    String command,
    Map<String, dynamic> parameters, {
    void Function(String)? onToken,
  }) async {
    if (_disposed) throw StateError('VLM service disposed.');
    await _start();
    final id = ++_nextId;
    final completion = Completer<Map<dynamic, dynamic>>();
    _pending[id] = completion;
    if (onToken != null) _chunks[id] = onToken;

    try {
      _sendPort!.send({'id': id, 'command': command, ...parameters});
      final result = await completion.future;
      if (result['success'] != true) {
        throw StateError(result['error']?.toString() ?? 'VLM request failed');
      }
      return result;
    } finally {
      _pending.remove(id);
      _chunks.remove(id);
    }
  }

  Future<void> loadModel(String path) async {
    _loaded = false;
    await _request('load', {'modelPath': path});
    _loaded = true;
  }

  Future<String> analyzeImage({
    required String imagePath,
    required String question,
    List<Map<String, String>> history = const [],
    void Function(String)? onToken,
  }) async {
    if (!_loaded) throw StateError('Load the model first.');
    final result = await _request('analyze', {
      'imagePath': imagePath,
      'question': question,
      'history': history,
    }, onToken: onToken);
    debugPrint('Worker inference time: ${result['elapsedMs']} ms');
    return result['result'] as String;
  }

  Future<void> _shutdownPorts() async {
    await _inboxSubscription?.cancel();
    await _exitSubscription?.cancel();
    await _errorSubscription?.cancel();
    _inbox?.close();
    _exitPort?.close();
    _errorPort?.close();
    _inbox = null;
    _exitPort = null;
    _errorPort = null;
    _inboxSubscription = null;
    _exitSubscription = null;
    _errorSubscription = null;
    _sendPort = null;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    if (_sendPort != null) {
      try {
        await _request('dispose', {});
      } catch (error) {
        debugPrint('Worker dispose warning: $error');
      }
    }
    _disposed = true;
    _loaded = false;
    for (final pending in _pending.values) {
      if (!pending.isCompleted) {
        pending.completeError(StateError('VLM service disposed.'));
      }
    }
    _pending.clear();
    _chunks.clear();
    _worker?.kill(priority: Isolate.immediate);
    _worker = null;
    await _shutdownPorts();
  }
}
