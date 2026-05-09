import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import '../models/voice_option.dart';

/// Direct Edge TTS via WebSocket — no proxy needed.
/// Works on iOS and Android without any server.
/// Based on the edge-tts Python library protocol.
class EdgeTtsDart {
  // ═══════════════════════════════════════════════
  // EDGE TTS CONSTANTS
  // ═══════════════════════════════════════════════

  static const String _wsUrl =
      'wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1'
      '?TrustedClientToken=6A5AA1D4EAFF4E9FB37E23D68491D6F4';

  // Edge TTS sends audio in chunks, we accumulate them here
  Uint8List? _audioBuffer;

  // ═══════════════════════════════════════════════
  // VOICE LIST (hardcoded — covers major languages)
  // ═══════════════════════════════════════════════

  static final List<EdgeVoice> _fallbackVoices = [
    // Mandarin / Cantonese
    EdgeVoice(name: 'Microsoft Server Speech Text to Speech Voice (zh-CN, XiaoxiaoNeural)', shortName: 'zh-CN-XiaoxiaoNeural', gender: 'Female', locale: 'zh-CN', friendlyName: 'Xiaoxiao'),
    EdgeVoice(name: 'Microsoft Server Speech Text to Speech Voice (zh-CN, XiaoyiNeural)', shortName: 'zh-CN-XiaoyiNeural', gender: 'Female', locale: 'zh-CN', friendlyName: 'Xiaoyi'),
    EdgeVoice(name: 'Microsoft Server Speech Text to Speech Voice (zh-CN, YunjianNeural)', shortName: 'zh-CN-YunjianNeural', gender: 'Male', locale: 'zh-CN', friendlyName: 'Yunjian'),
    EdgeVoice(name: 'Microsoft Server Speech Text to Speech Voice (zh-CN, YunxiNeural)', shortName: 'zh-CN-YunxiNeural', gender: 'Male', locale: 'zh-CN', friendlyName: 'Yunxi'),
    EdgeVoice(name: 'Microsoft Server Speech Text to Speech Voice (zh-CN, YunxiaNeural)', shortName: 'zh-CN-YunxiaNeural', gender: 'Male', locale: 'zh-CN', friendlyName: 'Yunxia'),
    EdgeVoice(name: 'Microsoft Server Speech Text to Speech Voice (zh-CN, YunyangNeural)', shortName: 'zh-CN-YunyangNeural', gender: 'Male', locale: 'zh-CN', friendlyName: 'Yunyang'),
    EdgeVoice(name: 'Microsoft Server Speech Text to Speech Voice (zh-TW, HsiaoYuNeural)', shortName: 'zh-TW-HsiaoYuNeural', gender: 'Female', locale: 'zh-TW', friendlyName: 'HsiaoYu'),
    EdgeVoice(name: 'Microsoft Server Speech Text to Speech Voice (zh-TW, YunJheNeural)', shortName: 'zh-TW-YunJheNeural', gender: 'Male', locale: 'zh-TW', friendlyName: 'YunJhe'),
    EdgeVoice(name: 'Microsoft Server Speech Text to Speech Voice (zh-HK, HiuGaaiNeural)', shortName: 'zh-HK-HiuGaaiNeural', gender: 'Female', locale: 'zh-HK', friendlyName: 'HiuGaai'),
    EdgeVoice(name: 'Microsoft Server Speech Text to Speech Voice (zh-HK, HiuMaanNeural)', shortName: 'zh-HK-HiuMaanNeural', gender: 'Female', locale: 'zh-HK', friendlyName: 'HiuMaan'),
    EdgeVoice(name: 'Microsoft Server Speech Text to Speech Voice (zh-HK, WanLungNeural)', shortName: 'zh-HK-WanLungNeural', gender: 'Male', locale: 'zh-HK', friendlyName: 'WanLung'),
    // Japanese
    EdgeVoice(name: 'Microsoft Server Speech Text to Speech Voice (ja-JP, NanamiNeural)', shortName: 'ja-JP-NanamiNeural', gender: 'Female', locale: 'ja-JP', friendlyName: 'Nanami'),
    EdgeVoice(name: 'Microsoft Server Speech Text to Speech Voice (ja-JP, KeiichiNeural)', shortName: 'ja-JP-KeiichiNeural', gender: 'Male', locale: 'ja-JP', friendlyName: 'Keiichi'),
    // English
    EdgeVoice(name: 'Microsoft Server Speech Text to Speech Voice (en-US, AriaNeural)', shortName: 'en-US-AriaNeural', gender: 'Female', locale: 'en-US', friendlyName: 'Aria'),
    EdgeVoice(name: 'Microsoft Server Speech Text to Speech Voice (en-US, GuyNeural)', shortName: 'en-US-GuyNeural', gender: 'Male', locale: 'en-US', friendlyName: 'Guy'),
    EdgeVoice(name: 'Microsoft Server Speech Text to Speech Voice (en-US, JennyNeural)', shortName: 'en-US-JennyNeural', gender: 'Female', locale: 'en-US', friendlyName: 'Jenny'),
  ];

  // ═══════════════════════════════════════════════
  // VOICE LIST API
  // ═══════════════════════════════════════════════

  Future<List<EdgeVoice>> getVoices({bool forceRefresh = false}) async {
    return _fallbackVoices;
  }

  // ═══════════════════════════════════════════════
  // WEBSOCKET MESSAGE BUILDERS
  // ═══════════════════════════════════════════════

