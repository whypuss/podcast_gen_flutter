import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../models/voice_option.dart';
import '../services/edge_tts_dart.dart';
import '../services/audio_player_service.dart';
import '../widgets/text_area.dart';

const kDemoScript = '''[1] 大家好，歡迎來到 Podcast Gen！我是今天的主持人。
[2] 我是你的搭檔，今天我們來介紹這個強大的語音合成工具。
[1] 首先，什麼是 Podcast Gen 呢？
[2] 簡單來說，它是一款結合了 Edge TTS 語音合成技術的 Podcast 自動生成工具。
[1] 支援多種語言，包括中文、英語、日語、韓語等等。
[2] 而且音色非常自然，完全免費使用，適合內容創作者。
[1] 接下來，我們來看看如何使用這個工具。
[2] 第一步，選擇你喜歡的音色，這裡有多種選項。
[1] 第二步，輸入你的腳本內容，可以是任何主題的文章或文字。
[2] 第三步，點擊生成按鈕，系統會自動將文字轉換為語音。
[1] 生成的音頻可以即時播放，也可以下載保存。
[2] 這個工具非常適合用來製作教育類內容。
[1] 比如語言學習、知識科普、商業簡報等等。
[2] 而且所有功能都是免費的，無需註冊登入。
[1] 最後，讓我們來做一個簡單的總結。
[2] Podcast Gen 是一款方便快捷的語音合成工具，值得一試。
[1] 如果你有任何問題，歡迎在描述區留言。
[2] 今天的節目就到這裡，感謝大家的聆聽！
[1] 我是你的搭檔，下次見！''';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _tts = EdgeTtsDart();
  final _scriptCtrl = TextEditingController();
  final _player = AudioPlayerService();
  Timer? _playbackTimer;

  // Voice selections (edge short names)
  String _voice1 = 'zh-HK-HiuGaaiNeural';  // 粵語 (女)
  String _voice2 = 'zh-HK-WanLungNeural';   // 粵語 (男)
  String _narrationVoice = 'zh-HK-WanLungNeural'; // 粵語 (旁白)
  double _speed = 1.0;
  bool _mixed = true;
  int _activeTab = 0;

  bool _loading = false;
  String _progress = '';
  List<Segment> _segments = [];
  List<ParsedLine> _preview = [];
  int? _playingIdx;
  bool _isMergedPlaying = false;
  String? _mergedPath;

  // Cached voices
  List<EdgeVoice> _allVoices = [];
  bool _voicesLoaded = false;

  // Debug console
  final List<String> _debugLog = [];
  void _addDebug(String msg) {
    final ts = DateTime.now().toString().substring(11, 19);
    _debugLog.add('[$ts] $msg');
    if (_debugLog.length > 50) _debugLog.removeAt(0);
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    _scriptCtrl.text = kDemoScript;
    _updatePreview();
    _scriptCtrl.addListener(_updatePreview);
    _loadVoices();
  }

  void _writeDebug(String msg) {
    final ts = DateTime.now().toString().substring(11, 23);
    final line = "[$ts] $msg\n";
    try {
      File("/sdcard/app_debug.txt").writeAsStringSync(line, mode: FileMode.append);
    } catch (_) {}
    print("HERMES: $line");
  }

  Future<void> _loadVoices() async {
    _addDebug("HERMES: _loadVoices START");
    try {
      final voices = await _tts.getVoices();
      _addDebug("HERMES: _loadVoices got ${voices.length} voices");
      if (mounted) {
        setState(() {
          _allVoices = voices;
          _voicesLoaded = true;
        });
        _addDebug("HERMES: _loadVoices setState done, _voicesLoaded=true");
      }
    } catch (e, st) {
      _addDebug("HERMES: _loadVoices EXCEPTION: $e $st");
    }
  }

  @override
  void dispose() {
    _scriptCtrl.removeListener(_updatePreview);
    _scriptCtrl.dispose();
    _playbackTimer?.cancel();
    _player.stop();
    _tts.dispose();
    super.dispose();
  }

  void _updatePreview() {
    final parsed = _tts.parseScript(_scriptCtrl.text);
    if (mounted) setState(() => _preview = parsed);
  }

  Future<void> _generate() async {
    print("HERMES: _generate ENTRY");
    if (_loading) return;
    print("HERMES: _generate past loading check");
    setState(() {
      _loading = true;
      _segments = [];
      _mergedPath = null;
      _progress = '';
    });

    print("HERMES: _generate setState done, about to call generatePodcast");
    try {
      print("HERMES: _generate calling tts.generatePodcast now...");
      print("HERMES: _generate about to call tts.generatePodcast...");
      final segs = await _tts.generatePodcast(
        script: _scriptCtrl.text,
        voice1: _voice1,
        voice2: _voice2,
        narrationVoice: _narrationVoice,
        speed: _speed,
        onProgress: (p) {
          try {
            _addDebug(p);
          } catch (e) {
            print("HERMES: onProgress _addDebug EXCEPTION: $e");
          }
        },
        debugCallback: _addDebug,
      );

      print("HERMES: _generate back from generatePodcast, segs.length=${segs.length}");

      // Merge if requested
      String? merged;
      if (_mixed && segs.isNotEmpty && segs.every((s) => s.audioPath != null)) {
        final dir = await getTemporaryDirectory();
        merged = '${dir.path}/podcast_${DateTime.now().millisecondsSinceEpoch}.mp3';
        final paths = segs.where((s) => s.audioPath != null).map((s) => s.audioPath!).toList();
        final result = await _tts.mergeMp3Files(paths, merged);
        merged = result;
      }

      if (mounted) {
        setState(() {
          _segments = segs;
          _mergedPath = merged;
          if (segs.isNotEmpty) _activeTab = 1;
        });
      }
    } catch (e) {
      _addDebug('❌ 生成失敗: $e');
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
          _progress = '';
        });
      }
    }
  }

  Future<void> _playSeg(int idx) async {
    final seg = _segments[idx];
    if (seg.audioPath == null) return;

    await _player.stop();
    _playbackTimer?.cancel();
    if (mounted) setState(() => _playingIdx = idx);
    await _player.play(seg.audioPath!);
    // Poll for playback completion
    _playbackTimer = Timer.periodic(const Duration(milliseconds: 500), (timer) async {
      final playing = await _player.isCurrentlyPlaying;
      if (!playing) {
        timer.cancel();
        if (mounted) setState(() => _playingIdx = null);
      }
    });
  }

  Future<void> _playMerged() async {
    if (_mergedPath == null) return;
    if (_isMergedPlaying) {
      await _player.pause();
      setState(() => _isMergedPlaying = false);
    } else {
      await _player.play(_mergedPath!);
      setState(() => _isMergedPlaying = true);
    }
  }

  Future<void> _shareAudio(String path) async {
    await Share.shareXFiles([XFile(path)], text: 'PodcastGen 生成的音頻');
  }

  Future<void> _shareMerged() async {
    if (_mergedPath != null) await _shareAudio(_mergedPath!);
  }

  // Group voices by locale
  Map<String, List<EdgeVoice>> get _voicesByLocale {
    final map = <String, List<EdgeVoice>>{};
    for (final v in _allVoices) {
      map.putIfAbsent(v.locale, () => []).add(v);
    }
    return map;
  }

  String _localeLabel(String locale) {
    switch (locale) {
      case 'zh-CN': return '普通話';
      case 'zh-HK': return '粵語';
      case 'en-US': return '英語';
      case 'ja-JP': return '日語';
      case 'ko-KR': return '韓語';
      default: return locale;
    }
  }

  // Current locale tabs
  String _currentLocale = 'zh-CN';
  List<String> get _localeTabs {
    final locales = _voicesByLocale.keys.toList();
    // Prioritize useful ones
    final priority = ['zh-CN', 'zh-HK', 'en-US', 'ja-JP', 'ko-KR'];
    final sorted = <String>[];
    for (final l in priority) {
      if (locales.contains(l)) { sorted.add(l); locales.remove(l); }
    }
    sorted.addAll(locales);
    return sorted.take(6).toList();
  }

  List<EdgeVoice> get _currentLocaleVoices {
    return _voicesByLocale[_currentLocale] ?? [];
  }

  String _genderLabel(String gender) {
    return gender == 'Female' ? '女' : '男';
  }

  String _voiceLabel(String shortName) {
    // Chinese names for common voices
    final cnNames = {
      'zh-CN-XiaoxiaoNeural': '曉曉（女）',
      'zh-CN-XiaoyiNeural': '曉逸（女）',
      'zh-CN-YunjianNeural': '云劍（男）',
      'zh-CN-YunxiNeural': '云溪（男）',
      'zh-CN-YunxiaNeural': '云夏（男）',
      'zh-CN-YunyangNeural': '云揚（男）',
      'zh-HK-HiuGaaiNeural': '凱悅（女）',
      'zh-HK-HiuMaanNeural': '曉敏（女）',
      'zh-HK-WanLungNeural': '雲龍（男）',
    };
    if (cnNames.containsKey(shortName)) return cnNames[shortName]!;
    final voice = _allVoices.cast<EdgeVoice?>().firstWhere((v) => v?.shortName == shortName, orElse: () => null);
    if (voice != null) return '${voice.friendlyName}（${_genderLabel(voice.gender)}）';
    return shortName;
  }

  Color _speakerColor(String s) {
    return s == '1' ? const Color(0xFFFF2D55)
        : s == '2' ? const Color(0xFF5856D6)
        : const Color(0xFF34C759);
  }

  String _speakerLabel(String s) {
    return s == '1' ? '角色1'
        : s == '2' ? '角色2'
        : '角色3';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF2F2F7),
      body: SafeArea(
        child: Column(
          children: [
            _statusBar(),
            if (_voicesLoaded) _localeTabBar() else _voiceLoadingBar(),
            _tabBar(),
            Expanded(
              child: _activeTab == 0 ? _editTab() : _resultTab(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statusBar() {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              const Icon(Icons.mic, size: 20, color: Color(0xFF007AFF)),
              const SizedBox(width: 6),
              const Text(
                'PodcastGen',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
              ),
            ],
          ),
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: _voicesLoaded ? const Color(0xFF34C759) : const Color(0xFFFF9500),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  children: [
                    Icon(Icons.circle, size: 8, color: Colors.white),
                    const SizedBox(width: 5),
                    Text(
                      _voicesLoaded ? 'Edge TTS' : '加載中...',
                      style: const TextStyle(fontSize: 12, color: Colors.white),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _voiceLoadingBar() {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.all(12),
      child: const Center(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
            SizedBox(width: 8),
            Text('正在獲取 Edge 音色列表...', style: TextStyle(color: Color(0xFF8E8E93))),
          ],
        ),
      ),
    );
  }

  Widget _localeTabBar() {
    return Container(
      color: Colors.white,
      child: Row(
        children: _localeTabs.map((l) {
          final active = _currentLocale == l;
          return Expanded(
            child: GestureDetector(
              onTap: () => setState(() => _currentLocale = l),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                      color: active ? const Color(0xFF007AFF) : Colors.transparent,
                      width: 2,
                    ),
                  ),
                ),
                child: Text(
                  _localeLabel(l),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                    color: active ? const Color(0xFF007AFF) : const Color(0xFF8E8E93),
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _tabBar() {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        children: [
          _tabBtn('編輯', Icons.edit, 0),
          const SizedBox(width: 24),
          _tabBtn('結果', Icons.check_circle_outline, 1),
        ],
      ),
    );
  }

  Widget _tabBtn(String label, IconData icon, int idx) {
    final active = _activeTab == idx;
    return GestureDetector(
      onTap: () => setState(() => _activeTab = idx),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: active ? const Color(0xFF007AFF) : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Row(
          children: [
            Icon(icon, size: 16, color: active ? const Color(0xFF007AFF) : const Color(0xFF8E8E93)),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 15,
                fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                color: active ? const Color(0xFF007AFF) : const Color(0xFF8E8E93),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _editTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          _card([
            _cardLabel('腳本', Icons.description),
            TextArea(
              controller: _scriptCtrl,
              hint: '[1] 嘉賓1台詞\n[2] 嘉賓2台詞\n[3] 旁白',
              lines: 6,
            ),
            Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  '${_scriptCtrl.text.length} 字',
                  style: const TextStyle(fontSize: 12, color: Color(0xFFC7C7CC)),
                ),
              ),
            ),
          ]),
          _card([
            _cardLabel('預覽', Icons.visibility),
            if (_preview.isEmpty)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(20),
                  child: Text('輸入腳本查看分段', style: TextStyle(color: Color(0xFFC7C7CC))),
                ),
              )
            else
              ...(_preview.map((p) => Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF2F2F7),
                      borderRadius: BorderRadius.circular(8),
                      border: Border(left: BorderSide(color: _speakerColor(p.speaker), width: 3)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _speakerLabel(p.speaker),
                          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: _speakerColor(p.speaker)),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          p.text.length > 40 ? '${p.text.substring(0, 40)}...' : p.text,
                          style: const TextStyle(fontSize: 14),
                        ),
                      ],
                    ),
                  ))),
          ]),
          if (_voicesLoaded) _voiceCard(),
          _speedCard(),
          _card([
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('合併為單一 MP3', style: TextStyle(fontSize: 15)),
                Switch(
                  value: _mixed,
                  activeColor: const Color(0xFF34C759),
                  onChanged: (v) => setState(() => _mixed = v),
                ),
              ],
            ),
          ]),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _loading ? null : _generate,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF007AFF),
                disabledBackgroundColor: const Color(0xFF007AFF).withOpacity(0.6),
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: Text(
                _loading ? '$_progress' : '生成 Podcast',
                style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w600),
              ),
            ),
          ),
          // Debug console toggle
          if (_debugLog.isNotEmpty || _loading) ...[
            const SizedBox(height: 8),
            GestureDetector(
              onTap: () => _showDebugConsole(),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: const Color(0xFF1C1C1E),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.bug_report, size: 14, color: Color(0xFF30D158)),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        _loading ? '🔄 ${_debugLog.isNotEmpty ? _debugLog.last : _progress}...' : '🔍 查看調試日誌',
                        style: const TextStyle(fontSize: 12, color: Color(0xFF30D158), fontFamily: 'monospace'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const Icon(Icons.chevron_right, size: 14, color: Color(0xFF636366)),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 40),
        ],
      ),
    );
  }

  void _showDebugConsole() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1C1C1E),
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.6,
        minChildSize: 0.3,
        maxChildSize: 0.9,
        expand: false,
        builder: (_, scrollController) => Column(
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  const Icon(Icons.bug_report, color: Color(0xFF30D158)),
                  const SizedBox(width: 8),
                  const Text('調試日誌', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.delete_outline, color: Color(0xFF636366)),
                    onPressed: () {
                      _debugLog.clear();
                      if (mounted) setState(() {});
                      Navigator.pop(ctx);
                    },
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: Color(0xFF38383A)),
            Expanded(
              child: ListView.builder(
                controller: scrollController,
                padding: const EdgeInsets.all(12),
                itemCount: _debugLog.length,
                itemBuilder: (_, i) => Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    _debugLog[i],
                    style: TextStyle(
                      fontSize: 11,
                      fontFamily: 'monospace',
                      color: _debugLog[i].contains('❌') ? const Color(0xFFFF453A)
                          : _debugLog[i].contains('✅') ? const Color(0xFF30D158)
                          : const Color(0xFFE5E5EA),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _voiceCard() {
    return _card([
      _cardLabel('音色設定', Icons.record_voice_over),
      _voiceSelector('角色1', _voice1, (v) => setState(() => _voice1 = v)),
      const Divider(height: 1),
      _voiceSelector('角色2', _voice2, (v) => setState(() => _voice2 = v)),
      const Divider(height: 1),
      _voiceSelector('角色3', _narrationVoice, (v) => setState(() => _narrationVoice = v)),
    ]);
  }

  Widget _voiceSelector(String label, String currentVoice, Function(String) onChanged) {
    return GestureDetector(
      onTap: () => _showVoicePicker(currentVoice, onChanged),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: const TextStyle(fontSize: 15)),
            Row(
              children: [
                Text(
                  _voiceLabel(currentVoice),
                  style: const TextStyle(fontSize: 14, color: Color(0xFF8E8E93)),
                ),
                const SizedBox(width: 4),
                const Icon(Icons.chevron_right, size: 18, color: Color(0xFFC7C7CC)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _showVoicePicker(String current, Function(String) onChanged) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => Container(
        padding: const EdgeInsets.only(top: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(width: 36, height: 4, decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2))),
            const SizedBox(height: 12),
            const Text('選擇音色', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.5,
              ),
              child: ListView(
                shrinkWrap: true,
                children: _currentLocaleVoices.map((v) {
                  final selected = v.shortName == current;
                  return ListTile(
                    leading: Icon(v.gender == 'Female' ? Icons.person : Icons.person_outline,
                        color: selected ? const Color(0xFF007AFF) : Colors.grey),
                    title: Text(_voiceLabel(v.shortName), style: TextStyle(
                      fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                      color: selected ? const Color(0xFF007AFF) : Colors.black,
                    )),
                    subtitle: Text(v.shortName, style: const TextStyle(fontSize: 11)),
                    trailing: selected ? const Icon(Icons.check, color: Color(0xFF007AFF)) : null,
                    onTap: () {
                      onChanged(v.shortName);
                      Navigator.pop(ctx);
                    },
                  );
                }).toList(),
              ),
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  Widget _speedCard() {
    return _card([
      _cardLabel('語速 · ${_speed.toStringAsFixed(1)}x', Icons.speed),
      Slider(
        value: _speed,
        min: 0.5,
        max: 2.0,
        divisions: 15,
        activeColor: const Color(0xFF007AFF),
        onChanged: (v) => setState(() => _speed = v),
      ),
      const Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text('慢', style: TextStyle(fontSize: 12, color: Color(0xFF8E8E93))),
          Text('正常', style: TextStyle(fontSize: 12, color: Color(0xFF8E8E93))),
          Text('快', style: TextStyle(fontSize: 12, color: Color(0xFF8E8E93))),
        ],
      ),
    ]);
  }

  Widget _card(List<Widget> children) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
  }

  Widget _cardLabel(String text, IconData icon) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Icon(icon, size: 16, color: const Color(0xFF007AFF)),
          const SizedBox(width: 6),
          Text(text, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  Widget _resultTab() {
    if (_segments.isEmpty) {
      return const Center(
        child: Text(
          '還沒有生成結果\n切換到「編輯」標籤開始',
          textAlign: TextAlign.center,
          style: TextStyle(color: Color(0xFFC7C7CC), fontSize: 15),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (_mergedPath != null) ...[
          _mergedCard(),
          const SizedBox(height: 12),
        ],
        ...(_segments.map((s) => _segmentCard(s))),
      ],
    );
  }

  Widget _mergedCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(colors: [Color(0xFF007AFF), Color(0xFF5856D6)]),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          const Icon(Icons.audio_file, color: Colors.white, size: 32),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('合併 MP3', style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600)),
                Text('${_segments.length} 段音頻', style: TextStyle(color: Colors.white.withOpacity(0.8), fontSize: 13)),
              ],
            ),
          ),
          IconButton(
            icon: Icon(_isMergedPlaying ? Icons.pause_circle_filled : Icons.play_circle_filled, color: Colors.white, size: 36),
            onPressed: _playMerged,
          ),
          IconButton(
            icon: const Icon(Icons.share, color: Colors.white, size: 28),
            onPressed: _shareMerged,
          ),
        ],
      ),
    );
  }

  Widget _segmentCard(Segment s) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border(left: BorderSide(color: _speakerColor(s.speaker), width: 4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Icon(
                    s.speaker == '1' ? Icons.person : s.speaker == '2' ? Icons.person_outline : Icons.mic,
                    size: 16,
                    color: _speakerColor(s.speaker),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    _speakerLabel(s.speaker),
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _speakerColor(s.speaker)),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _voiceLabel(s.speaker == '1' ? _voice1 : s.speaker == '2' ? _voice2 : _narrationVoice),
                    style: const TextStyle(fontSize: 11, color: Color(0xFF8E8E93)),
                  ),
                ],
              ),
              if (s.success)
                const Icon(Icons.check_circle, size: 14, color: Color(0xFF34C759))
              else
                const Icon(Icons.error, size: 14, color: Color(0xFFFF3B30)),
            ],
          ),
          const SizedBox(height: 8),
          Text(s.text, style: const TextStyle(fontSize: 14)),
          if (s.success && s.audioPath != null) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                GestureDetector(
                  onTap: () => _playSeg(s.index),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    decoration: BoxDecoration(
                      color: _playingIdx == s.index ? const Color(0xFF007AFF) : const Color(0xFFF2F2F7),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          _playingIdx == s.index ? Icons.stop : Icons.play_arrow,
                          size: 16,
                          color: _playingIdx == s.index ? Colors.white : const Color(0xFF007AFF),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          _playingIdx == s.index ? '停止' : '播放',
                          style: TextStyle(fontSize: 13, color: _playingIdx == s.index ? Colors.white : const Color(0xFF007AFF)),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: () => _shareAudio(s.audioPath!),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF2F2F7),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Row(
                      children: [
                        Icon(Icons.share, size: 16, color: Color(0xFF8E8E93)),
                        SizedBox(width: 4),
                        Text('分享', style: TextStyle(fontSize: 13, color: Color(0xFF8E8E93))),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ],
          if (!s.success && s.error != null) ...[
            const SizedBox(height: 6),
            Text(s.error!, style: const TextStyle(fontSize: 12, color: Color(0xFFFF3B30))),
          ],
        ],
      ),
    );
  }
}