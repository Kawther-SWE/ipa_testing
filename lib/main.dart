import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:audio_io/audio_io.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import 'package:google_speech/endless_streaming_service_beta.dart' as stt_streaming;
import 'package:google_speech/google_speech.dart' as stt;
import 'package:google_speech/generated/google/cloud/speech/v1p1beta1/cloud_speech.pb.dart'
    as stt_pb;
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

const double kOverlayWidth = 320;
const double kOverlayHeight = 220;
const double kBubbleSize = 56;
const String kServiceAccountAsset = 'assets/my-project-for-deaf-5ca65dcc5876.json';
const List<String> kAltLanguages = ['ar-SA'];

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

@pragma('vm:entry-point')
void overlayMain() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const OverlayApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  final SettingsStore _settings = SettingsStore();
  late final TranscriptionController _transcription;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _transcription = TranscriptionController(settings: _settings);
    _settings.load().then((_) {
      if (!mounted) return;
      setState(() {
        _ready = true;
      });
    });
  }

  @override
  void dispose() {
    _transcription.dispose();
    _settings.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return const MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          body: Center(child: CircularProgressIndicator()),
        ),
      );
    }

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Live Transcription',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
      ),
      home: HomePage(
        settings: _settings,
        transcription: _transcription,
      ),
    );
  }
}

class SettingsStore extends ChangeNotifier {
  static const String _fontSizeKey = 'font_size';
  static const String _textColorKey = 'text_color';
  static const double _defaultFontSize = 16;

  SharedPreferences? _prefs;
  double _fontSize = _defaultFontSize;
  Color _textColor = Colors.white;

  Future<void> load() async {
    _prefs = await SharedPreferences.getInstance();
    _fontSize = _prefs?.getDouble(_fontSizeKey) ?? _defaultFontSize;
    _textColor = Color(_prefs?.getInt(_textColorKey) ?? Colors.white.toARGB32());
  }

  double get fontSize => _fontSize;
  Color get textColor => _textColor;

  Future<void> setFontSize(double value) async {
    _fontSize = value;
    notifyListeners();
    await _prefs?.setDouble(_fontSizeKey, value);
  }

  Future<void> setTextColor(Color value) async {
    _textColor = value;
    notifyListeners();
    await _prefs?.setInt(_textColorKey, value.toARGB32());
  }

  static Future<SettingsSnapshot> loadSnapshot() async {
    final prefs = await SharedPreferences.getInstance();
    final fontSize = prefs.getDouble(_fontSizeKey) ?? _defaultFontSize;
    final colorValue = prefs.getInt(_textColorKey) ?? Colors.white.toARGB32();
    return SettingsSnapshot(
      fontSize: fontSize,
      textColor: Color(colorValue),
    );
  }
}

class SettingsSnapshot {
  const SettingsSnapshot({required this.fontSize, required this.textColor});
  final double fontSize;
  final Color textColor;
}

class TranscriptionController extends ChangeNotifier {
  TranscriptionController({required this.settings});

  final SettingsStore settings;
  final AudioIo _audioIo = AudioIo.instance;

  stt_streaming.EndlessStreamingServiceBeta? _speech;
  StreamController<List<int>>? _audioController;
  StreamSubscription<List<double>>? _audioSub;
  StreamSubscription<stt_pb.StreamingRecognizeResponse>? _sttSub;

  bool _running = false;
  bool _disposed = false;
  String _finalText = '';
  String _partialText = '';
  String _status = 'Idle';

  bool get isRunning => _running;
  String get status => _status;
  String get fullText {
    if (_partialText.isEmpty) return _finalText;
    if (_finalText.isEmpty) return _partialText;
    return '$_finalText $_partialText';
  }

  Future<void> start() async {
    if (_running) return;

    final micGranted = await _ensureMicrophonePermission();
    if (!micGranted) {
      _status = 'Microphone permission denied';
      _broadcast();
      return;
    }

    _running = true;
    _status = 'Listening...';
    _broadcast();

    final serviceAccountJson = await rootBundle.loadString(kServiceAccountAsset);
    final serviceAccount = stt.ServiceAccount.fromString(serviceAccountJson);
    _speech =
      stt_streaming.EndlessStreamingServiceBeta.viaServiceAccount(serviceAccount);

    final config = stt.RecognitionConfigBeta(
      encoding: stt.AudioEncoding.LINEAR16,
      sampleRateHertz: 48000,
      languageCode: 'en-US',
      alternativeLanguageCodes: kAltLanguages,
      model: stt.RecognitionModel.latest_long,
      enableAutomaticPunctuation: true,
    );

    final streamingConfig = stt.StreamingRecognitionConfigBeta(  
      config: config,
      interimResults: true,
      singleUtterance: false,
    );

    _audioController = StreamController<List<int>>();
    _speech!.endlessStreamingRecognize(streamingConfig, _audioController!.stream);

    _sttSub = _speech!.endlessStream.listen(
      _onSttData,
      onError: _onSttError,
      onDone: _onSttDone,
    );

    await _audioIo.requestLatency(AudioIoLatency.Balanced);
    await _audioIo.start();

    _audioSub = _audioIo.input.listen(
      _onAudioData,
      onError: _onAudioError,
      cancelOnError: true,
    );
  }

