import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import 'services/model_storage.dart';
import 'services/vllm_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const VisionApp());
}

class VisionApp extends StatelessWidget {
  const VisionApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Vision AI',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF4055B8)),
      scaffoldBackgroundColor: const Color(0xFFF6F7FB),
      appBarTheme: const AppBarTheme(backgroundColor: Color(0xFFF6F7FB)),
    ),
    home: const VisionHomePage(),
  );
}

class VisionHomePage extends StatefulWidget {
  const VisionHomePage({super.key});

  @override
  State<VisionHomePage> createState() => _VisionHomePageState();
}

class _VisionHomePageState extends State<VisionHomePage> {
  final VlmService _vlm = VlmService();
  final ImagePicker _picker = ImagePicker();
  final CancelToken _cancelDownload = CancelToken();
  final TextEditingController _question = TextEditingController();
  final ScrollController _chatScroll = ScrollController();
  final List<Map<String, String>> _messages = [];

  XFile? _image;
  String _partialAnswer = '';
  String _status = 'Checking for an installed model...';
  String? _error;
  bool _busy = true;
  bool _ready = false;
  bool _downloading = false;
  bool _analyzing = false;
  double? _progress;
  double? _lastInferenceSeconds;

  @override
  void initState() {
    super.initState();
    _setupModel();
  }

