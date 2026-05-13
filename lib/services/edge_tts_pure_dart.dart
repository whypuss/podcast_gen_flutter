import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:crypto/crypto.dart';

/// Pure Dart Edge TTS implementation using WebSocket.
/// No proxy, no native code — connects directly to Edge TTS cloud.
class EdgeTtsPureDart {
  static const String _token = '6A5AA1D4EAFF4E9FB37E23D68491D6F4';
  static const String _chromeVersion = '143.0.3650.75';
  static const String _chromeMajor = '143';

  static String _generateSecMsGec() {
    // Round down Unix ms to nearest 5 minutes (300000ms)
    final unixMs = DateTime.now().toUtc().millisecondsSinceEpoch;
    final rounded = (unixMs ~/ 300000) * 300000;
    // Convert to Windows file time (100-ns intervals since 1601-01-01)
    // Unix epoch 1970-01-01 = 11644473600000 in Windows file time
    final winTicks = (rounded + 11644473600000) * 10000;
    final toHash = '${winTicks}_$_token';
    final bytes = sha256.convert(utf8.encode(toHash)).bytes;
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join().toUpperCase();
  }

  static String _generateMuid() {
    final rnd = Random.secure();
    final bytes = List<int>.generate(16, (_) => rnd.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join().toUpperCase();
  }

  static String _generateConnectionId() {
    final rnd = Random.secure();
    final bytes = List<int>.generate(16, (_) => rnd.nextInt(256));
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0,8)}-${hex.substring(8,12)}-${hex.substring(12,16)}'
        '-${hex.substring(16,20)}-${hex.substring(20,32)}';
  }

  static String _buildWsUrl() {
    final connId = _generateConnectionId();
    final secGec = _generateSecMsGec();
    final version = '1-$_chromeVersion';
    return 'wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1'
        '?TrustedClientToken=$_token'
        '&ConnectionId=$connId'
        '&Sec-MS-GEC=$secGec'
        '&Sec-MS-GEC-Version=$version';
  }

  static Map<String, String> _buildWsHeaders() {
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

  /// Synthesize text to audio file. Returns file path on success, null on failure.
  Future<String?> synthesize({
    required String text,
    required String voice,  // e.g. "zh-CN-XiaoxiaoNeural"
    required String rate,   // e.g. "+0%" or "-10%"
    required String pitch,  // e.g. "+0Hz" or "-10Hz"
    required String volume, // e.g. "+0%"
    String outputFormat = 'audio-24khz-48kbitrate-mono-mp3',
    void Function(String)? debugCallback,
  }) async {
    // Parse voice: "zh-CN-XiaoxiaoNeural" -> {"zh-CN", "Xiaoxiao"}
    final parts = voice.split('-');
    String lang = 'en-US';
    String voiceName = voice;
    if (parts.length >= 3) {
      lang = '${parts[0]}-${parts[1]}';
      voiceName = parts.sublist(2).join('-');
    }

    debugCallback?.call('🌐 連接 Edge TTS...');
    print('EdgeTts: 🌐 連接 Edge TTS...');

    WebSocketChannel? channel;
    IOSink? sink;
    RandomAccessFile? raf;
    String? outputPath;

    try {
      final wsUrl = _buildWsUrl();
      final headers = _buildWsHeaders();
      print('EdgeTts: URL=${wsUrl.substring(0, 100)}...');

      final socket = await WebSocket.connect(
        wsUrl,
        headers: headers,
      ).timeout(const Duration(seconds: 15));

      channel = IOWebSocketChannel(socket);

      debugCallback?.call('✅ WebSocket 已連接');
      print('EdgeTts: ✅ WebSocket 已連接');

      // 1. Send speech.config (connection setup)
      final timestamp = _makeTimestamp();
      final configPayload = json.encode({
        'context': {
          'synthesis': {
            'audio': {
              'metadataoptions': {
                'sentenceBoundaryEnabled': 'false',
                'wordBoundaryEnabled': 'false',
              },
              'outputFormat': outputFormat,
            }
          }
        }
      });

      final configMsg =
          'X-Timestamp:$timestamp\r\n'
          'Content-Type:application/json; charset=utf-8\r\n'
          'Path:speech.config\r\n\r\n'
          '$configPayload\r\n';

      channel.sink.add(configMsg);
      debugCallback?.call('📤 已發送 speech.config');
      print('EdgeTts: 📤 已發送 speech.config');

      // 2. Build SSML
      final ssml = _buildSsml(
        text: text,
        voiceName: voiceName,
        lang: lang,
        rate: rate,
        pitch: pitch,
        volume: volume,
        outputFormat: outputFormat,
        timestamp: timestamp,
      );

      channel.sink.add(ssml);
      debugCallback?.call('📤 已發送 SSML');
      print('EdgeTts: 📤 已發送 SSML');

      // 3. Receive binary audio chunks
      final tempDir = Directory.systemTemp;
      outputPath =
          '${tempDir.path}/edge_tts_${DateTime.now().millisecondsSinceEpoch}.mp3';
      raf = await File(outputPath).open(mode: FileMode.write);

      bool audioStarted = false;

      await for (final message in channel.stream) {
        if (message is List<int>) {
          // Binary message — audio data
          if (message.length < 2) continue;
          final headerLen = _getUint16BE(message, 0);
          if (message.length < 2 + headerLen) continue;

          final headerBytes = message.sublist(2, 2 + headerLen);
          final audioData = message.sublist(2 + headerLen);

          final headerStr = utf8.decode(headerBytes, allowMalformed: true);
          String? path;
          for (final line in headerStr.split('\r\n')) {
            final idx = line.indexOf(':');
            if (idx > 0 && line.substring(0, idx).trim() == 'Path') {
              path = line.substring(idx + 1).trim();
              break;
            }
          }

          if (path == 'audio') {
            if (!audioStarted) {
              debugCallback?.call('🔊 收到第一個音頻塊');
              print('EdgeTts: 🔊 收到第一個音頻塊');
              audioStarted = true;
            }
            await raf!.writeFrom(audioData);
          }
        } else if (message is String) {
          // TEXT message — turn.end is here
          String? path;
          final idx = message.indexOf('\r\n\r\n');
          if (idx >= 0) {
            final headerStr = message.substring(0, idx);
            for (final line in headerStr.split('\r\n')) {
              final i = line.indexOf(':');
              if (i > 0 && line.substring(0, i).trim() == 'Path') {
                path = line.substring(i + 1).trim();
                break;
              }
            }
          }

          if (path == 'turn.end') {
            debugCallback?.call('🏁 Edge TTS 完成');
            print('EdgeTts: 🏁 Edge TTS 完成');
            break;
          } else if (path == 'audio.metadata') {
            // Ignore metadata
          } else if (path != null && path != 'response' && path != 'turn.start') {
            debugCallback?.call('📨 TEXT: path=$path');
            print('EdgeTts: 📨 TEXT: path=$path msg=${message.substring(0, message.length > 80 ? 80 : message.length)}');
          }
        }
      }

      await raf.close();
      raf = null;

      final file = File(outputPath!);
      if (await file.exists() && await file.length() > 100) {
        final size = await file.length();
        debugCallback?.call('🎉 合成成功: $size bytes');
        print('EdgeTts: 🎉 合成成功: $size bytes');

        // Copy to Downloads so we can retrieve it
        try {
          final downloadsDir = Directory('/storage/emulated/0/Download');
          final destPath =
              '${downloadsDir.path}/PodcastGen_EdgeTTS_${DateTime.now().millisecondsSinceEpoch}.mp3';
          await File(outputPath!).copy(destPath);
          debugCallback?.call('📁 已複製到: $destPath');
          print('EdgeTts: 📁 已複製到: $destPath');
        } catch (e) {
          print('EdgeTts: ⚠️ 複製到下載失敗: $e');
        }

        return outputPath;
      } else {
        debugCallback?.call('❌ 檔案缺失或太小');
        print('EdgeTts: ❌ 檔案缺失或太小');
        return null;
      }
    } catch (e, st) {
      print('EdgeTts: ❌ EXCEPTION: $e');
      print('EdgeTts: ❌ Stack: $st');
      debugCallback?.call('❌ EdgeTtsPureDart EXCEPTION: $e');
      return null;
    } finally {
      await channel?.sink.close();
      await sink?.close();
      await raf?.close();
    }
  }

  String _makeTimestamp() {
    final now = DateTime.now().toUtc();
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    final wkday = days[now.weekday - 1];
    final month = months[now.month - 1];
    final str =
        '$wkday, ${now.day.toString().padLeft(2, '0')} $month ${now.year} '
        '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}:'
        '${now.second.toString().padLeft(2, '0')} GMT';
    return str;
  }

  String _buildSsml({
    required String text,
    required String voiceName,
    required String lang,
    required String rate,
    required String pitch,
    required String volume,
    required String outputFormat,
    required String timestamp,
  }) {
    final ssml = '<speak version=\'1.0\' xmlns=\'http://www.w3.org/2001/10/synthesis\' '
        'xml:lang=\'$lang\'><voice name=\'$voiceName\' '
        'lang=\'$lang\' rate=\'$rate\' pitch=\'$pitch\' volume=\'$volume\'>'
        '${_escapeSsml(text)}</voice></speak>';

    return 'X-Timestamp:$timestamp\r\n'
        'Content-Type:application/ssml+xml\r\n'
        'Path:ssml\r\n\r\n'
        '$ssml\r\n';
  }

  String _escapeSsml(String text) {
    return text
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;');
  }

  int _getUint16BE(List<int> data, int offset) {
    return (data[offset] << 8) | data[offset + 1];
  }

  Future<void> stop() async {}
}
