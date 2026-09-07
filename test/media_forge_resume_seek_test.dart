import 'package:flutter_test/flutter_test.dart';
import 'package:peerstream/features/player/player_backend.dart';
import 'package:peerstream/models/media_item.dart';
import 'package:peerstream/models/torrent_models.dart';
import 'package:peerstream/models/watch_progress.dart';

void main() {
  group('MediaForgeSeekCoordinator.onSeekFailed', () {
    test('voids the latest started seek', () {
      final coordinator = MediaForgeSeekCoordinator();
      coordinator.onSeekStarted(3);
      expect(coordinator.hasPendingSeek, isTrue);
      coordinator.onSeekFailed(3);
      expect(coordinator.hasPendingSeek, isFalse);
      expect(coordinator.latestSettled, 3);
    });

    test('ignores failures for superseded generations', () {
      final coordinator = MediaForgeSeekCoordinator();
      coordinator.onSeekStarted(3);
      coordinator.onSeekStarted(4);
      coordinator.onSeekFailed(3);
      expect(coordinator.hasPendingSeek, isTrue);
      expect(coordinator.latestStarted, 4);
    });

    test('late settle for a voided generation is rejected', () {
      final coordinator = MediaForgeSeekCoordinator();
      coordinator.onSeekStarted(3);
      coordinator.onSeekFailed(3);
      expect(coordinator.shouldApplySettled(3), isFalse);
    });

    test('voided state still accepts a newer seek', () {
      final coordinator = MediaForgeSeekCoordinator();
      coordinator.onSeekStarted(3);
      coordinator.onSeekFailed(3);
      coordinator.onSeekStarted(4);
      expect(coordinator.hasPendingSeek, isTrue);
      expect(coordinator.shouldApplySettled(4), isTrue);
    });
  });

  group('mediaForgeResumeSeekDelay', () {
    test('backs off linearly and caps', () {
      expect(
        mediaForgeResumeSeekDelay(1),
        const Duration(milliseconds: 500),
      );
      expect(
        mediaForgeResumeSeekDelay(2),
        const Duration(milliseconds: 1000),
      );
      expect(
        mediaForgeResumeSeekDelay(4),
        const Duration(milliseconds: 2000),
      );
      expect(
        mediaForgeResumeSeekDelay(20),
        const Duration(milliseconds: 2000),
      );
    });
  });

  group('mediaForgeResumeSeekLanded', () {
    test('matches the default player settle window', () {
      const target = Duration(minutes: 5);
      expect(
        mediaForgeResumeSeekLanded(
          position: const Duration(minutes: 5),
          target: target,
        ),
        isTrue,
      );
      // 2s behind: within tolerance.
      expect(
        mediaForgeResumeSeekLanded(
          position: const Duration(minutes: 4, seconds: 58),
          target: target,
        ),
        isTrue,
      );
      // 10s behind: not landed.
      expect(
        mediaForgeResumeSeekLanded(
          position: const Duration(minutes: 4, seconds: 50),
          target: target,
        ),
        isFalse,
      );
      // Ahead within the generous window.
      expect(
        mediaForgeResumeSeekLanded(
          position: const Duration(minutes: 5, seconds: 20),
          target: target,
        ),
        isTrue,
      );
      // Far ahead: overshoot, not landed.
      expect(
        mediaForgeResumeSeekLanded(
          position: const Duration(minutes: 6),
          target: target,
        ),
        isFalse,
      );
    });
  });

  group('resumeMsForSource', () {
    TorrentSource source() => TorrentSource(
      id: 's1',
      content: const MediaRef(id: 7, type: MediaType.movie),
      name: 's1',
      uri: Uri.parse('magnet:?xt=urn:btih:${'b' * 40}'),
      inputType: TorrentInputType.magnet,
      providerName: 'p',
      attribution: 'a',
      license: 'l',
      provenanceUrl: Uri.parse('about:blank'),
    );

    WatchEntry entry(int positionMs) => WatchEntry(
      key: 'movie/7',
      media: const MediaRef(id: 7, type: MediaType.movie),
      title: 't',
      sourceId: 's1',
      providerName: 'p',
      sourceUri: 'magnet:?xt=urn:btih:${'b' * 40}',
      inputType: 'magnet',
      positionMs: positionMs,
      durationMs: 600000,
      updatedAt: DateTime(2026, 1, 1),
    );

    test('returns the saved position for the source media', () {
      expect(
        resumeMsForSource(source: source(), history: [entry(300000)]),
        300000,
      );
    });

    test('null without history or without a matching entry', () {
      expect(resumeMsForSource(source: source(), history: null), isNull);
      expect(resumeMsForSource(source: source(), history: const []), isNull);
      expect(
        resumeMsForSource(
          source: source(),
          history: [
            entry(300000).copyWithKey('movie/8'),
          ],
        ),
        isNull,
      );
    });

    test('null for zero positions', () {
      expect(
        resumeMsForSource(source: source(), history: [entry(0)]),
        isNull,
      );
    });
  });

  group('MediaForgeResumeSeekDriver', () {
    test('returns immediately when already landed', () async {
      final backend = _FakeSeekBackend()
        ..position = const Duration(minutes: 5);
      final driver = MediaForgeResumeSeekDriver(
        delayFn: (_) async {},
      );
      final ok = await driver.drive(
        reason: 'test',
        target: const Duration(minutes: 5),
        seek: backend.seek,
        currentGeneration: () => backend.generation,
        latestStarted: () => backend.coordinator.latestStarted,
        latestSettled: () => backend.coordinator.latestSettled,
        position: () => backend.position,
        isCurrent: () => backend.current,
        onAttemptFailed: backend.onAttemptFailed,
      );
      expect(ok, isTrue);
      expect(backend.seekCalls, 0);
    });

    test('succeeds on first attempt when settle arrives', () async {
      final backend = _FakeSeekBackend();
      final driver = MediaForgeResumeSeekDriver(
        settleTimeout: const Duration(seconds: 5),
        pollInterval: const Duration(milliseconds: 1),
        delayFn: (_) async {},
      );
      final ok = await driver.drive(
        reason: 'test',
        target: const Duration(minutes: 5),
        seek: backend.seek,
        currentGeneration: () => backend.generation,
        latestStarted: () => backend.coordinator.latestStarted,
        latestSettled: () => backend.coordinator.latestSettled,
        position: () => backend.position,
        isCurrent: () => backend.current,
        onAttemptFailed: backend.onAttemptFailed,
      );
      expect(ok, isTrue);
      expect(backend.seekCalls, 1);
      expect(backend.failed, isEmpty);
      expect(backend.coordinator.hasPendingSeek, isFalse);
    });

    test('retries failures then succeeds', () async {
      final backend = _FakeSeekBackend()..failRemaining = 2;
      final driver = MediaForgeResumeSeekDriver(
        settleTimeout: const Duration(seconds: 5),
        pollInterval: const Duration(milliseconds: 1),
        delayFn: (_) async {},
      );
      final ok = await driver.drive(
        reason: 'test',
        target: const Duration(minutes: 5),
        seek: backend.seek,
        currentGeneration: () => backend.generation,
        latestStarted: () => backend.coordinator.latestStarted,
        latestSettled: () => backend.coordinator.latestSettled,
        position: () => backend.position,
        isCurrent: () => backend.current,
        onAttemptFailed: backend.onAttemptFailed,
      );
      expect(ok, isTrue);
      expect(backend.seekCalls, 3);
      // Both failed generations were voided: seeking never latches.
      expect(backend.failed, [1, 2]);
      expect(backend.coordinator.hasPendingSeek, isFalse);
    });

    test('gives up after the budget is exhausted', () async {
      final backend = _FakeSeekBackend()..failRemaining = 100;
      final driver = MediaForgeResumeSeekDriver(
        maxAttempts: 3,
        settleTimeout: const Duration(milliseconds: 10),
        pollInterval: const Duration(milliseconds: 1),
        delayFn: (_) async {},
      );
      final ok = await driver.drive(
        reason: 'test',
        target: const Duration(minutes: 5),
        seek: backend.seek,
        currentGeneration: () => backend.generation,
        latestStarted: () => backend.coordinator.latestStarted,
        latestSettled: () => backend.coordinator.latestSettled,
        position: () => backend.position,
        isCurrent: () => backend.current,
        onAttemptFailed: backend.onAttemptFailed,
      );
      expect(ok, isFalse);
      expect(backend.seekCalls, 3);
      // Every failed attempt voided: no stuck seeking state.
      expect(backend.coordinator.hasPendingSeek, isFalse);
    });

    test('stops when a newer seek supersedes the run', () async {
      final backend = _FakeSeekBackend()..neverSettle = true;
      var polls = 0;
      final driver = MediaForgeResumeSeekDriver(
        settleTimeout: const Duration(seconds: 5),
        pollInterval: const Duration(milliseconds: 1),
        delayFn: (_) async {
          if (++polls == 3) backend.userSeek();
        },
      );
      final ok = await driver.drive(
        reason: 'test',
        target: const Duration(minutes: 5),
        seek: backend.seek,
        currentGeneration: () => backend.generation,
        latestStarted: () => backend.coordinator.latestStarted,
        latestSettled: () => backend.coordinator.latestSettled,
        position: () => backend.position,
        isCurrent: () => backend.current,
        onAttemptFailed: backend.onAttemptFailed,
      );
      // Handoff, not success: no more attempts at the stale target.
      expect(ok, isTrue);
      expect(backend.seekCalls, 1);
    });

    test('cancel aborts the run', () async {
      final backend = _FakeSeekBackend()..neverSettle = true;
      late final MediaForgeResumeSeekDriver driver;
      driver = MediaForgeResumeSeekDriver(
        settleTimeout: const Duration(seconds: 5),
        pollInterval: const Duration(milliseconds: 1),
        delayFn: (_) async => driver.cancel(),
      );
      final ok = await driver.drive(
        reason: 'test',
        target: const Duration(minutes: 5),
        seek: backend.seek,
        currentGeneration: () => backend.generation,
        latestStarted: () => backend.coordinator.latestStarted,
        latestSettled: () => backend.coordinator.latestSettled,
        position: () => backend.position,
        isCurrent: () => backend.current,
        onAttemptFailed: backend.onAttemptFailed,
      );
      // Handoff, not failure: stop quietly without further attempts.
      expect(ok, isTrue);
      expect(backend.seekCalls, 1);
    });

    test('position reaching target counts without a settle event', () async {
      final backend = _FakeSeekBackend()..neverSettle = true;
      var polls = 0;
      final driver = MediaForgeResumeSeekDriver(
        settleTimeout: const Duration(seconds: 5),
        pollInterval: const Duration(milliseconds: 1),
        delayFn: (_) async {
          if (++polls == 2) {
            backend.position = const Duration(minutes: 5);
          }
        },
      );
      final ok = await driver.drive(
        reason: 'test',
        target: const Duration(minutes: 5),
        seek: backend.seek,
        currentGeneration: () => backend.generation,
        latestStarted: () => backend.coordinator.latestStarted,
        latestSettled: () => backend.coordinator.latestSettled,
        position: () => backend.position,
        isCurrent: () => backend.current,
        onAttemptFailed: backend.onAttemptFailed,
      );
      expect(ok, isTrue);
      expect(backend.seekCalls, 1);
    });
  });
}