  String _buildTimestamp() {
    final now = DateTime.now().toUtc();
    final pad = (int v) => v.toString().padLeft(2, '0');
    return '${now.year}-${pad(now.month)}-${pad(now.day)}-'
        '${pad(now.hour)}:${pad(now.minute)}:${pad(now.second)}.'
        '${(now.millisecond).toString().padLeft(3, '0')}Z';
  }

  String _buildSpeechConfig() {
    final ts = _buildTimestamp();
    return 'X-RequestId:${_genReqId()}\r\n'
        'Content-Type:application/json; charset=utf-8\r\n'
        'X-Timestamp:$ts\r\n'
        'Path:speech.config\r\n\r\n'
        '{"context":{"synthesis":{"audio":{"metadataoptions":'
        '{"sentenceBoundaryEnabled":"false","wordBoundaryEnabled":"false"},'
        '"outputFormat":"audio-24khz-48kbitrate-mono-mp3"}}}}';
  }

  String _buildSsml(String text, String voiceShortName, double rate, double pitch) {
    final ts = _buildTimestamp();
    // Edge TTS rate/pitch: 1.0 = normal. Convert from speed multiplier.
    // speed: 1.0=normal, >1=faster, <1=slower
    // pitch: 1.0=normal
    final ratePercent = ((rate - 1.0) * 100).round();
    final pitchHz = ((pitch - 1.0) * 50).round(); // ±50Hz
    final ssmlPitch = pitch != 1.0 ? ' msst Pitch="${pitchHz}Hz"' : '';

    return 'X-RequestId:${_genReqId()}\r\n'
        'Content-Type:application/ssml+xml\r\n'
        'X-Timestamp:$ts\r\n'
        'Path:ssml\r\n\r\n'
        '<speak version='"'"'1.0'"'"' '
        'xmlns='"'"'http://www.w3.org/2001/10/synthesis'"'"' '
        'xml:lang='"'"'${_voiceLocale(voiceShortName)}'"'"'>'
        '<voice name='"'"'$voiceShortName'"'"'$ssmlPitch>'
        '<prosody rate='"'"'$ratePercent%'"'"' pitch="${pitchHz}Hz">'
        '$text'
        '</prosody></voice></speak>';
  }

  String _voiceLocale(String shortName) {
    final parts = shortName.split('-');
    if (parts.length >= 2) return '${parts[0]}-${parts[1]}';
    return 'en-US';
  }

  // Simple request ID generator
  int _reqIdCounter = 0;
  String _genReqId() {
    _reqIdCounter = (_reqIdCounter + 1) % 100000;
    return '${DateTime.now().millisecondsSinceEpoch.toRadixString(16).padLeft(12, '0')}${_reqIdCounter.toRadixString(16).padLeft(5, '0')}';
  }

  // ═══════════════════════════════════════════════
  // TTS SYNTHESIS
  // ═══════════════════════════════════════════════

  /// Synthesize speech to MP3 bytes via direct Edge TTS WebSocket.
  Future<Uint8List?> synthesize({
    required String text,
    required String voiceShortName,
    double rate = 1.0,
    double pitch = 1.0,
    double volume = 1.0,
    void Function(String)? debugCallback,
  }) async {
    // 1. 強制清洗 URL，避免末尾出現 # 或空格
    final cleanUrl = _wsUrl.trim().split('#')[0];
    debugCallback?.call('🔌 連接 Edge TTS (Android Fix Applied)...');

    WebSocket? ws;
    try {
      // 2. 建立連接：移除 protocols，更新 UA 和 Origin
      ws = await WebSocket.connect(
        cleanUrl,
        headers: {
          'Pragma': 'no-cache',
          'Cache-Control': 'no-cache',
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
              '(KHTML, like Gecko) Chrome/123.0.0.0 Safari/537.36 Edg/123.0.0.0',
          'Origin': 'chrome-extension://jdiccldjedidmcnnefciiohendbhjhj',
        },
      ).timeout(const Duration(seconds: 10));

      debugCallback?.call('✅ 已連接');

      // 3. 發送配置與 SSML
      ws.add(_buildSpeechConfig());
      await Future.delayed(const Duration(milliseconds: 50));
      ws.add(_buildSsml(text, voiceShortName, rate, pitch));

      final audioChunks = <int>[];

      // 4. 解析二進制流
      await for (final msg in ws) {
        if (msg is List<int>) {
          final data = Uint8List.fromList(msg);
          if (data.length >= 2) {
            // 解析 Header 長度 (Big-endian)
            final headerLen = (data[0] << 8) | data[1];
            final audioStart = 2 + headerLen;

            // 確保只提取音頻數據部分
            if (audioStart < data.length) {
              final audioPart = data.sublist(audioStart);
              audioChunks.addAll(audioPart);
              // debugCallback?.call('🔊 接收音頻幀: ${audioPart.length} bytes');
            }
          }
        } else if (msg is String) {
          if (msg.contains('turn.end')) {
            debugCallback?.call('🏁 收到結束信號 (turn.end)');
            break;
          }
        }
      }

      if (audioChunks.isEmpty) {
        debugCallback?.call('❌ 錯誤：未收到任何音頻數據');
        return null;
      }

      debugCallback?.call('🎉 合成完成，總計 ${audioChunks.length} bytes');
      return Uint8List.fromList(audioChunks);

    } catch (e) {
      debugCallback?.call('❌ 異常: $e');
      return null;
    } finally {
      await ws?.close();
    }
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

      String shortName = voiceKey;
      if (!voiceKey.contains('Neural')) {
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

  /// Merge multiple MP3 files into one (simple concatenation)
  Future<String?> mergeMp3Files(List<String> inputPaths, String outputPath) async {
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

  void dispose() {}
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
