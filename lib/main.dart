import 'package:flutter/material.dart';
import 'screens/home_screen.dart';

void main() {
  runApp(const PodcastGenApp());
}

class PodcastGenApp extends StatelessWidget {
  const PodcastGenApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PodcastGen',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        primaryColor: const Color(0xFF007AFF),
        scaffoldBackgroundColor: const Color(0xFFF2F2F7),
        fontFamily: '.SF Pro Text',
        useMaterial3: false,
      ),
      home: const HomeScreen(),
    );
  }
}
