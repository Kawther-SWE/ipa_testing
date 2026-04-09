import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';

import 'package:my_project/src/core/app_constants.dart';
import 'package:my_project/src/models/overlay_payload.dart';
import 'package:my_project/src/services/settings_store.dart';
import 'package:my_project/src/widgets/transcript_window.dart';

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
    if (!payload.isTranscriptUpdate || payload.isEmpty) return;
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
      onClear: _clear,
    );

    return Material(
      color: Colors.transparent,
      child: GestureDetector(
        onDoubleTap: _toggleCollapsed,
        onTap: _collapsed ? _toggleCollapsed : null,
        child: window,
      ),
    );
  }

  Future<void> _copy() async {
    if (_text.isEmpty) return;
    var copied = false;

    try {
      copied = await kNativeClipboardChannel.invokeMethod<bool>(
            'setText',
            {'text': _text},
          ) ??
          false;
    } catch (_) {}

    if (!copied) {
      try {
        await Clipboard.setData(ClipboardData(text: _text));
        copied = true;
      } catch (_) {}
    }

    if (!copied) {
      final payload = jsonEncode({
        kOverlayTypeKey: kOverlayTypeCopyRequest,
        'text': _text,
      });

      try {
        await FlutterOverlayWindow.shareData(payload);
      } catch (_) {}
    }
  }

  Future<void> _clear() async {
    if (_text.isNotEmpty) {
      setState(() {
        _text = '';
      });
    }

    final payload = jsonEncode({
      kOverlayTypeKey: kOverlayTypeClearRequest,
    });

    try {
      await FlutterOverlayWindow.shareData(payload);
    } catch (_) {}
  }
}
