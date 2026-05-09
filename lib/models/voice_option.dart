class VoiceOption {
  final String key;
  final String label;
  const VoiceOption({required this.key, required this.label});
}

class VoiceGroup {
  final List<VoiceOption> all;
  const VoiceGroup({required this.all});
}

class Segment {
  final int index;
  final String speaker;
  final String text;
  final String? audioPath;
  final double? duration;
  final bool success;
  final String? error;

  Segment({
    required this.index,
    required this.speaker,
    required this.text,
    this.audioPath,
    this.duration,
    required this.success,
    this.error,
  });
}

class GenResult {
  final String jobId;
  final List<Segment> segments;
  final String? outputPath;
  final bool success;
  final String? error;

  GenResult({
    required this.jobId,
    required this.segments,
    this.outputPath,
    required this.success,
    this.error,
  });
}

class ParsedLine {
  final String speaker;
  final String text;
  ParsedLine({required this.speaker, required this.text});
}
