import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import '../models/voice_option.dart';

const kVoiceMap = {
  '粵語': VoiceGroup(all: [
    VoiceOption(key: 'zh-HK', label: '系統預設（粵語）'),
  ]),
  '國語': VoiceGroup(all: [
    VoiceOption(key: 'zh-CN', label: '系統預設（國語）'),
  ]),
  '英語': VoiceGroup(all: [
    VoiceOption(key: 'en-US', label: '系統預設（英語）'),
  ]),
  '日語': VoiceGroup(all: [
    VoiceOption(key: 'ja-JP', label: '系統預設（日語）'),
  ]),
};

class EdgeTtsService {
  final FlutterTts _tts = FlutterTts();
  bool _initialized = false;
  String _currentLang = 'zh-CN';
  List<Map<String, String>> _availableVoices = [];

  Future<void> _ensureInit() async {
    if (_initialized) return;
    await _tts.awaitSpeakCompletion(true);
    _initialized = true;
  }

  /// Query all available voices from the system TTS engine
  Future<List<Map<String, String>>> getAvailableVoices() async {
    await _ensureInit();
    try {
      final voices = await _tts.getVoices;
      if (voices != null) {
        _availableVoices = (voices as List).map((v) {
          final name = v['name']?.toString() ?? '';
          final lang = v['locale']?.toString() ?? '';
          return {'name': name, 'locale': lang, 'label': '$lang • $name'};
        }).toList();
        debugPrint('[TTS] Available voices: ${_availableVoices.length}');
        for (final v in _availableVoices) {
          debugPrint('  - ${v}');
        }
      }
    } catch (e) {
      debugPrint('[TTS] getVoices error: $e');
    }
    return _availableVoices;
  }

  /// Get voices for a specific language locale
  List<Map<String, String>> getVoicesForLocale(String localePrefix) {
    return _availableVoices
        .where((v) => v['locale']?.startsWith(localePrefix) ?? false)
        .toList();
  }

  Future<void> _setLanguage(String langCode) async {
    await _ensureInit();
    if (langCode == _currentLang) return;
    await _tts.stop();
    final result = await _tts.setLanguage(langCode);
    debugPrint('[TTS] setLanguage($langCode) → $result');
    _currentLang = langCode;
  }

  String _voiceToLang(String voiceKey) {
    if (voiceKey.startsWith('zh-HK')) return 'zh-HK';
    if (voiceKey.startsWith('zh')) return 'zh-CN';
    if (voiceKey.startsWith('ja')) return 'ja-JP';
    if (voiceKey.startsWith('en-GB')) return 'en-GB';
    if (voiceKey.startsWith('en')) return 'en-US';
    return 'zh-CN';
  }

  /// Speak text immediately
  Future<void> speakText(String text, String voiceKey, double speed) async {
    await _ensureInit();
    final lang = _voiceToLang(voiceKey);
    await _tts.stop();
    await _tts.setLanguage(lang);
    _currentLang = lang;
    final ttsRate = (speed * 0.75).clamp(0.3, 1.5);
    await _tts.setSpeechRate(ttsRate);
    await _tts.speak(text);
  }

  Future<void> stop() async {
    await _tts.stop();
  }

  Future<List<Segment>> generate({
    required String script,
    required String voice1,
    required String voice2,
    required String narrationVoice,
    required double speed,
    required Function(String) onProgress,
  }) async {
    final lines = parseScript(script);
    final segments = <Segment>[];

    for (int i = 0; i < lines.length; i++) {
      final line = lines[i];
      onProgress('生成 ${i + 1}/${lines.length}...');

      String voiceKey;
      if (line.speaker == '1') {
        voiceKey = voice1;
      } else if (line.speaker == '2') {
        voiceKey = voice2;
      } else {
        voiceKey = narrationVoice;
      }

      await _ensureInit();
      final lang = _voiceToLang(voiceKey);
      await _tts.stop();
      await _tts.setLanguage(lang);
      _currentLang = lang;

      final ttsRate = (speed * 0.75).clamp(0.3, 1.5);
      await _tts.setSpeechRate(ttsRate);

      final completer = Completer<void>();
      String? error;

      _tts.setCompletionHandler(() {
        if (!completer.isCompleted) completer.complete();
      });
      _tts.setErrorHandler((msg) {
        debugPrint('[TTS] error: $msg');
        error = msg;
        if (!completer.isCompleted) completer.complete();
      });
      _tts.setCancelHandler(() {
        if (!completer.isCompleted) completer.complete();
      });

      await _tts.speak(line.text);
      await completer.future.timeout(const Duration(seconds: 30), onTimeout: () {
        _tts.stop();
      });

      segments.add(Segment(
        index: i,
        speaker: line.speaker,
        text: line.text,
        audioPath: null, // streamed only, no file
        success: error == null,
        error: error,
        duration: (line.text.length / (speed * 5)).clamp(1.0, 30.0),
      ));
    }

    return segments;
  }

  /// Parse script lines into speaker/text pairs
  List<ParsedLine> parseScript(String script) {
    final lines = script.trim().split('\n');
    final result = <ParsedLine>[];
    int turn = 0;
    for (final raw in lines) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      final m = RegExp(r'^\[([123])\]\s*(.+)$', caseSensitive: false).firstMatch(line);
      if (m != null) {
        result.add(ParsedLine(speaker: m.group(1)!, text: m.group(2)!.trim()));
        turn++;
      } else {
        result.add(ParsedLine(speaker: turn++ % 2 == 0 ? '1' : '2', text: line));
      }
    }
    return result;
  }

  void dispose() {
    _tts.stop();
  }
}
