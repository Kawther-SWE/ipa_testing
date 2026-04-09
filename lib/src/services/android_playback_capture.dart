import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class AndroidPlaybackCapture {
  static const MethodChannel _methodChannel =
      MethodChannel('my_project/playback_capture');
  static const EventChannel _audioEventChannel =
      EventChannel('my_project/playback_audio_stream');

  Stream<Uint8List>? _audioStream;

  Stream<Uint8List> get audioStream =>
      _audioStream ??= _audioEventChannel.receiveBroadcastStream().map((event) {
        if (event is Uint8List) return event;
        if (event is List<int>) return Uint8List.fromList(event);
        throw FormatException('Unexpected playback audio event: $event');
      });

  Future<bool> start() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _methodChannel.invokeMethod<bool>('startPlaybackCapture') ??
          false;
    } on PlatformException {
      return false;
    }
  }

  Future<void> stop() async {
    if (!Platform.isAndroid) return;
    try {
      await _methodChannel.invokeMethod('stopPlaybackCapture');
    } on PlatformException catch (error) {
      debugPrint('stopPlaybackCapture failed: $error');
    }
  }
}
