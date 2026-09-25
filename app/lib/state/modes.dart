import '../services/core_session.dart';

/// "16:9", "4:3", "1:1".
String aspectOf(StreamMode m) {
  final g = m.width.gcd(m.height);
  return '${m.width ~/ g}:${m.height ~/ g}';
}

String resolutionLabel(int height) => height == 2160 ? '4K' : '${height}p';

/// The phone's mode for a Video-card tap: the given [aspect] / [height] / [fps] where set, everything else as close
/// to [current] as the phone allows. Null if [modes] is empty.
StreamMode? pickMode(List<StreamMode> modes, StreamMode current, {String? aspect, int? height, int? fps}) {
  StreamMode? best;
  (int, int, int)? bestScore;
  for (final m in modes) {
    // Lexicographic: the field that was tapped first, then stay near the current height, then near the current fps.
    final score = (
      aspectOf(m) == (aspect ?? aspectOf(current)) ? 0 : 1,
      (m.height - (height ?? current.height)).abs(),
      (m.fps - (fps ?? current.fps)).abs(),
    );
    if (bestScore == null || _less(score, bestScore)) {
      best = m;
      bestScore = score;
    }
  }
  return best;
}

bool _less((int, int, int) a, (int, int, int) b) =>
    a.$1 != b.$1 ? a.$1 < b.$1 : (a.$2 != b.$2 ? a.$2 < b.$2 : a.$3 < b.$3);
