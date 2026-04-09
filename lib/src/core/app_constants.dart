import 'package:flutter/services.dart';

const double kOverlayWidth = 320;
const double kOverlayHeight = 220;
const double kBubbleSize = 56;
const int kMaxTranscriptChars = 20000;
const String kServiceAccountAsset = 'assets/my-project-for-deaf-5ca65dcc5876.json';
const String kPrimaryLanguage = 'en-US';
const List<String> kAltLanguages = ['ar-SA'];
const int kAndroidPlaybackSampleRate = 16000;
const int kMicSampleRate = 48000;
const double kIosSpeechRestartIntervalSeconds = 50;
const String kOverlayTypeKey = 'type';
const String kOverlayTypeTranscriptUpdate = 'transcript_update';
const String kOverlayTypeCopyRequest = 'copy_request';
const String kOverlayTypeClearRequest = 'clear_request';

const MethodChannel kNativeClipboardChannel = MethodChannel('my_project/clipboard');
