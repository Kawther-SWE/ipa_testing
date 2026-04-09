import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:my_project/src/models/settings_snapshot.dart';

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