  Future<void> stop() async {
    if (!_running) return;

    _running = false;
    _status = 'Stopped';

    await _audioSub?.cancel();
    _audioSub = null;

    try {
      await _audioIo.stop();
    } catch (_) {}

    await _audioController?.close();
    _audioController = null;

    await _sttSub?.cancel();
    _sttSub = null;

    _speech?.dispose();
    _speech = null;

    _broadcast();
  }

  void clear() {
    _finalText = '';
    _partialText = '';
    _broadcast();
  }

  @override
  void dispose() {
    _disposed = true;
    stop();
    super.dispose();
  }

  void _onAudioData(List<double> samples) {
    if (!_running || _audioController == null) return;
    _audioController!.add(_floatToPcm16(samples));
  }

  void _onAudioError(Object error) {
    if (!_running) return;
    _status = 'Audio error: $error';
    _broadcast();
  }

  void _onSttData(stt_pb.StreamingRecognizeResponse data) {
    if (!_running) return;
    for (final result in data.results) {
      if (result.alternatives.isEmpty) continue;
      final transcript = result.alternatives.first.transcript.trim();
      if (transcript.isEmpty) continue;
      if (result.isFinal) {
        if (_finalText.isEmpty) {
          _finalText = transcript;
        } else {
          _finalText = '$_finalText $transcript';
        }
        _partialText = '';
      } else {
        _partialText = transcript;
      }
    }
    _broadcast();
  }

  void _onSttError(Object error) {
    if (!_running) return;
    _status = 'Speech error: $error';
    _running = false;
    _broadcast();
  }

  void _onSttDone() {
    if (!_running) return;
    _status = 'Stream ended';
    _running = false;
    _broadcast();
  }

  void _broadcast() {
    if (_disposed) return;
    notifyListeners();
    OverlayBridge.sendUpdate(fullText, settings);
  }

  Future<bool> _ensureMicrophonePermission() async {
    final status = await Permission.microphone.request();
    return status.isGranted;
  }

  Uint8List _floatToPcm16(List<double> samples) {
    final data = ByteData(samples.length * 2);
    for (var i = 0; i < samples.length; i++) {
      var s = samples[i];
      if (s > 1.0) s = 1.0;
      if (s < -1.0) s = -1.0;
      final v = (s * 32767).round();
      data.setInt16(i * 2, v, Endian.little);
    }
    return data.buffer.asUint8List();
  }
}

class OverlayBridge {
  static DateTime _lastPush = DateTime.fromMillisecondsSinceEpoch(0);

  static Future<void> showOverlay(SettingsStore settings) async {
    if (!Platform.isAndroid) return;

    final granted = await FlutterOverlayWindow.isPermissionGranted();
    final ok = granted || (await FlutterOverlayWindow.requestPermission() ?? false);
    if (!ok) return;

    await FlutterOverlayWindow.showOverlay(
      height: kOverlayHeight.toInt(),
      width: kOverlayWidth.toInt(),
      enableDrag: true,
      overlayTitle: 'Live transcription',
      overlayContent: 'Running',
      flag: OverlayFlag.defaultFlag,
      positionGravity: PositionGravity.none,
    );
    await sendUpdate('', settings);
  }

  static Future<void> sendUpdate(String text, SettingsStore settings) async {
    if (!Platform.isAndroid) return;

    final now = DateTime.now();
    if (now.difference(_lastPush).inMilliseconds < 200) return;
    _lastPush = now;

    final payload = jsonEncode({
      'text': text,
      'fontSize': settings.fontSize,
      'textColor': settings.textColor.toARGB32(),
    });

    try {
      await FlutterOverlayWindow.shareData(payload);
    } catch (_) {}
  }
}

class OverlayApp extends StatelessWidget {
  const OverlayApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: OverlayHome(),
    );
  }
}

class OverlayHome extends StatefulWidget {
  const OverlayHome({super.key});

  @override
  State<OverlayHome> createState() => _OverlayHomeState();
}

