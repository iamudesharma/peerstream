import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// YouTube-style player actions triggered by keyboard shortcuts.
enum PlayerShortcutAction {
  playPause,
  seekBackward5,
  seekForward5,
  seekBackward10,
  seekForward10,
  volumeUp,
  volumeDown,
  toggleMute,
  toggleFullscreen,
  exitFullscreen,
  toggleSubtitles,
  speedDown,
  speedUp,
  frameStepBack,
  frameStepForward,
  seekToPercent,
  jumpToStart,
  jumpToEnd,
  showHelp,
}

/// One keyboard binding plus its help-sheet metadata.
class PlayerShortcut {
  const PlayerShortcut({
    required this.activator,
    required this.action,
    this.value,
    this.helpKeys,
    this.helpDescription,
  });

  final SingleActivator activator;
  final PlayerShortcutAction action;

  /// Digit for [PlayerShortcutAction.seekToPercent].
  final int? value;

  /// Label shown in the shortcuts help sheet. Null hides the entry.
  final String? helpKeys;

  /// Description shown in the shortcuts help sheet.
  final String? helpDescription;
}

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

List<PlayerShortcut> _buildShortcuts() {
  final shortcuts = <PlayerShortcut>[
    const PlayerShortcut(
      activator: SingleActivator(LogicalKeyboardKey.space),
      action: PlayerShortcutAction.playPause,
      helpKeys: 'Space',
      helpDescription: 'Play or pause',
    ),
    const PlayerShortcut(
      activator: SingleActivator(LogicalKeyboardKey.keyK),
      action: PlayerShortcutAction.playPause,
      helpKeys: 'K',
      helpDescription: 'Play or pause',
    ),
    const PlayerShortcut(
      activator: SingleActivator(LogicalKeyboardKey.mediaPlayPause),
      action: PlayerShortcutAction.playPause,
    ),
    const PlayerShortcut(
      activator: SingleActivator(LogicalKeyboardKey.arrowLeft),
      action: PlayerShortcutAction.seekBackward5,
      helpKeys: '←',
      helpDescription: 'Back 5 seconds',
    ),
    const PlayerShortcut(
      activator: SingleActivator(LogicalKeyboardKey.arrowRight),
      action: PlayerShortcutAction.seekForward5,
      helpKeys: '→',
      helpDescription: 'Forward 5 seconds',
    ),
    const PlayerShortcut(
      activator: SingleActivator(LogicalKeyboardKey.keyJ),
      action: PlayerShortcutAction.seekBackward10,
      helpKeys: 'J',
      helpDescription: 'Back 10 seconds',
    ),
    const PlayerShortcut(
      activator: SingleActivator(LogicalKeyboardKey.keyL),
      action: PlayerShortcutAction.seekForward10,
      helpKeys: 'L',
      helpDescription: 'Forward 10 seconds',
    ),
    const PlayerShortcut(
      activator: SingleActivator(LogicalKeyboardKey.arrowUp),
      action: PlayerShortcutAction.volumeUp,
      helpKeys: '↑',
      helpDescription: 'Volume up 5%',
    ),
    const PlayerShortcut(
      activator: SingleActivator(LogicalKeyboardKey.arrowDown),
      action: PlayerShortcutAction.volumeDown,
      helpKeys: '↓',
      helpDescription: 'Volume down 5%',
    ),
    const PlayerShortcut(
      activator: SingleActivator(LogicalKeyboardKey.keyM),
      action: PlayerShortcutAction.toggleMute,
      helpKeys: 'M',
      helpDescription: 'Mute or unmute',
    ),
    const PlayerShortcut(
      activator: SingleActivator(LogicalKeyboardKey.keyF),
      action: PlayerShortcutAction.toggleFullscreen,
      helpKeys: 'F',
      helpDescription: 'Fullscreen',
    ),
    const PlayerShortcut(
      activator: SingleActivator(LogicalKeyboardKey.escape),
      action: PlayerShortcutAction.exitFullscreen,
      helpKeys: 'Esc',
      helpDescription: 'Exit fullscreen',
    ),
    const PlayerShortcut(
      activator: SingleActivator(LogicalKeyboardKey.keyC),
      action: PlayerShortcutAction.toggleSubtitles,
      helpKeys: 'C',
      helpDescription: 'Subtitles on or off',
    ),
    const PlayerShortcut(
      activator: SingleActivator(LogicalKeyboardKey.comma, shift: true),
      action: PlayerShortcutAction.speedDown,
      helpKeys: 'Shift + ,',
      helpDescription: 'Slower',
    ),
    const PlayerShortcut(
      activator: SingleActivator(LogicalKeyboardKey.period, shift: true),
      action: PlayerShortcutAction.speedUp,
      helpKeys: 'Shift + .',
      helpDescription: 'Faster',
    ),
    const PlayerShortcut(
      activator: SingleActivator(LogicalKeyboardKey.comma),
      action: PlayerShortcutAction.frameStepBack,
      helpKeys: ',',
      helpDescription: 'Step back one frame (paused)',
    ),
    const PlayerShortcut(
      activator: SingleActivator(LogicalKeyboardKey.period),
      action: PlayerShortcutAction.frameStepForward,
      helpKeys: '.',
      helpDescription: 'Step forward one frame (paused)',
    ),
    const PlayerShortcut(
      activator: SingleActivator(LogicalKeyboardKey.home),
      action: PlayerShortcutAction.jumpToStart,
      helpKeys: 'Home',
      helpDescription: 'Jump to start',
    ),
    const PlayerShortcut(
      activator: SingleActivator(LogicalKeyboardKey.end),
      action: PlayerShortcutAction.jumpToEnd,
      helpKeys: 'End',
      helpDescription: 'Jump to end',
    ),
    const PlayerShortcut(
      activator: SingleActivator(LogicalKeyboardKey.slash, shift: true),
      action: PlayerShortcutAction.showHelp,
      helpKeys: '?',
      helpDescription: 'Show keyboard shortcuts',
    ),
  ];
  for (var digit = 0; digit <= 9; digit++) {
    shortcuts.add(
      PlayerShortcut(
        activator: SingleActivator(_digitKeys[digit]),
        action: PlayerShortcutAction.seekToPercent,
        value: digit,
        helpKeys: digit == 0 ? '0–9' : null,
        helpDescription: digit == 0 ? 'Jump to 0%–90%' : null,
      ),
    );
  }
  return List.unmodifiable(shortcuts);
}

