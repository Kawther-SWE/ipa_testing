import 'dart:convert';
import 'dart:io';

import 'package:flutter_overlay_window/flutter_overlay_window.dart';

import 'package:my_project/src/core/app_constants.dart';
import 'package:my_project/src/services/settings_store.dart';

class OverlayBridge {
  static DateTime _lastPush = DateTime.fromMillisecondsSinceEpoch(0);

  static Future<void> showOverlay(SettingsStore settings) async {
    if (!Platform.isAndroid) return;

    final granted = await FlutterOverlayWindow.isPermissionGranted();
    final ok = granted || (await FlutterOverlayWindow.requestPermission() ?? false);
    if (!ok) return;
    if (await FlutterOverlayWindow.isActive()) return;

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
      kOverlayTypeKey: kOverlayTypeTranscriptUpdate,
      'text': text,
      'fontSize': settings.fontSize,
      'textColor': settings.textColor.toARGB32(),
    });

    try {
      await FlutterOverlayWindow.shareData(payload);
    } catch (_) {}
  }
}
