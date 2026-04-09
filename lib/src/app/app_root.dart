import 'package:flutter/material.dart';

import 'package:my_project/src/home/home_page.dart';
import 'package:my_project/src/services/settings_store.dart';
import 'package:my_project/src/services/transcription_controller.dart';

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  final SettingsStore _settings = SettingsStore();
  late final TranscriptionController _transcription;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _transcription = TranscriptionController(settings: _settings);
    _settings.load().then((_) {
      if (!mounted) return;
      setState(() {
        _ready = true;
      });
    });
  }

  @override
  void dispose() {
    _transcription.dispose();
    _settings.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return const MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          body: Center(child: CircularProgressIndicator()),
        ),
      );
    }

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Live Transcription',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
      ),
      home: HomePage(
        settings: _settings,
        transcription: _transcription,
      ),
    );
  }
}