  Future<void> _setupModel() async {
    if (!mounted) return;
    setState(() {
      _busy = true;
      _ready = false;
      _downloading = false;
      _progress = null;
      _error = null;
      _status = 'Checking for an installed model...';
    });
    try {
      var modelPath = await ModelStorage.getInstalledModelPath();
      if (modelPath == null) {
        if (!mounted) return;
        setState(() {
          _status = 'Downloading SmolVLM2 (first launch)...';
          _downloading = true;
        });
        modelPath = await ModelStorage.downloadModel(
          cancelToken: _cancelDownload,
          onProgress: (received, total) {
            if (!mounted) return;
            setState(() {
              _progress = total > 0 ? (received / total).clamp(0.0, 1.0) : null;
            });
          },
        );
      }
      if (!mounted) return;
      setState(() {
        _downloading = false;
        _status = 'Initializing on-device vision model...';
      });
      await _vlm.loadModel(modelPath);
      if (!mounted) return;
      setState(() {
        _ready = true;
        _status = 'Model ready • On-device';
      });
    } catch (e, stack) {
      debugPrint('Model setup failed: $e');
      debugPrintStack(stackTrace: stack);
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _status = 'Model setup failed';
      });
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _downloading = false;
        });
      }
    }
  }

  Future<void> _chooseImage(ImageSource source) async {
    if (_busy) return;
    try {
      final image = await _picker.pickImage(
        source: source,
        maxWidth: 1024,
        imageQuality: 85,
      );
      if (!mounted || image == null) return;
      setState(() {
        _image = image;
        _messages.clear();
        _partialAnswer = '';
        _lastInferenceSeconds = null;
        _error = null;
        _question.text = 'Describe this image in one sentence.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Image selection failed: $e');
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_chatScroll.hasClients) return;
      _chatScroll.animateTo(
        _chatScroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _sendQuestion() async {
    if (_busy || !_ready || _image == null) return;
    final text = _question.text.trim();
    if (text.isEmpty) return;
    final history = _messages.map((m) => Map<String, String>.from(m)).toList();

    setState(() {
      _busy = true;
      _analyzing = true;
      _error = null;
      _partialAnswer = '';
      _lastInferenceSeconds = null;
      _messages.add({'role': 'user', 'text': text});
      _question.clear();
    });
    _scrollToBottom();
    // Allow the progress indicator to appear before any native work starts.
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;

    final stopwatch = Stopwatch()..start();
    try {
      final answer = await _vlm.analyzeImage(
        imagePath: _image!.path,
        question: text,
        history: history,
        onToken: (fragment) {
          if (!mounted) return;
          setState(() => _partialAnswer += fragment);
          _scrollToBottom();
        },
      );
      stopwatch.stop();
      if (!mounted) return;
      setState(() {
        _messages.add({'role': 'assistant', 'text': answer});
        _partialAnswer = '';
        _lastInferenceSeconds = stopwatch.elapsedMilliseconds / 1000;
      });
      _scrollToBottom();
    } catch (e, stack) {
      debugPrint('Inference failed: $e');
      debugPrintStack(stackTrace: stack);
      if (!mounted) return;
      setState(() {
        _error = 'Analysis failed: $e';
        _partialAnswer = '';
        if (_messages.isNotEmpty && _messages.last['role'] == 'user') {
          _messages.removeLast();
        }
        _question.text = text;
      });
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _analyzing = false;
        });
      }
    }
  }

  Widget _modelCard() => Card(
    elevation: 0,
    color: Colors.white,
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                _ready ? Icons.verified : Icons.memory,
                color: _ready ? Colors.green : Colors.indigo,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  _status,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              if (_ready) const Icon(Icons.wifi_off, size: 20),
            ],
          ),
          if (_downloading) ...[
            const SizedBox(height: 12),
            LinearProgressIndicator(value: _progress),
            const SizedBox(height: 6),
            Text(
              _progress == null
                  ? 'Downloading model...'
                  : '${(_progress! * 100).toStringAsFixed(1)}% downloaded',
            ),
          ] else if (_busy && !_ready) ...[
            const SizedBox(height: 12),
            const LinearProgressIndicator(),
          ],
          if (_error != null && !_ready && !_busy) ...[
            const SizedBox(height: 10),
            SelectableText(_error!, style: const TextStyle(color: Colors.red)),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: _setupModel,
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
            ),
          ],
        ],
      ),
    ),
  );

  Widget _imagePanel() => Container(
    height: 235,
    width: double.infinity,
    clipBehavior: Clip.antiAlias,
    decoration: BoxDecoration(
      color: const Color(0xFFE8ECF6),
      borderRadius: BorderRadius.circular(20),
    ),
    child: _image == null
        ? const Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.add_photo_alternate_outlined, size: 54),
              SizedBox(height: 8),
              Text('Choose a picture to start visual chat'),
            ],
          )
        : Image.file(File(_image!.path), fit: BoxFit.contain),
  );

  Widget _chatPanel() {
    final entries = <Map<String, String>>[
      ..._messages,
      if (_analyzing) {'role': 'assistant', 'text': _partialAnswer},
    ];
    if (entries.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(
          child: Text(
            'Your questions and answers will appear here.',
            style: TextStyle(color: Colors.black54),
          ),
        ),
      );
    }
    return SizedBox(
      height: 310,
      child: ListView.builder(
        controller: _chatScroll,
        itemCount: entries.length,
        itemBuilder: (context, index) {
          final entry = entries[index];
          final isUser = entry['role'] == 'user';
          final generating = _analyzing && index == entries.length - 1;
          final content = entry['text'] ?? '';
          return Align(
            alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
            child: Container(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.sizeOf(context).width * 0.78,
              ),
              padding: const EdgeInsets.all(13),
              margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 5),
              decoration: BoxDecoration(
                color: isUser ? const Color(0xFFE0E7FF) : Colors.white,
                borderRadius: BorderRadius.circular(17),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    isUser ? 'You' : 'Vision AI',
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    generating && content.isEmpty ? 'Thinking...' : content,
                    style: const TextStyle(fontSize: 15, height: 1.4),
                  ),
                  if (generating) ...[
                    const SizedBox(height: 8),
                    const SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ],
                  if (!isUser && !generating && content.isNotEmpty)
                    Align(
                      alignment: Alignment.centerRight,
                      child: IconButton(
                        tooltip: 'Copy answer',
                        icon: const Icon(Icons.copy, size: 18),
                        onPressed: () async {
                          await Clipboard.setData(ClipboardData(text: content));
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Answer copied')),
                          );
                        },
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  void dispose() {
    _cancelDownload.cancel('App closed');
    _question.dispose();
    _chatScroll.dispose();
    // Disposal of native resources is asynchronous; isolate handles its cleanup.
    _vlm.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Vision AI', style: TextStyle(fontWeight: FontWeight.bold)),
          Text(
            'Private visual conversations',
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.normal),
          ),
        ],
      ),
      actions: const [
        Padding(
          padding: EdgeInsets.only(right: 16),
          child: Icon(Icons.visibility_outlined),
        ),
      ],
    ),
    body: SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _modelCard(),
          const SizedBox(height: 14),
          _imagePanel(),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _busy
                      ? null
                      : () => _chooseImage(ImageSource.camera),
                  icon: const Icon(Icons.camera_alt),
                  label: const Text('Camera'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _busy
                      ? null
                      : () => _chooseImage(ImageSource.gallery),
                  icon: const Icon(Icons.photo_library),
                  label: const Text('Gallery'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          const Text(
            'Conversation',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          _chatPanel(),
          if (_lastInferenceSeconds != null)
            Text(
              'Last response: ${_lastInferenceSeconds!.toStringAsFixed(2)} s',
              textAlign: TextAlign.right,
              style: const TextStyle(fontSize: 12, color: Colors.black54),
            ),
          const SizedBox(height: 12),
          TextField(
            controller: _question,
            maxLines: 2,
            decoration: InputDecoration(
              hintText: 'Ask about this image...',
              filled: true,
              fillColor: Colors.white,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
            onSubmitted: (_) => _sendQuestion(),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              ActionChip(
                label: const Text('Describe'),
                onPressed: _busy
                    ? null
                    : () => _question.text =
                          'Describe this image in one sentence.',
              ),
              ActionChip(
                label: const Text('Identify objects'),
                onPressed: _busy
                    ? null
                    : () => _question.text = 'What objects are visible?',
              ),
              ActionChip(
                label: const Text('Read text'),
                onPressed: _busy
                    ? null
                    : () => _question.text = 'Read the visible text.',
              ),
            ],
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _ready && !_busy && _image != null
                ? _sendQuestion
                : null,
            icon: const Icon(Icons.send),
            label: Text(_analyzing ? 'Generating...' : 'Ask Vision AI'),
          ),
          if (_error != null && _ready) ...[
            const SizedBox(height: 12),
            SelectableText(_error!, style: const TextStyle(color: Colors.red)),
          ],
          const SizedBox(height: 20),
          const Center(
            child: Text(
              'Powered by SmolVLM2 • Inference stays on-device',
              style: TextStyle(fontSize: 11, color: Colors.black54),
            ),
          ),
        ],
      ),
    ),
  );
}
