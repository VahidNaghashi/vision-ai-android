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

class VisionApp extends StatefulWidget {
  const VisionApp({super.key});

  @override
  State<VisionApp> createState() => _VisionAppState();
}

class _VisionAppState extends State<VisionApp> {
  ThemeMode _theme = ThemeMode.system;

  @override
  Widget build(BuildContext context) {
    ThemeData buildTheme(Brightness brightness) {
      final dark = brightness == Brightness.dark;
      final scheme = ColorScheme.fromSeed(
        seedColor: const Color(0xFF5568DC),
        brightness: brightness,
      );
      return ThemeData(
        useMaterial3: true,
        colorScheme: scheme,
        scaffoldBackgroundColor: dark
            ? const Color(0xFF0D1120)
            : const Color(0xFFF5F7FC),
        cardTheme: CardThemeData(
          elevation: 0,
          color: dark ? const Color(0xFF1A2034) : Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: dark ? const Color(0xFF202740) : Colors.white,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(18),
            borderSide: BorderSide.none,
          ),
        ),
      );
    }

    return MaterialApp(
      title: 'Vision AI',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: _theme,
      home: VisionHomePage(
        darkMode: _theme == ThemeMode.dark,
        toggleTheme: () => setState(() {
          _theme = _theme == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
        }),
      ),
    );
  }
}

class VisionHomePage extends StatefulWidget {
  const VisionHomePage({
    super.key,
    required this.darkMode,
    required this.toggleTheme,
  });

  final bool darkMode;
  final VoidCallback toggleTheme;

  @override
  State<VisionHomePage> createState() => _VisionHomePageState();
}

class _VisionHomePageState extends State<VisionHomePage> {
  final _vlm = VlmService();
  final _picker = ImagePicker();
  final _question = TextEditingController();
  final _scroll = ScrollController();
  final List<Map<String, String>> _messages = [];

  ModelSpec _selected = ModelStorage.smol;
  CancelToken? _activeDownload;
  XFile? _image;
  String _partial = '';
  String _status = 'Checking saved models...';
  String? _error;
  bool _ready = false;
  bool _busy = true;
  bool _downloading = false;
  bool _analyzing = false;
  double? _progress;
  double? _lastSeconds;
  final Map<VisionModel, bool> _installed = {};

  @override
  void initState() {
    super.initState();
    _restoreSelection();
  }

  Future<void> _refreshInstalled() async {
    for (final model in ModelStorage.models) {
      final installed = await ModelStorage.isInstalled(model);
      _installed[model.id] = installed;
    }
    if (mounted) setState(() {});
  }

