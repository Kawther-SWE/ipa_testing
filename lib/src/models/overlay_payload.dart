import 'dart:convert';

import 'package:my_project/src/core/app_constants.dart';

class OverlayPayload {
  OverlayPayload({this.type, this.text, this.fontSize, this.textColor});

  final String? type;
  final String? text;
  final double? fontSize;
  final int? textColor;

  bool get isEmpty => text == null && fontSize == null && textColor == null;
  bool get isTranscriptUpdate =>
      type == null || type == kOverlayTypeTranscriptUpdate;
  bool get isCopyRequest => type == kOverlayTypeCopyRequest;
  bool get isClearRequest => type == kOverlayTypeClearRequest;

  factory OverlayPayload.from(dynamic event) {
    try {
      if (event is String) {
        final data = jsonDecode(event);
        if (data is Map) {
          return OverlayPayload(
            type: data[kOverlayTypeKey] as String?,
            text: data['text'] as String?,
            fontSize: (data['fontSize'] as num?)?.toDouble(),
            textColor: data['textColor'] as int?,
          );
        }
      }
      if (event is Map) {
        return OverlayPayload(
          type: event[kOverlayTypeKey] as String?,
          text: event['text'] as String?,
          fontSize: (event['fontSize'] as num?)?.toDouble(),
          textColor: event['textColor'] as int?,
        );
      }
    } catch (_) {}
    return OverlayPayload();
  }
}
