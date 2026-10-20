import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:litertlm/litertlm.dart';

String cleanGeneratedText(String input) {
  final text = input.trim();
  return text.replaceFirstMapped(
    RegExp(r'\b(\w+)[,.!?]?\s+\1([,.!?]?)$', caseSensitive: false),
    (m) => '${m.group(1)}${m.group(2)}',
  );
}

Future<void> visionWorker(SendPort mainPort) async {
  final inbox = ReceivePort();
  mainPort.send(inbox.sendPort);
  Engine? engine;
  try {
    await for (final raw in inbox) {
      final req = Map<String, dynamic>.from(raw as Map);
      final id = req['id'] as int;
      try {
        switch (req['command'] as String) {
          case 'load':
            // Release the old model before loading a new one to limit peak RAM.
            await engine?.dispose();
            engine = null;
            final candidate = Engine(
              engineConfig: EngineConfig(
                modelPath: req['path'] as String,
                backend: Backend.cpu(),
                visionBackend: Backend.cpu(),
                maxNumImages: 1,
                maxNumTokens: 2048,
              ),
            );
            try {
              await candidate.initialize();
              engine = candidate;
            } catch (_) {
              await candidate.dispose();
              rethrow;
            }
            mainPort.send({'id': id, 'type': 'done', 'success': true});
            break;
          case 'analyze':
            if (engine == null) throw StateError('No model is loaded.');
            final question = req['question'] as String;
            final history = (req['history'] as List)
                .map((e) => Map<String, String>.from(e as Map))
                .toList();
            final recent = history.length > 4
                ? history.sublist(history.length - 4)
                : history;
            final contextText = recent
                .map((e) => e['text'] ?? '')
                .where((s) => s.isNotEmpty)
                .join(' ');
            final prompt = contextText.isEmpty
                ? '$question\nAnswer briefly and directly.'
                : 'Look at the attached image. Earlier discussion for context: '
                      '$contextText\nNew question: $question\n'
                      'Answer only the new question, briefly. Do not copy the question.';
            final conversation = await engine.createConversation();
            final buffer = StringBuffer();
            final watch = Stopwatch()..start();
            try {
              await for (final chunk in conversation.sendMessageStream(
                Message.userContents(
                  Contents([
                    Content.text(prompt),
                    Content.imageFile(req['imagePath'] as String),
                  ]),
                ),
                maxOutputTokens: 128,
              )) {
                if (chunk.text.isEmpty) continue;
                buffer.write(chunk.text);
                mainPort.send({'id': id, 'type': 'chunk', 'text': chunk.text});
              }
              watch.stop();
              mainPort.send({
                'id': id,
                'type': 'done',
                'success': true,
                'result': cleanGeneratedText(buffer.toString()),
                'elapsedMs': watch.elapsedMilliseconds,
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
            throw ArgumentError('Unknown worker command');
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
    inbox.close();
  }
}

class VlmService {
  Isolate? _worker;
  ReceivePort? _messages;
  ReceivePort? _exits;
  ReceivePort? _errors;
  StreamSubscription<dynamic>? _messageSubscription;
  StreamSubscription<dynamic>? _exitSubscription;
  StreamSubscription<dynamic>? _errorSubscription;
  SendPort? _port;
  Future<void>? _starting;
  final _pending = <int, Completer<Map<dynamic, dynamic>>>{};
  final _callbacks = <int, void Function(String)>{};
  int _nextId = 0;
  bool _loaded = false;
  bool _disposed = false;

  bool get isLoaded => _loaded;

  Future<void> _start() {
    if (_port != null) return Future.value();
    return _starting ??= _spawn();
  }

  Future<void> _spawn() async {
    final messages = ReceivePort();
    final exits = ReceivePort();
    final errors = ReceivePort();
    _messages = messages;
    _exits = exits;
    _errors = errors;
    final ready = Completer<SendPort>();

    void fail(Object error) {
      if (!ready.isCompleted) ready.completeError(error);
      for (final completer in _pending.values) {
        if (!completer.isCompleted) completer.completeError(error);
      }
      _pending.clear();
      _callbacks.clear();
      _loaded = false;
    }

    _messageSubscription = messages.listen((raw) {
      if (raw is SendPort) {
        _port = raw;
        if (!ready.isCompleted) ready.complete(raw);
        return;
      }
      if (raw is! Map) return;
      final id = raw['id'] as int?;
      if (id == null) return;
      if (raw['type'] == 'chunk') {
        try {
          _callbacks[id]?.call(raw['text'] as String? ?? '');
        } catch (error) {
          debugPrint('Stream callback error: $error');
        }
      } else {
        _callbacks.remove(id);
        final pending = _pending.remove(id);
        if (pending != null && !pending.isCompleted) pending.complete(raw);
      }
    });
    _exitSubscription = exits.listen((_) {
      if (!_disposed) fail(StateError('Vision worker exited unexpectedly.'));
      _port = null;
      _worker = null;
      _starting = null;
    });
    _errorSubscription = errors.listen((raw) {
      fail(StateError('Vision worker error: $raw'));
    });
    try {
      _worker = await Isolate.spawn(
        visionWorker,
        messages.sendPort,
        onExit: exits.sendPort,
        onError: errors.sendPort,
      );
      await ready.future;
    } catch (_) {
      await _closePorts();
      _starting = null;
      rethrow;
    }
  }

  Future<Map<dynamic, dynamic>> _request(
    String command,
    Map<String, dynamic> args, {
    void Function(String)? onToken,
  }) async {
    if (_disposed) throw StateError('VLM service has been disposed.');
    await _start();
    final id = ++_nextId;
    final completer = Completer<Map<dynamic, dynamic>>();
    _pending[id] = completer;
    if (onToken != null) _callbacks[id] = onToken;
    try {
      _port!.send({'id': id, 'command': command, ...args});
      final response = await completer.future;
      if (response['success'] != true) {
        throw StateError(response['error']?.toString() ?? 'Worker failure');
      }
      return response;
    } finally {
      _pending.remove(id);
      _callbacks.remove(id);
    }
  }

  Future<void> loadModel(String path) async {
    _loaded = false;
    await _request('load', {'path': path});
    _loaded = true;
  }

  Future<String> analyzeImage({
    required String imagePath,
    required String question,
    List<Map<String, String>> history = const [],
    void Function(String)? onToken,
  }) async {
    if (!_loaded) throw StateError('Load a model first.');
    final response = await _request('analyze', {
      'imagePath': imagePath,
      'question': question,
      'history': history,
    }, onToken: onToken);
    debugPrint('Inference time: ${response['elapsedMs']}ms');
    return response['result'] as String;
  }

  Future<void> _closePorts() async {
    await _messageSubscription?.cancel();
    await _exitSubscription?.cancel();
    await _errorSubscription?.cancel();
    _messages?.close();
    _exits?.close();
    _errors?.close();
    _messages = null;
    _exits = null;
    _errors = null;
    _port = null;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    if (_port != null) {
      try {
        await _request('dispose', {});
      } catch (e) {
        debugPrint('Worker disposal warning: $e');
      }
    }
    _disposed = true;
    _loaded = false;
    for (final pending in _pending.values) {
      if (!pending.isCompleted) {
        pending.completeError(StateError('Service disposed.'));
      }
    }
    _pending.clear();
    _callbacks.clear();
    _worker?.kill(priority: Isolate.immediate);
    _worker = null;
    await _closePorts();
  }
}
