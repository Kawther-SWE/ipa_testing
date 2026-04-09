import 'package:flutter/widgets.dart';

import 'package:my_project/src/app/app_root.dart';
import 'package:my_project/src/overlay/overlay_app.dart';

export 'package:my_project/src/app/app_root.dart' show MyApp;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

@pragma('vm:entry-point')
void overlayMain() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const OverlayApp());
}
