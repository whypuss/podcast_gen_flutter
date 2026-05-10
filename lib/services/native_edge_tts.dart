import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import '../models/voice_option.dart';

/// Native Edge TTS via Android Ktor WebSocket — bypasses dart:io WebSocket URL parsing bug.
class NativeEdgeTts {
  static const _channel = MethodChannel('com.podcastgen.podcast_gen/edgetts');

  /// Synthesize speech using native Android Ktor WebSocket engine.
  Future<Uint8List?> synthesize({
    required String text,
    required String voiceShortName,
    double rate = 1.0,
    double pitch = 1.0,
    double volume = 1.0,
    void Function(String)? debugCallback,
  }) async {
    debugCallback?.call('🔌 使用原生 Ktor 引擎...');

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

      final result = await _channel.invokeMethod<String>('synthesize', {
        'text': text,
        'voice': voiceShortName,
        'rate': rateStr,
        'pitch': pitchStr,
        'volume': volStr,
        'outputFormat': 'audio-24khz-48kbitrate-mono-mp3',
      });

      if (result != null) {
        final file = File(result);
        if (await file.exists()) {
          final bytes = await file.readAsBytes();
          await file.delete();
          debugCallback?.call('🎉 原生合成成功: ${bytes.length} bytes');
          return bytes;
        }
      }

      debugCallback?.call('❌ 原生合成返回空');
      return null;

    } on PlatformException catch (e) {
      debugCallback?.call('❌ 原生異常: ${e.message}');
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
