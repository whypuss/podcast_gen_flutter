import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import '../models/voice_option.dart';

/// Complete edge-tts implementation in pure Dart for Flutter/Android
/// Uses Python proxy on Mac for Edge TTS WebSocket protocol
class EdgeTtsDart {
  // ═══════════════════════════════════════════════
  // CONSTANTS
  // ═══════════════════════════════════════════════

  /// Proxy URL for Edge TTS (runs on Mac). Default: auto-detect from platform.
  /// Can be set explicitly, e.g. 'http://192.168.31.124:50022'
  String? _proxyUrl;
  List<EdgeVoice>? _cachedVoices;

  void setProxy(String url) {
    _proxyUrl = url.endsWith('/') ? url.substring(0, url.length - 1) : url;
  }

  String get _ttsProxyUrl => _proxyUrl ?? 'http://192.168.31.124:8888';

  // ═══════════════════════════════════════════════
  // VOICE MODEL
  // ═══════════════════════════════════════════════

  EdgeVoice voiceFromJson(Map<String, dynamic> json) {
    return EdgeVoice(
      name: json['Name'] ?? '',
      shortName: json['ShortName'] ?? '',
      gender: json['Gender'] ?? 'Female',
      locale: json['Locale'] ?? '',
      friendlyName: json['FriendlyName'] ?? '',
      suggestedStyle: json['SuggestedStyle'] != null ? List<String>.from(json['SuggestedStyle']) : [],
    );
  }

  // ═══════════════════════════════════════════════
  // VOICE LIST API
  // ═══════════════════════════════════════════════

  Future<List<EdgeVoice>> getVoices({bool forceRefresh = false}) async {
    // Voice list is provided by the proxy server (edge-tts voices list endpoint)
    // For now, use the hardcoded fallback voices which cover all major languages
    return _fallbackVoices;
  }

  static final List<EdgeVoice> _fallbackVoices = [
    // Mandarin/Cantonese voices
    EdgeVoice(name: 'Microsoft Server Speech Text to Speech Voice (zh-CN, XiaoxiaoNeural)', shortName: 'zh-CN-XiaoxiaoNeural', gender: 'Female', locale: 'zh-CN', friendlyName: 'Xiaoxiao'),
    EdgeVoice(name: 'Microsoft Server Speech Text to Speech Voice (zh-CN, XiaoyiNeural)', shortName: 'zh-CN-XiaoyiNeural', gender: 'Female', locale: 'zh-CN', friendlyName: 'Xiaoyi'),
    EdgeVoice(name: 'Microsoft Server Speech Text to Speech Voice (zh-CN, YunjianNeural)', shortName: 'zh-CN-YunjianNeural', gender: 'Male', locale: 'zh-CN', friendlyName: 'Yunjian'),
    EdgeVoice(name: 'Microsoft Server Speech Text to Speech Voice (zh-CN, YunxiNeural)', shortName: 'zh-CN-YunxiNeural', gender: 'Male', locale: 'zh-CN', friendlyName: 'Yunxi'),
    EdgeVoice(name: 'Microsoft Server Speech Text to Speech Voice (zh-CN, YunxiaNeural)', shortName: 'zh-CN-YunxiaNeural', gender: 'Male', locale: 'zh-CN', friendlyName: 'Yunxia'),
    EdgeVoice(name: 'Microsoft Server Speech Text to Speech Voice (zh-CN, YunyangNeural)', shortName: 'zh-CN-YunyangNeural', gender: 'Male', locale: 'zh-CN', friendlyName: 'Yunyang'),
    EdgeVoice(name: 'Microsoft Server Speech Text to Speech Voice (zh-HK, HiuGaaiNeural)', shortName: 'zh-HK-HiuGaaiNeural', gender: 'Female', locale: 'zh-HK', friendlyName: 'HiuGaai'),
    EdgeVoice(name: 'Microsoft Server Speech Text to Speech Voice (zh-HK, HiuMaanNeural)', shortName: 'zh-HK-HiuMaanNeural', gender: 'Female', locale: 'zh-HK', friendlyName: 'HiuMaan'),
    EdgeVoice(name: 'Microsoft Server Speech Text to Speech Voice (zh-HK, WanLungNeural)', shortName: 'zh-HK-WanLungNeural', gender: 'Male', locale: 'zh-HK', friendlyName: 'WanLung'),
    // Japanese voices
    EdgeVoice(name: 'Microsoft Server Speech Text to Speech Voice (ja-JP, NanamiNeural)', shortName: 'ja-JP-NanamiNeural', gender: 'Female', locale: 'ja-JP', friendlyName: 'Nanami'),
    EdgeVoice(name: 'Microsoft Server Speech Text to Speech Voice (ja-JP, KeiichiNeural)', shortName: 'ja-JP-KeiichiNeural', gender: 'Male', locale: 'ja-JP', friendlyName: 'Keiichi'),
    // English voices
    EdgeVoice(name: 'Microsoft Server Speech Text to Speech Voice (en-US, AriaNeural)', shortName: 'en-US-AriaNeural', gender: 'Female', locale: 'en-US', friendlyName: 'Aria'),
    EdgeVoice(name: 'Microsoft Server Speech Text to Speech Voice (en-US, GuyNeural)', shortName: 'en-US-GuyNeural', gender: 'Male', locale: 'en-US', friendlyName: 'Guy'),
    EdgeVoice(name: 'Microsoft Server Speech Text to Speech Voice (en-US, JennyNeural)', shortName: 'en-US-JennyNeural', gender: 'Female', locale: 'en-US', friendlyName: 'Jenny'),
  ];

