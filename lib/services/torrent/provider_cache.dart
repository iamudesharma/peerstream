import 'dart:async';
import 'dart:collection';

/// Bounded, expiring, deduplicating in-memory cache.
///
/// Used for manifests, metadata, and source searches. Concurrent callers
/// asking for the same key share one in-flight future (request
/// deduplication); completed entries expire after [ttl] and the map is
/// bounded to [maxEntries] with LRU eviction.
class ExpiringCache<K, V> {
  ExpiringCache({this.maxEntries = 64, this.ttl = const Duration(minutes: 5)});

  final int maxEntries;
  final Duration ttl;
  final LinkedHashMap<K, _Entry<V>> _entries = LinkedHashMap();
  final Map<K, Future<V>> _inflight = {};

  Future<V> get(K key, Future<V> Function() loader) {
    final now = DateTime.now();
    final existing = _entries[key];
    if (existing != null) {
      if (now.difference(existing.storedAt) < ttl) {
        // Refresh LRU order.
        _entries.remove(key);
        _entries[key] = existing;
        return Future.value(existing.value);
      }
      _entries.remove(key);
    }
    final running = _inflight[key];
    if (running != null) return running;
    final future = loader();
    _inflight[key] = future;
    future.then((value) {
      _inflight.remove(key);
      _entries[key] = _Entry(value, DateTime.now());
      while (_entries.length > maxEntries) {
        _entries.remove(_entries.keys.first);
      }
    }, onError: (_) {
      _inflight.remove(key);
    });
    return future;
  }

  void invalidate(K key) {
    _entries.remove(key);
    // In-flight futures are left to complete; callers holding them check
    // generation/cancellation separately.
  }

  void clear() {
    _entries.clear();
  }

  int get length => _entries.length;
}

class _Entry<V> {
  _Entry(this.value, this.storedAt);
  final V value;
  final DateTime storedAt;
}

/// Single-flight tracker for torrent additions/prefetches.
///
/// Concurrent `add()` calls for the same cache key share one future so
/// hover-prefetch storms do not open duplicate native handles.
class SingleFlight {
  final Map<String, Future<dynamic>> _running = {};

  Future<T> run<T>(String key, Future<T> Function() work) {
    final existing = _running[key];
    if (existing != null) return existing as Future<T>;
    final future = work();
    _running[key] = future;
    future.then((_) => _running.remove(key), onError: (_) {
      _running.remove(key);
    });
    return future;
  }

  bool get isEmpty => _running.isEmpty;
  int get length => _running.length;
}
