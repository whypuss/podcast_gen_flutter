import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../models/voice_option.dart';
import 'native_edge_tts.dart';

/// Edge TTS service with dual backends:
/// - Direct WebSocket (iOS/macOS/Linux)
/// - HTTP proxy fallback (Android — dart:io WebSocket has URL parsing bug)
class EdgeTtsDart {
  // ═══════════════════════════════════════════════
  // EDGE TTS CONSTANTS
  // ═══════════════════════════════════════════════

  static const String _trustedClientToken =
      '6A5AA1D4EAFF4E9FB37E23D68491D6F4';
  static const String _baseWsUrl =
      'wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1'
      '?TrustedClientToken=$_trustedClientToken';

  static const String _chromeVersion = '143.0.3650.75';
  static const String _chromeMajor = '143';

  // HTTP proxy URL — Mac Python FastAPI proxy (fallback for Android)
  // TODO: Auto-discover or configure this address
  static const String _proxyUrl = 'http://192.168.31.124:8888';

  // ═══════════════════════════════════════════════
  // DRM HELPERS (from edge-tts drm.py)
  // ═══════════════════════════════════════════════

  static const int _winEpochOffset = 11644473600000;

  String _generateSecMsGec() {
    final unixMs = DateTime.now().toUtc().millisecondsSinceEpoch;
    final winTicks = (unixMs + _winEpochOffset) * 10000;
    final roundedTicks = (winTicks ~/ 3000000000) * 3000000000;
    final toHash = '$roundedTicks$_trustedClientToken';
    final bytes = sha256.convert(utf8.encode(toHash)).bytes;
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join().toUpperCase();
  }

