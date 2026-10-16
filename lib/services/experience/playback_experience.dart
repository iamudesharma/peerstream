import 'dart:convert';

import 'journal_memory.dart' if (dart.library.io) 'journal_io.dart' as storage;

/// Local playback journal. Reliability observations use identities only;
/// explicitly requested offline saves retain their source locally for resuming.
class PlaybackExperience {
  PlaybackExperience({
    Future<Map<String, dynamic>> Function()? read,
    Future<void> Function(Map<String, dynamic>)? write,
    DateTime Function()? now,
  }) : _read = read ?? storage.readJournal,
       _write = write ?? storage.writeJournal,
       _now = now ?? DateTime.now;
  final Future<Map<String, dynamic>> Function() _read;
  final Future<void> Function(Map<String, dynamic>) _write;
  final DateTime Function() _now;
  Map<String, dynamic> _data = {};
  Future<void>? _loaded;
  Future<void> _tail = Future.value();
  Object? _loadError;
  Object? get loadError => _loadError;
  Future<void> load() {
    if (_loadError != null) _loaded = null;
    return _loaded ??= () async {
      try {
        _data = await _read();
        _loadError = null;
      } catch (error) {
        _loadError = error;
      }
    }();
  }

  /// Untested sources have neutral score; a single observation is low confidence.
  double score(String key) {
    final rows = _data['reliability'] as Map?;
    final row = rows?[key] as Map?;
    if (row == null) return 0;
    final at = DateTime.tryParse(row['at'] as String? ?? '');
    if (at == null || _now().difference(at) > const Duration(days: 7)) return 0;
    final samples = (row['samples'] as num?)?.toInt() ?? 0;
    final successes = (row['successes'] as num?)?.toDouble() ?? 0;
    final stalls = (row['stalls'] as num?)?.toInt() ?? 0;
    final latency = (row['latency'] as num?)?.toDouble() ?? 10000;
    return ((successes * 2 - samples) - stalls * 0.5 - latency / 30000) /
        (samples + 2);
  }

  Future<void> observe(
    String key, {
    required bool success,
    int startupMs = 0,
    int stalls = 0,
  }) => update((data) {
    final rows = Map<String, dynamic>.from(data['reliability'] as Map? ?? {});
    rows.removeWhere((_, value) {
      final at = DateTime.tryParse((value as Map)['at'] as String? ?? '');
      return at == null || _now().difference(at) > const Duration(days: 7);
    });
    final old = Map<String, dynamic>.from(rows.remove(key) as Map? ?? {});
    final n = (old['samples'] as num?)?.toInt() ?? 0;
    rows[key] = {
      'at': _now().toUtc().toIso8601String(),
      'samples': (n + 1).clamp(1, 20),
      'successes':
          (((old['successes'] as num?)?.toDouble() ?? 0) *
                      (n >= 20 ? 0.95 : 1) +
                  (success ? 1 : 0))
              .clamp(0, 20),
      'stalls': stalls.clamp(0, 20),
      'latency': success
          ? ((old['latency'] as num? ?? startupMs) * 0.7 + startupMs * 0.3)
          : (old['latency'] ?? 10000),
    };
    while (rows.length > 128) {
      rows.remove(rows.keys.first);
    }
    data['reliability'] = rows;
  });

  Future<void> recordStall(String key) => update((data) {
    final rows = Map<String, dynamic>.from(data['reliability'] as Map? ?? {});
    final old = Map<String, dynamic>.from(rows[key] as Map? ?? {});
    if (old.isEmpty) return;
    old['stalls'] = ((old['stalls'] as num? ?? 0).toInt() + 1).clamp(0, 20);
    rows[key] = old;
    data['reliability'] = rows;
  });

  Set<String> get watchedMedia =>
      section('watched').values
          .whereType<Map>()
          .map((row) => row['media'])
          .whereType<String>()
          .toSet();

  Future<void> markWatched(String key, String media) => update((data) {
    final rows = Map<String, dynamic>.from(data['watched'] as Map? ?? {});
    rows.remove(key);
    rows[key] = {'media': media, 'at': _now().toUtc().toIso8601String()};
    while (rows.length > 2000) {
      rows.remove(rows.keys.first);
    }
    data['watched'] = rows;
  });

  Map<String, dynamic> section(String key) =>
      Map<String, dynamic>.from(_data[key] as Map? ?? {});
  Future<void> update(void Function(Map<String, dynamic>) action) {
    final next = _tail.then((_) async {
      await load();
      if (_loadError != null) {
        throw StateError(
          'Saved experience data is unavailable; reconnect storage and retry.',
        );
      }
      final candidate = jsonDecode(jsonEncode(_data)) as Map<String, dynamic>;
      action(candidate);
      await _write(candidate);
      _data = candidate;
    });
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }
}

final playbackExperience = PlaybackExperience();
