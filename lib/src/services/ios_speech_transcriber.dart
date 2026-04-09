import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class IosSpeechTranscriber {
  static const MethodChannel _methodChannel = MethodChannel('my_project/ios_speech');
  static const EventChannel _eventChannel = EventChannel(
    'my_project/ios_speech_events',
  );

  Stream<Map<dynamic, dynamic>>? _events;

  Stream<Map<dynamic, dynamic>> get events =>
      _events ??= _eventChannel.receiveBroadcastStream().map((event) {
        if (event is Map) {
          return Map<dynamic, dynamic>.from(event);
        }
        throw FormatException('Unexpected iOS speech event: $event');
      });

  Future<bool> start({
    required String primaryLocale,
    required List<String> alternateLocales,
    required String initialTranscript,
    bool requiresOnDevice = true,
    double restartIntervalSeconds = 50,
  }) async {
    if (!Platform.isIOS) return false;
    return await _methodChannel.invokeMethod<bool>('start', {
          'primaryLocale': primaryLocale,
          'alternateLocales': alternateLocales,
          'initialTranscript': initialTranscript,
          'requiresOnDevice': requiresOnDevice,
          'restartIntervalSeconds': restartIntervalSeconds,
        }) ??
        false;
  }

  Future<void> stop() async {
    if (!Platform.isIOS) return;
    try {
      await _methodChannel.invokeMethod('stop');
    } on PlatformException catch (error) {
      debugPrint('stop iOS speech failed: $error');
    }
  }

  Future<void> clear() async {
    if (!Platform.isIOS) return;
    try {
      await _methodChannel.invokeMethod('clear');
    } on PlatformException catch (error) {
      debugPrint('clear iOS speech failed: $error');
    }
  }
}
