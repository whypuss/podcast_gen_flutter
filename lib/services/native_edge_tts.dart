import 'dart:typed_data';
import 'package:flutter/services.dart';

/// Edge TTS using native Android OkHttp WebSocket — no proxy, no Dart WebSocket.
/// Works completely standalone on Android via Method Channel.
class NativeEdgeTts {
  static const _channel = MethodChannel('com.podcastgen.podcast_gen/edgetts');

  /// Synthesize speech using native OkHttp Edge TTS WebSocket.
  /// Returns audio bytes (Uint8List) on success, null on failure.
  Future<Uint8List?> synthesize({
    required String text,
    required String voiceShortName,
    double rate = 1.0,
    double pitch = 1.0,
    double volume = 1.0,
    void Function(String)? debugCallback,
  }) async {
    debugCallback?.call('🔌 使用原生 OkHttp Edge TTS 引擎...');

    try {
      // Convert rate/pitch/volume to edge-tts string format
      final rateStr = rate >= 1.0
          ? '+${((rate - 1.0) * 100).round()}%'
          : '${((rate - 1.0) * 100).round()}%';
      final pitchStr = pitch >= 1.0
          ? '+${((pitch - 1.0) * 50).round()}Hz'
          : '${((pitch - 1.0) * 50).round()}Hz';
      final volStr = volume >= 1.0
          ? '+${((volume - 1.0) * 100).round()}%'
          : '${((volume - 1.0) * 100).round()}%';

      // Call native OkHttp WebSocket engine
      final result = await _channel.invokeMethod<Uint8List>('synthesize', {
        'text': text,
        'voice': voiceShortName,
        'rate': rateStr,
        'pitch': pitchStr,
        'volume': volStr,
        'outputFormat': 'audio-24khz-48kbitrate-mono-mp3',
      });

      if (result != null && result.isNotEmpty) {
        debugCallback?.call('🎉 合成成功: ${result.length} bytes');
        return result;
      }

      debugCallback?.call('❌ 合成返回空');
      return null;

    } on PlatformException catch (e) {
      debugCallback?.call('❌ PlatformException: ${e.message}');
      return null;
    } catch (e) {
      debugCallback?.call('❌ 錯誤: $e');
      return null;
    }
  }

  Future<void> stop() async {
    try {
      await _channel.invokeMethod('stop');
    } catch (_) {}
  }
}