  String _generateMuid() {
    final rnd = Random.secure();
    final bytes = List<int>.generate(16, (_) => rnd.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join().toUpperCase();
  }

  String _generateConnectionId() {
    final rnd = Random.secure();
    final bytes = List<int>.generate(16, (_) => rnd.nextInt(256));
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0,8)}-${hex.substring(8,12)}-${hex.substring(12,16)}'
           '-${hex.substring(16,20)}-${hex.substring(20,32)}';
  }

  String _buildWsUrl() {
    final connId = _generateConnectionId();
    final secGec = _generateSecMsGec();
    final version = '1-$_chromeVersion';
    return '$_baseWsUrl'
           '&ConnectionId=$connId'
           '&Sec-MS-GEC=$secGec'
           '&Sec-MS-GEC-Version=$version';
  }

  Map<String, String> _buildWsHeaders() {
    return {
      'Pragma': 'no-cache',
      'Cache-Control': 'no-cache',
      'Accept-Encoding': 'gzip, deflate, br, zstd',
      'Accept-Language': 'en-US,en;q=0.9',
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/$_chromeMajor.0.0.0 Safari/537.36 Edg/$_chromeMajor.0.0.0',
      'Origin': 'chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold',
      'Sec-WebSocket-Version': '13',
      'Cookie': 'muid=${_generateMuid()};',
    };
  }

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

  /// JavaScript-style date string (matching edge-tts Python library exactly)
  String _buildTimestamp() {
    final now = DateTime.now().toUtc();
    final weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
                    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final wd = weekdays[now.weekday - 1];
    final mon = months[now.month - 1];
    final pad = (int v) => v.toString().padLeft(2, '0');
    return '$wd $mon ${now.day} ${now.year} '
        '${pad(now.hour)}:${pad(now.minute)}:${pad(now.second)} '
        'GMT+0000 (Coordinated Universal Time)';
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
    // Edge TTS rate/pitch format: +N% / -N% for rate, +/-NHz for pitch/volume
    final ratePct = ((rate - 1.0) * 100).round();
    final pitchHz = ((pitch - 1.0) * 50).round();
    final rateStr = ratePct >= 0 ? '+$ratePct%' : '$ratePct%';
    final pitchStr = pitchHz >= 0 ? '+${pitchHz}Hz' : '${pitchHz}Hz';

    return 'X-RequestId:${_genReqId()}\r\n'
        'Content-Type:application/ssml+xml\r\n'
        'X-Timestamp:$ts\r\n'
        'Path:ssml\r\n\r\n'
        "<speak version='1.0' "
        "xmlns='http://www.w3.org/2001/10/synthesis' "
        "xml:lang='${_voiceLocale(voiceShortName)}'>"
        "<voice name='$voiceShortName'>"
        "<prosody pitch='$pitchStr' rate='$rateStr' volume='+0%'>"
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

  /// Main synthesize method — Android uses NativeEdgeTts (Ktor), others use Dart WebSocket.
  Future<Uint8List?> synthesize({
    required String text,
    required String voiceShortName,
    double rate = 1.0,
    double pitch = 1.0,
    double volume = 1.0,
    void Function(String)? debugCallback,
  }) async {
    // Android: use native Ktor WebSocket engine
    if (Platform.isAndroid) {
      debugCallback?.call('🤖 Android: 使用原生 Ktor 引擎...');
      final native = NativeEdgeTts();
      try {
        final bytes = await native.synthesize(
          text: text,
          voiceShortName: voiceShortName,
          rate: rate,
          pitch: pitch,
          volume: volume,
          debugCallback: debugCallback,
        );
        return bytes;
      } finally {
        await native.stop();
      }
    }

    // iOS/macOS/Linux: use Dart WebSocket
    debugCallback?.call('🍎 嘗試直接 Edge TTS...');
    try {
      final result = await _synthesizeViaWebSocket(text, voiceShortName, rate, pitch, debugCallback);
      if (result != null) return result;
    } catch (e) {
      debugCallback?.call('⚠️ WebSocket 失敗: $e');
    }

    // Fallback: HTTP proxy on Mac (for Android with dart:io WebSocket bug)
    debugCallback?.call('🔄 切換到 HTTP 代理...');
    try {
      final result = await _synthesizeViaHttpProxy(text, voiceShortName, rate, pitch, volume, debugCallback);
      if (result != null) return result;
    } catch (e) {
      debugCallback?.call('❌ HTTP 代理也失敗: $e');
    }

    return null;
  }

  /// Direct WebSocket synthesis (iOS/macOS/Linux)
  Future<Uint8List?> _synthesizeViaWebSocket(
    String text,
    String voiceShortName,
    double rate,
    double pitch,
    void Function(String)? debugCallback,
  ) async {
    final wsUrl = _buildWsUrl();
    debugCallback?.call('🔌 連接 Edge TTS...');

    WebSocket? ws;
    try {
      ws = await WebSocket.connect(
        wsUrl,
        headers: _buildWsHeaders(),
      ).timeout(const Duration(seconds: 10));

      debugCallback?.call('✅ 已連接');

      ws.add(_buildSpeechConfig());
      await Future.delayed(const Duration(milliseconds: 50));
      ws.add(_buildSsml(text, voiceShortName, rate, pitch));

      final audioChunks = <int>[];
      await for (final msg in ws) {
        if (msg is List<int>) {
          final data = Uint8List.fromList(msg);
          if (data.length >= 2) {
            final headerLen = (data[0] << 8) | data[1];
            final audioStart = 2 + headerLen;
            if (audioStart < data.length) {
              audioChunks.addAll(data.sublist(audioStart));
            }
          }
        } else if (msg is String) {
          if (msg.contains('turn.end')) break;
        }
      }

      if (audioChunks.isEmpty) return null;
      debugCallback?.call('🎉 直接 WebSocket 成功: ${audioChunks.length} bytes');
      return Uint8List.fromList(audioChunks);

    } catch (e) {
      debugCallback?.call('❌ WebSocket 異常: $e');
      return null;
    } finally {
      ws?.close();
    }
  }

  /// HTTP proxy synthesis (Android fallback via Mac Python proxy)
  Future<Uint8List?> _synthesizeViaHttpProxy(
    String text,
    String voiceShortName,
    double rate,
    double pitch,
    double volume,
    void Function(String)? debugCallback,
  ) async {
    debugCallback?.call("🌐 連接 Mac HTTP 代理 $_proxyUrl...");

    final rateStr = rate >= 1.0
        ? '+${((rate - 1.0) * 100).round()}%'
        : '${((rate - 1.0) * 100).round()}%';
    final pitchStr = pitch >= 1.0
        ? '+${((pitch - 1.0) * 50).round()}Hz'
        : '${((pitch - 1.0) * 50).round()}Hz';
    final volStr = volume >= 1.0
        ? '+${((volume - 1.0) * 100).round()}%'
        : '${((volume - 1.0) * 100).round()}%';

    final body = jsonEncode({
      'text': text,
      'voice': voiceShortName,
      'rate': rateStr,
      'pitch': pitchStr,
      'volume': volStr,
    });

    try {
      final response = await http.post(
        Uri.parse('$_proxyUrl/tts'),
        headers: {'Content-Type': 'application/json'},
        body: body,
      ).timeout(const Duration(seconds: 30));

      debugCallback?.call("📥 HTTP 代理響應: ${response.statusCode}");

      if (response.statusCode == 200 && response.bodyBytes.isNotEmpty) {
        debugCallback?.call('🎉 HTTP 代理成功: ${response.bodyBytes.length} bytes');
        return Uint8List.fromList(response.bodyBytes);
      } else {
        debugCallback?.call('❌ HTTP 代理失敗: ${response.statusCode}');
        return null;
      }
    } catch (e) {
      debugCallback?.call('❌ HTTP 代理異常: $e');
      return null;
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
