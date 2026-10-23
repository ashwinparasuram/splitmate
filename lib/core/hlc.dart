/// Hybrid logical clock. Gives a total order consistent with causality even
/// when device wall clocks disagree.
///
/// String form sorts lexicographically: `<15-digit ms>-<5-digit counter>-<node>`.
class Hlc implements Comparable<Hlc> {
  const Hlc(this.millis, this.counter, this.node);

  final int millis;
  final int counter;
  final String node;

  static const maxCounter = 99999;

  static Hlc parse(String s) {
    final parts = s.split('-');
    if (parts.length < 3 || parts[0].length != 15 || parts[1].length != 5) {
      throw FormatException('Invalid HLC', s);
    }
    return Hlc(int.parse(parts[0]), int.parse(parts[1]), parts.sublist(2).join('-'));
  }

  static bool isValid(String s) {
    try {
      parse(s);
      return true;
    } on FormatException {
      return false;
    }
  }

  @override
  String toString() =>
      '${millis.toString().padLeft(15, '0')}-${counter.toString().padLeft(5, '0')}-$node';

  @override
  int compareTo(Hlc other) => toString().compareTo(other.toString());
}

class HlcClock {
  HlcClock(this.node, {Hlc? last, int Function()? now})
      : _last = last ?? Hlc(0, 0, node),
        _now = now ?? (() => DateTime.now().toUtc().millisecondsSinceEpoch);

  final String node;
  Hlc _last;
  final int Function() _now;

  Hlc get last => _last;

  /// Timestamp for a local event.
  Hlc tick() {
    final wall = _now();
    if (wall > _last.millis) {
      _last = Hlc(wall, 0, node);
    } else {
      _last = Hlc(_last.millis, _bump(_last.counter), node);
    }
    return _last;
  }

  /// Merge a remote timestamp so later local events sort after it.
  void observe(Hlc remote) {
    final wall = _now();
    final maxMillis = [wall, _last.millis, remote.millis].reduce((a, b) => a > b ? a : b);
    int counter;
    if (maxMillis == _last.millis && maxMillis == remote.millis) {
      counter = _bump(_last.counter > remote.counter ? _last.counter : remote.counter);
    } else if (maxMillis == _last.millis) {
      counter = _bump(_last.counter);
    } else if (maxMillis == remote.millis) {
      counter = _bump(remote.counter);
    } else {
      counter = 0;
    }
    _last = Hlc(maxMillis, counter, node);
  }

  static int _bump(int c) {
    if (c >= Hlc.maxCounter) throw StateError('HLC counter overflow');
    return c + 1;
  }
}
