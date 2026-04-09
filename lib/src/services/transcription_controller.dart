import 'dart:async';

import 'package:audio_io/audio_io.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:google_speech/endless_streaming_service_beta.dart'
    as stt_streaming;
import 'package:google_speech/generated/google/cloud/speech/v1p1beta1/cloud_speech.pb.dart'
    as stt_pb;
import 'package:google_speech/google_speech.dart' as stt;
import 'package:permission_handler/permission_handler.dart';

import 'package:my_project/src/core/app_constants.dart';
import 'package:my_project/src/services/android_playback_capture.dart';
import 'package:my_project/src/services/ios_speech_transcriber.dart';
import 'package:my_project/src/services/overlay_bridge.dart';
import 'package:my_project/src/services/settings_store.dart';

class TranscriptionController extends ChangeNotifier {
  TranscriptionController({required this.settings});

  final SettingsStore settings;
  final AudioIo _audioIo = AudioIo.instance;
  final AndroidPlaybackCapture _playbackCapture = AndroidPlaybackCapture();
  final IosSpeechTranscriber _iosSpeechTranscriber = IosSpeechTranscriber();

  stt_streaming.EndlessStreamingServiceBeta? _speech;
  StreamController<List<int>>? _audioController;
  StreamSubscription<List<double>>? _audioSub;
  StreamSubscription<Uint8List>? _playbackSub;
  StreamSubscription<stt_pb.StreamingRecognizeResponse>? _sttSub;
  StreamSubscription<Map<dynamic, dynamic>>? _iosSpeechSub;

  bool _running = false;
  bool _usingPlaybackCapture = false;
  bool _usingIosNativeSpeech = false;
  bool _disposed = false;
  String _finalText = '';
  String _partialText = '';
  String _status = 'Idle';

  bool get isRunning => _running;
  String get status => _status;
  String get fullText {
    if (_partialText.isEmpty) return _finalText;
    if (_finalText.isEmpty) return _partialText;
    return _appendAndTrim(_finalText, _partialText, kMaxTranscriptChars);
  }