class _OverlayHomeState extends State<OverlayHome> {
  String _text = '';
  double _fontSize = 16;
  Color _textColor = Colors.white;
  bool _collapsed = false;
  StreamSubscription<dynamic>? _overlaySub;

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _overlaySub = FlutterOverlayWindow.overlayListener.listen(_onOverlayEvent);
  }

  Future<void> _loadSettings() async {
    final snapshot = await SettingsStore.loadSnapshot();
    if (!mounted) return;
    setState(() {
      _fontSize = snapshot.fontSize;
      _textColor = snapshot.textColor;
    });
  }

  @override
  void dispose() {
    _overlaySub?.cancel();
    super.dispose();
  }

  void _onOverlayEvent(dynamic event) {
    final payload = OverlayPayload.from(event);
    if (payload.isEmpty) return;
    setState(() {
      if (payload.text != null) _text = payload.text!;
      if (payload.fontSize != null) _fontSize = payload.fontSize!;
      if (payload.textColor != null) _textColor = Color(payload.textColor!);
    });
  }

  Future<void> _toggleCollapsed() async {
    final next = !_collapsed;
    setState(() {
      _collapsed = next;
    });
    if (Platform.isAndroid) {
      await FlutterOverlayWindow.resizeOverlay(
        next ? kBubbleSize.toInt() : kOverlayWidth.toInt(),
        next ? kBubbleSize.toInt() : kOverlayHeight.toInt(),
        true,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final window = TranscriptWindow(
      text: _text,
      fontSize: _fontSize,
      textColor: _textColor,
      collapsed: _collapsed,
      onCopy: _copy,
    );

    return Material(
      color: Colors.transparent,
      child: GestureDetector(
        onDoubleTap: _toggleCollapsed,
        onTap: () {
          if (_collapsed) {
            _toggleCollapsed();
          }
        },
        child: window,
      ),
    );
  }

  Future<void> _copy() async {
    if (_text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: _text));
  }
}

class OverlayPayload {
  OverlayPayload({this.text, this.fontSize, this.textColor});

  final String? text;
  final double? fontSize;
  final int? textColor;

  bool get isEmpty => text == null && fontSize == null && textColor == null;

  factory OverlayPayload.from(dynamic event) {
    try {
      if (event is String) {
        final data = jsonDecode(event);
        if (data is Map<String, dynamic>) {
          return OverlayPayload(
            text: data['text'] as String?,
            fontSize: (data['fontSize'] as num?)?.toDouble(),
            textColor: data['textColor'] as int?,
          );
        }
      }
      if (event is Map) {
        return OverlayPayload(
          text: event['text'] as String?,
          fontSize: (event['fontSize'] as num?)?.toDouble(),
          textColor: event['textColor'] as int?,
        );
      }
    } catch (_) {}
    return OverlayPayload();
  }
}