/// Mirrors the screen's event wiring: attempts bump the generation and
/// report started through a real coordinator; settle is delivered
/// asynchronously like a real `seekSettled` event.
class _FakeSeekBackend {
  final coordinator = MediaForgeSeekCoordinator();
  int generation = 0;
  Duration position = Duration.zero;
  bool current = true;
  int seekCalls = 0;
  int failRemaining = 0;
  bool neverSettle = false;
  final List<int> failed = [];

  Future<void> seek(Duration target) async {
    seekCalls++;
    if (failRemaining > 0) {
      failRemaining--;
      generation++;
      coordinator.onSeekStarted(generation);
      throw StateError('seek failed');
    }
    generation++;
    final g = generation;
    coordinator.onSeekStarted(g);
    if (!neverSettle) {
      // Microtask delivery, like a real broadcast `seekSettled` event.
      Future.microtask(() {
        coordinator.onSeekSettled(g);
      });
    }
  }

  void onAttemptFailed(int generation) {
    failed.add(generation);
    coordinator.onSeekFailed(generation);
  }

  void userSeek() {
    generation++;
    coordinator.onSeekStarted(generation);
  }
}

extension on WatchEntry {
  WatchEntry copyWithKey(String key) => WatchEntry(
    key: key,
    media: media,
    title: title,
    posterPath: posterPath,
    backdropPath: backdropPath,
    season: season,
    episode: episode,
    sourceId: sourceId,
    providerName: providerName,
    sourceUri: sourceUri,
    inputType: inputType,
    positionMs: positionMs,
    durationMs: durationMs,
    updatedAt: updatedAt,
  );
}