/// YouTube-compatible keyboard bindings for the default player.
final playerShortcuts = _buildShortcuts();

/// Wraps the video controls so shortcuts work embedded and in fullscreen.
///
/// The [onAction] callback receives the shortcut and the controls'
/// [BuildContext]; the context matters for fullscreen toggles because the
/// fullscreen route has its own [FullscreenInheritedWidget] scope.
class PlayerShortcuts extends StatelessWidget {
  const PlayerShortcuts({
    required this.onAction,
    required this.child,
    super.key,
  });

  final void Function(PlayerShortcut shortcut, BuildContext context) onAction;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        for (final shortcut in playerShortcuts)
          shortcut.activator: () => onAction(shortcut, context),
      },
      child: Focus(autofocus: true, child: child),
    );
  }
}

/// YouTube speed presets shared by the menu, keyboard stepping, and tests.
const playerPlaybackRates = <double>[
  0.25,
  0.5,
  0.75,
  1.0,
  1.25,
  1.5,
  1.75,
  2.0,
];

/// Relative seek clamped to the media bounds. Pure for tests.
Duration playerSeekTarget(
  Duration position,
  Duration delta,
  Duration duration,
) {
  final target = position + delta;
  if (target < Duration.zero) return Duration.zero;
  if (duration > Duration.zero && target > duration) return duration;
  return target;
}

/// Next preset in [direction] (+1 faster, -1 slower), clamped at the ends.
/// Pure for tests.
double steppedPlaybackRate(double current, int direction) {
  var nearest = 0;
  for (var i = 1; i < playerPlaybackRates.length; i++) {
    if ((playerPlaybackRates[i] - current).abs() <
        (playerPlaybackRates[nearest] - current).abs()) {
      nearest = i;
    }
  }
  final next = (nearest + direction).clamp(0, playerPlaybackRates.length - 1);
  return playerPlaybackRates[next];
}

/// Volume nudged by [delta] and clamped to 0–100. Pure for tests.
double nudgedVolume(double volume, double delta) =>
    (volume + delta).clamp(0.0, 100.0);

/// Compact speed label: 'Normal', '0.5×', '1.25×'. Pure for tests.
String formatPlaybackRate(double rate) {
  if (rate == 1) return 'Normal';
  var text = rate.toStringAsFixed(2);
  text = text.replaceFirst(RegExp(r'0+$'), '');
  if (text.endsWith('.')) text = text.substring(0, text.length - 1);
  return '$text×';
}

/// Whether [position] counts as having reached [target] for a resume seek.
///
/// Same asymmetric window as the MediaForge player: a small tolerance behind
/// the target, generous ahead of it. Pure for tests.
bool resumeSeekLanded(Duration position, Duration target) =>
    position + const Duration(seconds: 3) >= target &&
    position <= target + const Duration(seconds: 30);

/// Next episode number after [current], or null when this is the last one.
/// Pure for tests.
int? nextEpisodeNumber(Iterable<int> episodeNumbers, int current) {
  int? best;
  for (final number in episodeNumbers) {
    if (number > current && (best == null || number < best)) {
      best = number;
    }
  }
  return best;
}

/// First regular (non-special) season after [currentSeason], or null.
/// Pure for tests.
int? nextSeasonNumber(Iterable<int> seasonNumbers, int currentSeason) {
  int? best;
  for (final number in seasonNumbers) {
    if (number > currentSeason &&
        number > 0 &&
        (best == null || number < best)) {
      best = number;
    }
  }
  return best;
}