class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    required this.settings,
    required this.transcription,
  });

  final SettingsStore settings;
  final TranscriptionController transcription;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  Offset _position = const Offset(20, 140);
  bool _collapsed = false;

  @override
  void initState() {
    super.initState();
    widget.settings.addListener(_onSettingsChanged);
  }

  @override
  void dispose() {
    widget.settings.removeListener(_onSettingsChanged);
    super.dispose();
  }

  void _onSettingsChanged() {
    OverlayBridge.sendUpdate(widget.transcription.fullText, widget.settings);
  }

  @override
  Widget build(BuildContext context) {
    final listenable = Listenable.merge([widget.settings, widget.transcription]);
    return AnimatedBuilder(
      animation: listenable,
      builder: (context, _) {
        final text = widget.transcription.fullText;
        return Scaffold(
          appBar: AppBar(
            title: const Text('Live Transcription'),
          ),
          body: Stack(
            children: [
              ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Text('Status: ${widget.transcription.status}'),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 12,
                    children: [
                      ElevatedButton(
                        onPressed: widget.transcription.isRunning
                            ? null
                            : () async {
                                await widget.transcription.start();
                                if (Platform.isAndroid) {
                                  await OverlayBridge.showOverlay(widget.settings);
                                }
                              },
                        child: const Text('Start'),
                      ),
                      OutlinedButton(
                        onPressed: widget.transcription.isRunning
                            ? () => widget.transcription.stop()
                            : null,
                        child: const Text('Stop'),
                      ),
                      TextButton(
                        onPressed: text.isEmpty ? null : widget.transcription.clear,
                        child: const Text('Clear'),
                      ),
                    ],
                  ),
                  if (Platform.isAndroid) ...[
                    const SizedBox(height: 12),
                    ElevatedButton(
                      onPressed: () => OverlayBridge.showOverlay(widget.settings),
                      child: const Text('Show Floating Window'),
                    ),
                  ],
                  const SizedBox(height: 24),
                  Text('Font Size: ${widget.settings.fontSize.toStringAsFixed(0)}'),
                  Slider(
                    min: 12,
                    max: 26,
                    value: widget.settings.fontSize,
                    onChanged: (value) => widget.settings.setFontSize(value),
                  ),
                  const SizedBox(height: 8),
                  const Text('Text Color'),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 12,
                    children: _colorOptions.map((color) {
                      final isSelected =
                          widget.settings.textColor.toARGB32() == color.toARGB32();
                      return GestureDetector(
                        onTap: () => widget.settings.setTextColor(color),
                        child: Container(
                          width: 28,
                          height: 28,
                          decoration: BoxDecoration(
                            color: color,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: isSelected ? Colors.black : Colors.white,
                              width: 2,
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 24),
                  const Text('Preview'),
                  const SizedBox(height: 8),
                  const Text(
                    'Drag the window, double-tap to collapse, tap to expand, and use the copy icon.',
                  ),
                ],
              ),
              Positioned(
                left: _position.dx,
                top: _position.dy,
                child: _buildDraggableWindow(text),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildDraggableWindow(String text) {
    final size = MediaQuery.of(context).size;
    final width = _collapsed ? kBubbleSize : kOverlayWidth;
    final height = _collapsed ? kBubbleSize : kOverlayHeight;

    return GestureDetector(
      onPanUpdate: (details) {
        setState(() {
          _position = _clampOffset(
            _position + details.delta,
            size,
            width,
            height,
          );
        });
      },
      onDoubleTap: () => setState(() => _collapsed = !_collapsed),
      onTap: () {
        if (_collapsed) {
          setState(() => _collapsed = false);
        }
      },
      child: TranscriptWindow(
        text: text,
        fontSize: widget.settings.fontSize,
        textColor: widget.settings.textColor,
        collapsed: _collapsed,
        onCopy: () => _copy(text),
      ),
    );
  }

  Future<void> _copy(String text) async {
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Copied to clipboard')),
    );
  }

  Offset _clampOffset(Offset proposed, Size size, double width, double height) {
    final maxX = (size.width - width).clamp(0.0, size.width);
    final maxY = (size.height - height - 80).clamp(0.0, size.height);
    final dx = proposed.dx.clamp(0.0, maxX);
    final dy = proposed.dy.clamp(0.0, maxY);
    return Offset(dx, dy);
  }

  List<Color> get _colorOptions => const [
        Colors.white,
        Colors.yellowAccent,
        Colors.greenAccent,
        Colors.cyanAccent,
        Colors.orangeAccent,
      ];
}

class TranscriptWindow extends StatefulWidget {
  const TranscriptWindow({
    super.key,
    required this.text,
    required this.fontSize,
    required this.textColor,
    required this.collapsed,
    required this.onCopy,
  });

  final String text;
  final double fontSize;
  final Color textColor;
  final bool collapsed;
  final VoidCallback onCopy;

  @override
  State<TranscriptWindow> createState() => _TranscriptWindowState();
}

class _TranscriptWindowState extends State<TranscriptWindow> {
  final ScrollController _scrollController = ScrollController();

  @override
  void didUpdateWidget(covariant TranscriptWindow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.text != oldWidget.text) {
      _maybeAutoScroll();
    }
  }

  void _maybeAutoScroll() {
    if (!_scrollController.hasClients) return;
    final max = _scrollController.position.maxScrollExtent;
    final current = _scrollController.offset;
    if (max - current < 40) {
      _scrollController.jumpTo(max);
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = widget.collapsed
        ? const Size(kBubbleSize, kBubbleSize)
        : const Size(kOverlayWidth, kOverlayHeight);

    if (widget.collapsed) {
      return SizedBox(
        width: size.width,
        height: size.height,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.teal.shade700.withValues(alpha: 0.9),
            shape: BoxShape.circle,
          ),
          child: const Center(
            child: Icon(Icons.hearing, color: Colors.white),
          ),
        ),
      );
    }

    final textDirection = _directionForText(widget.text);

    return SizedBox(
      width: size.width,
      height: size.height,
      child: Material(
        color: Colors.black.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(16),
        child: Column(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                child: Scrollbar(
                  thumbVisibility: true,
                  child: SingleChildScrollView(
                    controller: _scrollController,
                    child: Text(
                      widget.text.isEmpty ? '...' : widget.text,
                      textDirection: textDirection,
                      style: TextStyle(
                        color: widget.textColor,
                        fontSize: widget.fontSize,
                        height: 1.3,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Container(
              height: 44,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: const BoxDecoration(
                border: Border(top: BorderSide(color: Colors.white12)),
              ),
              child: Row(
                children: [
                  const SizedBox(width: 4),
                  const Text(
                    'Copy',
                    style: TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: widget.onCopy,
                    icon: const Icon(Icons.copy, color: Colors.white),
                    tooltip: 'Copy text',
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  TextDirection _directionForText(String text) {
    final hasArabic = RegExp(r'[\u0600-\u06FF]').hasMatch(text);
    return hasArabic ? TextDirection.rtl : TextDirection.ltr;
  }
}