  Future<void> _restoreSelection() async {
    try {
      final id = await ModelStorage.selectedModel();
      if (!mounted) return;
      _selected = id == VisionModel.gemmaE2B
          ? ModelStorage.gemma
          : ModelStorage.smol;
      await _refreshInstalled();
      if (!mounted) return;
      // First launch auto-downloads only the smaller default model.
      // Gemma requires a confirmation before its large download.
      await _loadSelected(autoDownload: _selected.id == VisionModel.smol);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.toString();
        _status = 'Setup failed';
      });
    }
  }

  Future<void> _loadSelected({required bool autoDownload}) async {
    if (!mounted) return;
    setState(() {
      _busy = true;
      _ready = false;
      _downloading = false;
      _progress = null;
      _error = null;
      _status = 'Checking ${_selected.title}...';
    });
    try {
      String? path = await ModelStorage.installedPath(_selected);
      if (path == null && !autoDownload) {
        if (!mounted) return;
        setState(() {
          _status = '${_selected.title} is not downloaded';
        });
        return;
      }
      if (path == null) {
        final cancel = CancelToken();
        _activeDownload = cancel;
        if (!mounted) return;
        setState(() {
          _downloading = true;
          _status = 'Downloading ${_selected.title}...';
        });
        path = await ModelStorage.download(
          _selected,
          cancelToken: cancel,
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
        _status = 'Loading ${_selected.title} into memory...';
      });
      await _vlm.loadModel(path);
      if (!mounted) return;
      _installed[_selected.id] = true;
      setState(() {
        _ready = true;
        _status = '${_selected.title} is ready';
      });
    } catch (e, trace) {
      debugPrint('Model load failed: $e');
      debugPrintStack(stackTrace: trace);
      if (!mounted) return;
      setState(() {
        _status = 'Unable to load ${_selected.title}';
        _error = e.toString();
      });
    } finally {
      _activeDownload = null;
      if (mounted) {
        setState(() {
          _busy = false;
          _downloading = false;
        });
      }
    }
  }

  Future<void> _switchModel(ModelSpec next) async {
    if (_busy || next.id == _selected.id) return;
    final installed = await ModelStorage.isInstalled(next);
    if (!mounted) return;
    bool downloadNow = false;
    if (!installed) {
      final allowed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Download ${next.title}?'),
          content: Text(
            'This model uses ${next.sizeLabel} of download data and '
            'additional temporary storage during installation. '
            'Use Wi-Fi and ensure sufficient free space. '
            'Inference remains on-device after installation.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Download'),
            ),
          ],
        ),
      );
      if (allowed != true || !mounted) return;
      downloadNow = true;
    }
    setState(() {
      _selected = next;
      _messages.clear();
      _partial = '';
      _lastSeconds = null;
      _question.clear();
    });
    await ModelStorage.saveSelectedModel(next.id);
    if (!mounted) return;
    await _loadSelected(autoDownload: downloadNow);
  }

  Future<void> _pickImage(ImageSource source) async {
    if (_busy) return;
    try {
      final image = await _picker.pickImage(
        source: source,
        maxWidth: 1024,
        imageQuality: 85,
      );
      if (image == null || !mounted) return;
      setState(() {
        _image = image;
        _messages.clear();
        _partial = '';
        _lastSeconds = null;
        _error = null;
        _question.text = 'Describe this image in one sentence.';
      });
    } catch (e) {
      if (mounted) setState(() => _error = 'Cannot open photo: $e');
    }
  }

  void _scrollDown() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _sendQuestion() async {
    if (!_ready || _busy || _image == null) return;
    final question = _question.text.trim();
    if (question.isEmpty) return;
    final history = _messages.map((e) => Map<String, String>.from(e)).toList();
    setState(() {
      _busy = true;
      _analyzing = true;
      _partial = '';
      _error = null;
      _lastSeconds = null;
      _messages.add({'role': 'user', 'text': question});
      _question.clear();
    });
    _scrollDown();
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    final watch = Stopwatch()..start();
    try {
      final answer = await _vlm.analyzeImage(
        imagePath: _image!.path,
        question: question,
        history: history,
        onToken: (fragment) {
          if (!mounted) return;
          setState(() => _partial += fragment);
          _scrollDown();
        },
      );
      watch.stop();
      if (!mounted) return;
      setState(() {
        _messages.add({'role': 'assistant', 'text': answer});
        _partial = '';
        _lastSeconds = watch.elapsedMilliseconds / 1000;
      });
      _scrollDown();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Generation failed: $e';
        _partial = '';
        if (_messages.isNotEmpty && _messages.last['role'] == 'user') {
          _messages.removeLast();
        }
        _question.text = question;
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

  Widget _modelCard(ColorScheme colors) => Card(
    margin: EdgeInsets.zero,
    child: Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                _ready ? Icons.verified_rounded : Icons.memory_rounded,
                color: _ready ? Colors.green : colors.primary,
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  _status,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
              if (_ready) const Icon(Icons.wifi_off_rounded, size: 18),
            ],
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<VisionModel>(
            key: ValueKey(_selected.id),
            initialValue: _selected.id,
            decoration: const InputDecoration(
              labelText: 'On-device vision model',
              isDense: true,
              prefixIcon: Icon(Icons.tune_rounded),
            ),
            items: ModelStorage.models.map((model) {
              final downloaded = _installed[model.id] == true;
              return DropdownMenuItem(
                value: model.id,
                child: Text(
                  '${model.title} (${model.sizeLabel})${downloaded ? ' ✓' : ''}',
                  overflow: TextOverflow.ellipsis,
                ),
              );
            }).toList(),
            onChanged: _busy
                ? null
                : (value) {
                    if (value == null) return;
                    final spec = ModelStorage.models.firstWhere(
                      (model) => model.id == value,
                    );
                    _switchModel(spec);
                  },
          ),
          if (_downloading) ...[
            const SizedBox(height: 12),
            LinearProgressIndicator(value: _progress),
            const SizedBox(height: 5),
            Text(
              _progress == null
                  ? 'Downloading and preparing model...'
                  : '${(_progress! * 100).toStringAsFixed(1)}% downloaded',
              style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
            ),
          ] else if (_busy && !_ready) ...[
            const SizedBox(height: 12),
            const LinearProgressIndicator(),
          ],
          if (_error != null && !_busy && !_ready) ...[
            const SizedBox(height: 8),
            Text(_error!, style: TextStyle(color: colors.error)),
            TextButton.icon(
              onPressed: () => _loadSelected(autoDownload: true),
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
            ),
          ],
        ],
      ),
    ),
  );

  Widget _photoCard(ColorScheme colors) => Card(
    margin: EdgeInsets.zero,
    clipBehavior: Clip.antiAlias,
    child: Column(
      children: [
        SizedBox(
          height: 185,
          width: double.infinity,
          child: _image == null
              ? Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.image_search_rounded,
                      size: 48,
                      color: colors.primary,
                    ),
                    const SizedBox(height: 10),
                    const Text('Add a photo to begin'),
                  ],
                )
              : Image.file(File(_image!.path), fit: BoxFit.contain),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _busy
                      ? null
                      : () => _pickImage(ImageSource.camera),
                  icon: const Icon(Icons.camera_alt_outlined),
                  label: const Text('Camera'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _busy
                      ? null
                      : () => _pickImage(ImageSource.gallery),
                  icon: const Icon(Icons.photo_library_outlined),
                  label: const Text('Photos'),
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );

  Widget _chat(ColorScheme colors) {
    final entries = <Map<String, String>>[
      ..._messages,
      if (_analyzing) {'role': 'assistant', 'text': _partial},
    ];
    if (entries.isEmpty) {
      return Center(
        child: Text(
          'Ask questions about the selected image.',
          textAlign: TextAlign.center,
          style: TextStyle(color: colors.onSurfaceVariant),
        ),
      );
    }
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: entries.length,
      itemBuilder: (context, index) {
        final item = entries[index];
        final isUser = item['role'] == 'user';
        final isStreaming = _analyzing && index == entries.length - 1;
        final text = item['text'] ?? '';
        return Align(
          alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.sizeOf(context).width * 0.83,
            ),
            margin: const EdgeInsets.symmetric(vertical: 5),
            padding: const EdgeInsets.all(13),
            decoration: BoxDecoration(
              color: isUser ? colors.primaryContainer : colors.surface,
              borderRadius: BorderRadius.circular(18),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isUser ? 'You' : _selected.title,
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                    color: colors.primary,
                  ),
                ),
                const SizedBox(height: 6),
                Text(isStreaming && text.isEmpty ? 'Thinking...' : text),
                if (isStreaming) ...[
                  const SizedBox(height: 8),
                  const SizedBox(
                    width: 13,
                    height: 13,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ],
                if (!isUser && !isStreaming && text.isNotEmpty)
                  Align(
                    alignment: Alignment.centerRight,
                    child: IconButton(
                      tooltip: 'Copy answer',
                      icon: const Icon(Icons.copy_rounded, size: 17),
                      onPressed: () async {
                        await Clipboard.setData(ClipboardData(text: text));
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
    );
  }

  Widget _composer(ColorScheme colors) => Container(
    padding: const EdgeInsets.fromLTRB(15, 10, 15, 10),
    decoration: BoxDecoration(
      color: Theme.of(context).scaffoldBackgroundColor,
      border: Border(top: BorderSide(color: colors.outlineVariant)),
    ),
    child: SafeArea(
      top: false,
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _question,
              minLines: 1,
              maxLines: 3,
              decoration: const InputDecoration(
                hintText: 'Ask Vision AI about this photo...',
                isDense: true,
              ),
              onSubmitted: (_) => _sendQuestion(),
            ),
          ),
          const SizedBox(width: 9),
          IconButton.filled(
            tooltip: 'Send question',
            onPressed: _ready && !_busy && _image != null
                ? _sendQuestion
                : null,
            icon: const Icon(Icons.arrow_upward_rounded),
          ),
        ],
      ),
    ),
  );

  @override
  void dispose() {
    _activeDownload?.cancel('App closing');
    _question.dispose();
    _scroll.dispose();
    _vlm.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Vision AI', style: TextStyle(fontWeight: FontWeight.bold)),
            Text(
              'Private on-device visual assistant',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.normal),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'New conversation',
            onPressed: _busy
                ? null
                : () => setState(() {
                    _messages.clear();
                    _partial = '';
                    _question.clear();
                    _lastSeconds = null;
                  }),
            icon: const Icon(Icons.edit_square),
          ),
          IconButton(
            tooltip: 'Toggle dark mode',
            onPressed: widget.toggleTheme,
            icon: Icon(
              widget.darkMode
                  ? Icons.light_mode_outlined
                  : Icons.dark_mode_outlined,
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              children: [
                _modelCard(colors),
                const SizedBox(height: 12),
                _photoCard(colors),
                const SizedBox(height: 18),
                Row(
                  children: [
                    const Text(
                      'Conversation',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const Spacer(),
                    if (_lastSeconds != null)
                      Text(
                        '${_lastSeconds!.toStringAsFixed(1)} s',
                        style: TextStyle(color: colors.onSurfaceVariant),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                SizedBox(height: 290, child: _chat(colors)),
                const SizedBox(height: 9),
                Text(
                  'All image inference runs on your device.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 11,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          _composer(colors),
        ],
      ),
    );
  }
}