  // ═══════════════════════════════════════════════
  // TTS SYNTHESIS
  // ═══════════════════════════════════════════════

  /// Synthesize speech to MP3 bytes via Edge TTS proxy on Mac
  Future<Uint8List?> synthesize({
    required String text,
    required String voiceShortName,
    double rate = 1.0,
    double pitch = 1.0,
    double volume = 1.0,
    void Function(String)? debugCallback,
  }) async {
    debugCallback?.call('🌐 連接 Edge TTS 代理 (${_ttsProxyUrl})...');

    try {
      final uri = Uri.parse('$_ttsProxyUrl/tts');
      final bodyBytes = utf8.encode(jsonEncode({
        'text': text,
        'voice': voiceShortName,
        'rate': rate,
        'pitch': pitch,
        'volume': volume,
      }));

      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 30);

      final req = await client.postUrl(uri);
      req.headers.set('Content-Type', 'application/json; charset=utf-8');
      req.headers.set('Content-Length', '${bodyBytes.length}');
      req.add(bodyBytes);

      debugCallback?.call('📤 發送 ${bodyBytes.length} bytes...');
      final resp = await req.close();

      if (resp.statusCode != 200) {
        final err = await resp.transform(utf8.decoder).join();
        debugCallback?.call('❌ HTTP ${resp.statusCode}: $err');
        client.close();
        return null;
      }

      final audioBytes = <int>[];
      await for (final chunk in resp) {
        audioBytes.addAll(chunk);
        debugCallback?.call('🔊 +${chunk.length} bytes');
      }

      client.close();
      debugCallback?.call('✅ 完成，共 ${audioBytes.length} bytes');

      if (audioBytes.isEmpty) {
        debugCallback?.call('❌ 無音頻數據');
        return null;
      }
      return Uint8List.fromList(audioBytes);
    } on HttpException catch (e) {
      debugCallback?.call('❌ HttpException: $e');
    } on SocketException catch (e) {
      debugCallback?.call('❌ SocketException: $e');
    } catch (e) {
      debugCallback?.call('❌ 異常: $e');
    }
    return null;
  }

  /// Synthesize to MP3 file, returns file path
  Future<String?> synthesizeToFile({
    required String text,
    required String voiceShortName,
    required String outputPath,
    double rate = 1.0,
    double pitch = 1.0,
    double volume = 1.0,
    void Function(String)? debugCallback,
  }) async {
    final audio = await synthesize(
      text: text,
      voiceShortName: voiceShortName,
      rate: rate,
      pitch: pitch,
      volume: volume,
      debugCallback: debugCallback,
    );
    if (audio == null) return null;

    final file = File(outputPath);
    await file.writeAsBytes(audio);
    return outputPath;
  }

  /// Generate podcast: synthesize all segments, save each to file, return paths
  Future<List<Segment>> generatePodcast({
    required String script,
    required String voice1,
    required String voice2,
    required String narrationVoice,
    required double speed,
    required Function(String) onProgress,
    void Function(String)? debugCallback,
  }) async {
    final lines = parseScript(script);
    final segments = <Segment>[];
    final dir = await getTemporaryDirectory();

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

      // Resolve short name
      String shortName = voiceKey;
      if (!voiceKey.contains('Neural')) {
        // It's a locale key like "zh-HK", find first matching voice
        final voices = await getVoices();
        final found = voices.firstWhere(
          (v) => v.locale == voiceKey && v.gender == 'Female',
          orElse: () => voices.firstWhere((v) => v.locale == voiceKey, orElse: () => _fallbackVoices.first),
        );
        shortName = found.shortName;
      }

      final filePath = '${dir.path}/segment_${i}_${DateTime.now().millisecondsSinceEpoch}.mp3';
      final result = await synthesizeToFile(
        text: line.text,
        voiceShortName: shortName,
        outputPath: filePath,
        rate: speed,
        debugCallback: debugCallback,
      );

      segments.add(Segment(
        index: i,
        speaker: line.speaker,
        text: line.text,
        audioPath: result,
        success: result != null,
        error: result == null ? 'Failed to generate audio' : null,
        duration: (line.text.length / (speed * 5)).clamp(1.0, 30.0),
      ));
    }

    return segments;
  }

  /// Merge multiple MP3 files into one
  Future<String?> mergeMp3Files(List<String> inputPaths, String outputPath) async {
    // Simple concatenation for MP3 files
    // For a production app, use a proper MP3 merge library
    final outputFile = File(outputPath);
    final sink = outputFile.openWrite();

    try {
      for (final path in inputPaths) {
        final file = File(path);
        if (await file.exists()) {
          sink.add(await file.readAsBytes());
        }
      }
      await sink.close();
      return outputPath;
    } catch (_) {
      return null;
    }
  }

  // ═══════════════════════════════════════════════
  // HELPERS
  // ═══════════════════════════════════════════════

  /// Parse script into speaker/text pairs
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
    _cachedVoices = null;
  }
}

/// Edge TTS Voice model
class EdgeVoice {
  final String name;
  final String shortName;
  final String gender;
  final String locale;
  final String friendlyName;
  final List<String> suggestedStyle;

  EdgeVoice({
    required this.name,
    required this.shortName,
    required this.gender,
    required this.locale,
    required this.friendlyName,
    this.suggestedStyle = const [],
  });

  @override
  String toString() => '$friendlyName ($locale, $gender)';
}