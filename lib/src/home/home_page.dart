import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';

import 'package:my_project/src/models/overlay_payload.dart';
import 'package:my_project/src/services/overlay_bridge.dart';
import 'package:my_project/src/services/settings_store.dart';
import 'package:my_project/src/services/transcription_controller.dart';

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
  StreamSubscription<dynamic>? _overlaySub;

  @override
  void initState() {
    super.initState();
    widget.settings.addListener(_onSettingsChanged);
    if (Platform.isAndroid) {
      _overlaySub = FlutterOverlayWindow.overlayListener.listen(_onOverlayEvent);
    }
  }

  @override
  void dispose() {
    _overlaySub?.cancel();
    widget.settings.removeListener(_onSettingsChanged);
    super.dispose();
  }

  void _onSettingsChanged() {
    OverlayBridge.sendUpdate(widget.transcription.fullText, widget.settings);
  }

  Future<void> _onOverlayEvent(dynamic event) async {
    final payload = OverlayPayload.from(event);
    if (payload.isClearRequest) {
      widget.transcription.clear();
      return;
    }

    final text = payload.text;
    if (payload.isCopyRequest && text != null && text.isNotEmpty) {
      await Clipboard.setData(ClipboardData(text: text));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Copied to clipboard')),
      );
    }
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
          body: ListView(
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
            ],
          ),
        );
      },
    );
  }

  List<Color> get _colorOptions => const [
        Colors.white,
        Colors.yellowAccent,
        Colors.greenAccent,
        Colors.cyanAccent,
        Colors.orangeAccent,
      ];
}
