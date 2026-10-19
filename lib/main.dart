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
  ThemeMode _mode = ThemeMode.system;

  @override
  Widget build(BuildContext context) {
    ThemeData makeTheme(Brightness brightness) {
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
        appBarTheme: AppBarTheme(
          backgroundColor: dark
              ? const Color(0xFF0D1120)
              : const Color(0xFFF5F7FC),
          surfaceTintColor: Colors.transparent,
        ),
        cardTheme: CardThemeData(
          elevation: 0,
          color: dark ? const Color(0xFF1A2034) : Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(20),
            borderSide: BorderSide.none,
          ),
          filled: true,
          fillColor: dark ? const Color(0xFF202740) : Colors.white,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 13,
          ),
        ),
      );
    }

    return MaterialApp(
      title: 'Vision AI',
      debugShowCheckedModeBanner: false,
      theme: makeTheme(Brightness.light),
      darkTheme: makeTheme(Brightness.dark),
      themeMode: _mode,
      home: VisionHomePage(
        themeMode: _mode,
        onToggleTheme: () {
          setState(() {
            _mode = _mode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
          });
        },
      ),
    );
  }
}

class VisionHomePage extends StatefulWidget {
  const VisionHomePage({
    super.key,
    required this.themeMode,
    required this.onToggleTheme,
  });

  final ThemeMode themeMode;
  final VoidCallback onToggleTheme;

  @override
  State<VisionHomePage> createState() => _VisionHomePageState();
}

class _VisionHomePageState extends State<VisionHomePage> {
  final VlmService _vlm = VlmService();
  final ImagePicker _picker = ImagePicker();
  final CancelToken _downloadCancel = CancelToken();
  final TextEditingController _question = TextEditingController();
  final ScrollController _chatScroll = ScrollController();
  final List<Map<String, String>> _messages = [];

