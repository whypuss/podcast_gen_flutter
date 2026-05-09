import 'package:flutter/services.dart';

/// Native audio player using Android MediaPlayer via platform channel.
/// No Flutter plugin needed - uses MethodChannel directly.
class AudioPlayerService {
  static const MethodChannel _channel =
      MethodChannel('com.podcastgen.podcast_gen/audio');

  bool _isPlaying = false;
  String? _currentFile;

  bool get isPlaying => _isPlaying;
  String? get currentFile => _currentFile;

  Future<bool> play(String filePath) async {
    try {
      _currentFile = filePath;
      _isPlaying = true;
      final result = await _channel.invokeMethod<bool>('play', {
        'filePath': filePath,
      });
      return result ?? false;
    } on PlatformException catch (e) {
      _isPlaying = false;
      print('AudioPlayer.play error: ${e.message}');
      return false;
    }
  }

  Future<bool> stop() async {
    try {
      final result = await _channel.invokeMethod<bool>('stop');
      _isPlaying = false;
      _currentFile = null;
      return result ?? true;
    } on PlatformException catch (e) {
      print('AudioPlayer.stop error: ${e.message}');
      return false;
    }
  }

  Future<bool> pause() async {
    try {
      final result = await _channel.invokeMethod<bool>('pause');
      _isPlaying = false;
      return result ?? false;
    } on PlatformException catch (e) {
      print('AudioPlayer.pause error: ${e.message}');
      return false;
    }
  }

  Future<bool> resume() async {
    try {
      final result = await _channel.invokeMethod<bool>('resume');
      _isPlaying = true;
      return result ?? false;
    } on PlatformException catch (e) {
      print('AudioPlayer.resume error: ${e.message}');
      return false;
    }
  }

  Future<bool> get isCurrentlyPlaying async {
    try {
      final result = await _channel.invokeMethod<bool>('isPlaying');
      _isPlaying = result ?? false;
      return _isPlaying;
    } on PlatformException {
      return false;
    }
  }

  Future<int> getDuration() async {
    try {
      final result = await _channel.invokeMethod<int>('getDuration');
      return result ?? 0;
    } on PlatformException {
      return 0;
    }
  }

  Future<int> getCurrentPosition() async {
    try {
      final result = await _channel.invokeMethod<int>('getCurrentPosition');
      return result ?? 0;
    } on PlatformException {
      return 0;
    }
  }
}
