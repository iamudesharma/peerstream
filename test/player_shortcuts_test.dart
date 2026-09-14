import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peerstream/features/player/player_shortcuts.dart';

const _digitKeys = <LogicalKeyboardKey>[
  LogicalKeyboardKey.digit0,
  LogicalKeyboardKey.digit1,
  LogicalKeyboardKey.digit2,
  LogicalKeyboardKey.digit3,
  LogicalKeyboardKey.digit4,
  LogicalKeyboardKey.digit5,
  LogicalKeyboardKey.digit6,
  LogicalKeyboardKey.digit7,
  LogicalKeyboardKey.digit8,
  LogicalKeyboardKey.digit9,
];

void main() {
  bool matches(
    SingleActivator activator,
    LogicalKeyboardKey key, {
    bool shift = false,
  }) =>
      activator.trigger == key &&
      activator.shift == shift &&
      !activator.control &&
      !activator.alt &&
      !activator.meta;

  PlayerShortcut shortcutFor(LogicalKeyboardKey key, {bool shift = false}) =>
      playerShortcuts.firstWhere(
        (shortcut) => matches(shortcut.activator, key, shift: shift),
      );

  group('playerShortcuts bindings', () {
    test('space and K toggle play/pause', () {
      expect(
        shortcutFor(LogicalKeyboardKey.space).action,
        PlayerShortcutAction.playPause,
      );
      expect(
        shortcutFor(LogicalKeyboardKey.keyK).action,
        PlayerShortcutAction.playPause,
      );
    });

    test('arrows seek 5 seconds and J/L seek 10 seconds', () {
      expect(
        shortcutFor(LogicalKeyboardKey.arrowLeft).action,
        PlayerShortcutAction.seekBackward5,
      );
      expect(
        shortcutFor(LogicalKeyboardKey.arrowRight).action,
        PlayerShortcutAction.seekForward5,
      );
      expect(
        shortcutFor(LogicalKeyboardKey.keyJ).action,
        PlayerShortcutAction.seekBackward10,
      );
      expect(
        shortcutFor(LogicalKeyboardKey.keyL).action,
        PlayerShortcutAction.seekForward10,
      );
    });

    test('volume, mute, fullscreen, captions and help are bound', () {
      expect(
        shortcutFor(LogicalKeyboardKey.arrowUp).action,
        PlayerShortcutAction.volumeUp,
      );
      expect(
        shortcutFor(LogicalKeyboardKey.arrowDown).action,
        PlayerShortcutAction.volumeDown,
      );
      expect(
        shortcutFor(LogicalKeyboardKey.keyM).action,
        PlayerShortcutAction.toggleMute,
      );
      expect(
        shortcutFor(LogicalKeyboardKey.keyF).action,
        PlayerShortcutAction.toggleFullscreen,
      );
      expect(
        shortcutFor(LogicalKeyboardKey.escape).action,
        PlayerShortcutAction.exitFullscreen,
      );
      expect(
        shortcutFor(LogicalKeyboardKey.keyC).action,
        PlayerShortcutAction.toggleSubtitles,
      );
      expect(
        shortcutFor(LogicalKeyboardKey.slash, shift: true).action,
        PlayerShortcutAction.showHelp,
      );
    });

    test('speed uses shifted comma/period and frames use unshifted', () {
      expect(
        shortcutFor(LogicalKeyboardKey.comma, shift: true).action,
        PlayerShortcutAction.speedDown,
      );
      expect(
        shortcutFor(LogicalKeyboardKey.period, shift: true).action,
        PlayerShortcutAction.speedUp,
      );
      expect(
        shortcutFor(LogicalKeyboardKey.comma).action,
        PlayerShortcutAction.frameStepBack,
      );
      expect(
        shortcutFor(LogicalKeyboardKey.period).action,
        PlayerShortcutAction.frameStepForward,
      );
    });

    test('digits 0-9 seek to percentages', () {
      for (var digit = 0; digit <= 9; digit++) {
        final shortcut = playerShortcuts.singleWhere(
          (item) =>
              item.action == PlayerShortcutAction.seekToPercent &&
              item.value == digit,
        );
        expect(matches(shortcut.activator, _digitKeys[digit]), isTrue);
      }
    });

    test('every binding is unique', () {
      final seen = <String>{};
      for (final shortcut in playerShortcuts) {
        final activator = shortcut.activator;
        final key =
            '${activator.trigger.keyId}:${activator.control}:'
            '${activator.shift}:${activator.alt}:${activator.meta}';
        expect(
          seen.add(key),
          isTrue,
          reason: '${activator.trigger} is bound twice',
        );
      }
    });

    test('help entries carry both labels', () {
      final helpEntries = playerShortcuts
          .where((shortcut) => shortcut.helpKeys != null)
          .toList(growable: false);
      expect(helpEntries, isNotEmpty);
      for (final shortcut in helpEntries) {
        expect(shortcut.helpDescription, isNotNull);
      }
    });
  });

  group('pure helpers', () {
    test('playerSeekTarget clamps at both ends', () {
      const duration = Duration(minutes: 10);
      expect(
        playerSeekTarget(
          const Duration(seconds: 2),
          const Duration(seconds: -5),
          duration,
        ),
        Duration.zero,
      );
      expect(
        playerSeekTarget(
          const Duration(seconds: 2),
          const Duration(seconds: 5),
          duration,
        ),
        const Duration(seconds: 7),
      );
      expect(
        playerSeekTarget(
          const Duration(seconds: 599),
          const Duration(seconds: 5),
          duration,
        ),
        duration,
      );
      expect(
        playerSeekTarget(
          const Duration(seconds: 5),
          const Duration(seconds: 5),
          Duration.zero,
        ),
        const Duration(seconds: 10),
      );
    });

    test('steppedPlaybackRate walks the presets and clamps', () {
      expect(steppedPlaybackRate(1, 1), 1.25);
      expect(steppedPlaybackRate(1, -1), 0.75);
      expect(steppedPlaybackRate(2, 1), 2);
      expect(steppedPlaybackRate(0.25, -1), 0.25);
      expect(steppedPlaybackRate(1.26, 1), 1.5);
    });

    test('nudgedVolume clamps to 0-100', () {
      expect(nudgedVolume(95, 5), 100);
      expect(nudgedVolume(5, -5), 0);
      expect(nudgedVolume(50, 5), 55);
    });

    test('formatPlaybackRate trims trailing zeros', () {
      expect(formatPlaybackRate(1), 'Normal');
      expect(formatPlaybackRate(0.5), '0.5×');
      expect(formatPlaybackRate(1.25), '1.25×');
      expect(formatPlaybackRate(2), '2×');
    });

    test('resumeSeekLanded uses an asymmetric window', () {
      const target = Duration(minutes: 10);
      expect(resumeSeekLanded(target, target), isTrue);
      expect(
        resumeSeekLanded(const Duration(minutes: 9, seconds: 58), target),
        isTrue,
      );
      expect(
        resumeSeekLanded(const Duration(minutes: 9, seconds: 55), target),
        isFalse,
      );
      expect(
        resumeSeekLanded(const Duration(minutes: 10, seconds: 29), target),
        isTrue,
      );
      expect(
        resumeSeekLanded(const Duration(minutes: 10, seconds: 31), target),
        isFalse,
      );
      expect(resumeSeekLanded(Duration.zero, target), isFalse);
    });

    test('nextEpisodeNumber picks the nearest later episode', () {
      expect(nextEpisodeNumber([1, 2, 3], 1), 2);
      expect(nextEpisodeNumber([3, 1, 2], 2), 3);
      expect(nextEpisodeNumber([1, 2], 2), isNull);
      expect(nextEpisodeNumber(const [], 1), isNull);
    });

    test('nextSeasonNumber skips specials and earlier seasons', () {
      expect(nextSeasonNumber([0, 1, 2, 3], 1), 2);
      expect(nextSeasonNumber([1, 2], 2), isNull);
      expect(nextSeasonNumber([0, -1, 1], 0), 1);
    });
  });
}