  XFile? _image;
  String _partialAnswer = '';
  String _status = 'Preparing private AI...';
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
      _status = 'Checking saved model...';
    });
    try {
      var path = await ModelStorage.getInstalledModelPath();
      if (path == null) {
        if (!mounted) return;
        setState(() {
          _downloading = true;
          _status = 'Downloading SmolVLM2 • First launch';
        });
        path = await ModelStorage.downloadModel(
          cancelToken: _downloadCancel,
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
        _status = 'Initializing on-device model...';
      });
      await _vlm.loadModel(path);
      if (!mounted) return;
      setState(() {
        _ready = true;
        _status = 'Private AI is ready';
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
        duration: const Duration(milliseconds: 180),
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
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    final watch = Stopwatch()..start();
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
      watch.stop();
      if (!mounted) return;
      setState(() {
        _messages.add({'role': 'assistant', 'text': answer});
        _partialAnswer = '';
        _lastInferenceSeconds = watch.elapsedMilliseconds / 1000;
      });
      _scrollToBottom();
    } catch (e, stack) {
      debugPrint('Inference error: $e');
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

  void _newChat() {
    if (_busy) return;
    setState(() {
      _messages.clear();
      _partialAnswer = '';
      _lastInferenceSeconds = null;
      _error = null;
      _question.clear();
    });
  }

  Widget _statusCard(ColorScheme scheme) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(15),
        child: Column(
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(9),
                  decoration: BoxDecoration(
                    color: (_ready ? const Color(0xFF1E9C77) : scheme.primary)
                        .withValues(alpha: 0.11),
                    borderRadius: BorderRadius.circular(13),
                  ),
                  child: Icon(
                    _ready ? Icons.verified_outlined : Icons.memory_outlined,
                    color: _ready ? const Color(0xFF1E9C77) : scheme.primary,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _status,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        _ready
                            ? 'SmolVLM2-500M • On-device inference'
                            : 'SmolVLM2-500M • Getting ready',
                        style: TextStyle(
                          color: scheme.onSurfaceVariant,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                if (_ready)
                  const Icon(Icons.wifi_off_rounded, color: Color(0xFF1E9C77)),
              ],
            ),
            if (_downloading) ...[
              const SizedBox(height: 15),
              LinearProgressIndicator(value: _progress, minHeight: 6),
              const SizedBox(height: 7),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  _progress == null
                      ? 'Downloading model...'
                      : '${(_progress! * 100).toStringAsFixed(1)}% downloaded',
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ] else if (_busy && !_ready) ...[
              const SizedBox(height: 12),
              const LinearProgressIndicator(),
            ],
            if (_error != null && !_busy && !_ready) ...[
              const SizedBox(height: 10),
              SelectableText(_error!, style: TextStyle(color: scheme.error)),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _setupModel,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Try again'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _photoCard(ColorScheme scheme) {
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          SizedBox(
            width: double.infinity,
            height: 185,
            child: _image == null
                ? Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.image_search_rounded,
                        size: 45,
                        color: scheme.primary.withValues(alpha: 0.75),
                      ),
                      const SizedBox(height: 9),
                      const Text(
                        'See more in every photo',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Take a photo or choose from your library',
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
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
                        : () => _chooseImage(ImageSource.camera),
                    icon: const Icon(Icons.photo_camera_outlined, size: 19),
                    label: const Text('Camera'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _busy
                        ? null
                        : () => _chooseImage(ImageSource.gallery),
                    icon: const Icon(Icons.photo_library_outlined, size: 19),
                    label: const Text('Photos'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _bubble(
    Map<String, String> entry,
    bool generating,
    ColorScheme scheme,
  ) {
    final user = entry['role'] == 'user';
    final text = entry['text'] ?? '';
    return Align(
      alignment: user ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.84,
        ),
        padding: const EdgeInsets.fromLTRB(14, 11, 14, 9),
        margin: const EdgeInsets.symmetric(vertical: 5),
        decoration: BoxDecoration(
          color: user ? scheme.primaryContainer : scheme.surface,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(19),
            topRight: const Radius.circular(19),
            bottomLeft: Radius.circular(user ? 19 : 5),
            bottomRight: Radius.circular(user ? 5 : 19),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!user) ...[
                  Icon(
                    Icons.auto_awesome_rounded,
                    size: 14,
                    color: scheme.primary,
                  ),
                  const SizedBox(width: 5),
                ],
                Text(
                  user ? 'You' : 'Vision AI',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: user ? scheme.onPrimaryContainer : scheme.primary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              generating && text.isEmpty
                  ? 'Thinking about your photo...'
                  : text,
              style: const TextStyle(fontSize: 15, height: 1.45),
            ),
            if (generating) ...[
              const SizedBox(height: 9),
              const SizedBox(
                width: 13,
                height: 13,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ] else if (!user && text.isNotEmpty) ...[
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerRight,
                child: IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Copy answer',
                  icon: const Icon(Icons.copy_rounded, size: 17),
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: text));
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Answer copied')),
                    );
                  },
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _conversation(ColorScheme scheme) {
    final entries = <Map<String, String>>[
      ..._messages,
      if (_analyzing) {'role': 'assistant', 'text': _partialAnswer},
    ];
    if (entries.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.forum_outlined,
              size: 35,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
            ),
            const SizedBox(height: 10),
            const Text(
              'Your conversation starts here',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 5),
            Text(
              'Choose a photo, then ask anything about it.',
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
            ),
          ],
        ),
      );
    }
    return ListView.builder(
      controller: _chatScroll,
      padding: const EdgeInsets.symmetric(vertical: 10),
      itemCount: entries.length,
      itemBuilder: (context, index) => _bubble(
        entries[index],
        _analyzing && index == entries.length - 1,
        scheme,
      ),
    );
  }

  Widget _composer(ColorScheme scheme) {
    final enabled = _ready && !_busy && _image != null;
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        border: Border(
          top: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
        ),
      ),
      padding: EdgeInsets.fromLTRB(
        16,
        9,
        16,
        MediaQuery.paddingOf(context).bottom > 0 ? 7 : 13,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_image != null)
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _suggestion(
                    'Describe',
                    'Describe this image in one sentence.',
                  ),
                  const SizedBox(width: 7),
                  _suggestion('Objects', 'What objects are visible?'),
                  const SizedBox(width: 7),
                  _suggestion('Read text', 'Read the visible text.'),
                ],
              ),
            ),
          if (_image != null) const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: TextField(
                  controller: _question,
                  enabled: !_busy,
                  minLines: 1,
                  maxLines: 3,
                  textCapitalization: TextCapitalization.sentences,
                  textInputAction: TextInputAction.send,
                  decoration: InputDecoration(
                    hintText: _image == null
                        ? 'Add a photo to start...'
                        : 'Ask about this photo...',
                    prefixIcon: const Icon(
                      Icons.chat_bubble_outline_rounded,
                      size: 20,
                    ),
                  ),
                  onSubmitted: (_) => _sendQuestion(),
                ),
              ),
              const SizedBox(width: 9),
              IconButton.filled(
                tooltip: 'Send question',
                onPressed: enabled ? _sendQuestion : null,
                icon: Icon(
                  _analyzing
                      ? Icons.hourglass_top_rounded
                      : Icons.arrow_upward_rounded,
                ),
                style: IconButton.styleFrom(minimumSize: const Size(49, 49)),
              ),
            ],
          ),
          if (_error != null && _ready)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                _error!,
                style: TextStyle(fontSize: 12, color: scheme.error),
              ),
            ),
        ],
      ),
    );
  }

  Widget _suggestion(String label, String prompt) => ActionChip(
    label: Text(label),
    visualDensity: VisualDensity.compact,
    onPressed: _busy
        ? null
        : () {
            _question.text = prompt;
            _question.selection = TextSelection.collapsed(
              offset: prompt.length,
            );
          },
  );

  @override
  void dispose() {
    _downloadCancel.cancel('App closed');
    _question.dispose();
    _chatScroll.dispose();
    _vlm.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 18,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Vision AI',
              style: TextStyle(
                fontWeight: FontWeight.w800,
                letterSpacing: -0.6,
              ),
            ),
            Text(
              'Your private visual assistant',
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'New conversation',
            onPressed: _busy ? null : _newChat,
            icon: const Icon(Icons.edit_square),
          ),
          IconButton(
            tooltip: 'Toggle light / dark mode',
            onPressed: widget.onToggleTheme,
            icon: Icon(
              widget.themeMode == ThemeMode.dark
                  ? Icons.light_mode_outlined
                  : Icons.dark_mode_outlined,
            ),
          ),
          const SizedBox(width: 7),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
              children: [
                _statusCard(scheme),
                const SizedBox(height: 12),
                _photoCard(scheme),
                const SizedBox(height: 17),
                Row(
                  children: [
                    const Text(
                      'Conversation',
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 18,
                      ),
                    ),
                    const Spacer(),
                    if (_lastInferenceSeconds != null)
                      Text(
                        '${_lastInferenceSeconds!.toStringAsFixed(1)} s',
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                SizedBox(height: 280, child: _conversation(scheme)),
                const SizedBox(height: 9),
                Center(
                  child: Text(
                    'Powered by SmolVLM2 • Images stay on this device',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
          _composer(scheme),
        ],
      ),
    );
  }
}