  Future<void> start() async {
    if (_running) return;

    final audioGranted = await _ensureMicrophonePermission();
    if (!audioGranted) {
      _status = 'Audio capture permission denied';
      _broadcast();
      return;
    }

    _running = true;
    _status = 'Starting...';
    _broadcast();

    if (_isIOS) {
      if (_partialText.isNotEmpty) {
        _finalText = _appendAndTrim(_finalText, _partialText, kMaxTranscriptChars);
        _partialText = '';
      }
      try {
        await _startIosSpeech();
      } catch (error) {
        _status = 'Failed to start iOS speech: $error';
        _running = false;
        await _shutdownAudioPipeline();
        _broadcast();
      }
      return;
    }

    final sampleRate = _isAndroid ? kAndroidPlaybackSampleRate : kMicSampleRate;

    try {
      final serviceAccountJson = await rootBundle.loadString(
        kServiceAccountAsset,
      );
      final serviceAccount = stt.ServiceAccount.fromString(serviceAccountJson);
      _speech = stt_streaming.EndlessStreamingServiceBeta.viaServiceAccount(
        serviceAccount,
      );

      final config = stt.RecognitionConfigBeta(
        encoding: stt.AudioEncoding.LINEAR16,
        sampleRateHertz: sampleRate,
        languageCode: kPrimaryLanguage,
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
      _speech!.endlessStreamingRecognize(
        streamingConfig,
        _audioController!.stream,
      );

      _sttSub = _speech!.endlessStream.listen(
        _onSttData,
        onError: _onSttError,
        onDone: _onSttDone,
      );

      if (_isAndroid) {
        _usingPlaybackCapture = true;
        _usingIosNativeSpeech = false;
        _playbackSub = _playbackCapture.audioStream.listen(
          _onPlaybackAudioData,
          onError: _onAudioError,
          cancelOnError: true,
        );

        final started = await _playbackCapture.start();
        if (!started) {
          _status =
              'Playback capture denied or unavailable for this device/app audio';
          _running = false;
          await _shutdownAudioPipeline();
          _broadcast();
          return;
        }
      } else {
        _usingPlaybackCapture = false;
        _usingIosNativeSpeech = false;
        await _audioIo.requestLatency(AudioIoLatency.Balanced);
        await _audioIo.start();
        _audioSub = _audioIo.input.listen(
          _onAudioData,
          onError: _onAudioError,
          cancelOnError: true,
        );
      }

      _status = 'Listening...';
      _broadcast();
    } catch (error) {
      _status = 'Failed to start capture: $error';
      _running = false;
      await _shutdownAudioPipeline();
      _broadcast();
    }
  }

  Future<void> stop() async {
    if (!_running) return;

    _running = false;
    _status = 'Stopped';
    await _shutdownAudioPipeline();

    _broadcast();
  }

  void clear() {
    _finalText = '';
    _partialText = '';
    if (_usingIosNativeSpeech) {
      unawaited(_iosSpeechTranscriber.clear());
    }
    _broadcast();
  }

  @override
  void dispose() {
    _disposed = true;
    stop();
    super.dispose();
  }

  void _onAudioData(List<double> samples) {
    _pushAudioBytes(_floatToPcm16(samples));
  }

  void _onPlaybackAudioData(Uint8List bytes) {
    _pushAudioBytes(bytes);
  }

  void _pushAudioBytes(List<int> bytes) {
    if (!_running || _audioController == null) return;
    try {
      _audioController!.add(bytes);
    } catch (error) {
      _onAudioError(error);
    }
  }

  Future<void> _startIosSpeech() async {
    _usingPlaybackCapture = false;
    _usingIosNativeSpeech = true;
    await _iosSpeechSub?.cancel();
    _iosSpeechSub = _iosSpeechTranscriber.events.listen(
      _onIosSpeechEvent,
      onError: _onAudioError,
      cancelOnError: true,
    );

    final started = await _iosSpeechTranscriber.start(
      primaryLocale: kPrimaryLanguage,
      alternateLocales: kAltLanguages,
      initialTranscript: _finalText,
      requiresOnDevice: true,
      restartIntervalSeconds: kIosSpeechRestartIntervalSeconds,
    );

    if (!started) {
      throw StateError('Speech recognition is unavailable on this iOS device');
    }
  }

  void _onIosSpeechEvent(Map<dynamic, dynamic> event) {
    if (!_running) return;

    final type = event['type']?.toString();
    switch (type) {
      case 'status':
        final value = _stringValue(event['value']);
        if (value != null && value.isNotEmpty) {
          _status = value;
        }
        break;
      case 'transcript':
        final finalText = _stringValue(event['finalText']);
        final partialText = _stringValue(event['partialText']);
        if (finalText != null) {
          _finalText = _trimToMaxChars(finalText);
        }
        if (partialText != null) {
          _partialText = partialText;
        }
        break;
      case 'error':
        final message = _stringValue(event['message']) ??
            'Unknown iOS speech recognition error';
        _status = 'Speech error: $message';
        _running = false;
        unawaited(_shutdownAudioPipeline());
        break;
    }

    _broadcast();
  }

  void _onAudioError(Object error) {
    if (!_running) return;
    _status = 'Audio error: $error';
    _running = false;
    unawaited(_shutdownAudioPipeline());
    _broadcast();
  }

  void _onSttData(stt_pb.StreamingRecognizeResponse data) {
    if (!_running) return;
    for (final result in data.results) {
      if (result.alternatives.isEmpty) continue;
      final transcript = result.alternatives.first.transcript.trim();
      if (transcript.isEmpty) continue;
      if (result.isFinal) {
        _finalText = _appendAndTrim(
          _finalText,
          transcript,
          kMaxTranscriptChars,
        );
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
    unawaited(_shutdownAudioPipeline());
    _broadcast();
  }

  void _onSttDone() {
    if (!_running) return;
    _status = 'Stream ended';
    _running = false;
    unawaited(_shutdownAudioPipeline());
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

  String _appendAndTrim(String base, String next, int maxChars) {
    final merged = base.isEmpty ? next : '$base $next';
    return _trimToMaxChars(merged, maxChars: maxChars);
  }

  String _trimToMaxChars(String text, {int maxChars = kMaxTranscriptChars}) {
    if (text.length <= maxChars) return text;
    final trimmed = text.substring(text.length - maxChars);
    final firstSpace = trimmed.indexOf(' ');
    return firstSpace == -1 ? trimmed : trimmed.substring(firstSpace + 1);
  }

  String? _stringValue(Object? value) {
    if (value == null) return null;
    return value.toString();
  }

  Future<void> _shutdownAudioPipeline() async {
    await _audioSub?.cancel();
    _audioSub = null;
    await _playbackSub?.cancel();
    _playbackSub = null;
    await _iosSpeechSub?.cancel();
    _iosSpeechSub = null;
    if (_usingPlaybackCapture) {
      await _playbackCapture.stop();
    } else if (_usingIosNativeSpeech) {
      await _iosSpeechTranscriber.stop();
    } else {
      try {
        await _audioIo.stop();
      } catch (_) {}
    }
    _usingPlaybackCapture = false;
    _usingIosNativeSpeech = false;
    await _audioController?.close();
    _audioController = null;
    await _sttSub?.cancel();
    _sttSub = null;
    _speech?.dispose();
    _speech = null;
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

  bool get _isAndroid => defaultTargetPlatform == TargetPlatform.android;
  bool get _isIOS => defaultTargetPlatform == TargetPlatform.iOS;
}
