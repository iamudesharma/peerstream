import 'package:flutter/material.dart';

import 'player_shortcuts.dart';
import 'player_control_menu.dart';

/// Anchored inside the video so all settings remain available in fullscreen.
class PlayerSettingsMenu extends StatelessWidget {
  const PlayerSettingsMenu({
    this.additionalControls = const [],
    required this.rate,
    required this.onRateSelected,
    required this.fit,
    required this.aspectRatio,
    required this.onToggleMute,
    required this.onFitSelected,
    required this.onAspectRatioSelected,
    required this.onShowShortcuts,
    required this.onToggleStats,
    required this.statsEnabled,
    super.key,
  });

  final List<Widget> additionalControls;
  final double rate;
  final ValueChanged<double> onRateSelected;
  final BoxFit fit;
  final double? aspectRatio;
  final VoidCallback onToggleMute;
  final ValueChanged<BoxFit> onFitSelected;
  final ValueChanged<double?> onAspectRatioSelected;
  final VoidCallback onShowShortcuts;
  final VoidCallback onToggleStats;
  final bool statsEnabled;

  @override
  Widget build(BuildContext context) => PlayerControlMenu(
    tooltip: 'Player settings',
    icon: const Icon(Icons.settings_outlined, color: Colors.white),
    menuBuilder: (context, close) =>
        _SettingsPanel(settings: this, close: close),
  );
}

class _SettingsPanel extends StatefulWidget {
  const _SettingsPanel({required this.settings, required this.close});
  final PlayerSettingsMenu settings;
  final VoidCallback close;

  @override
  State<_SettingsPanel> createState() => _SettingsPanelState();
}

class _SettingsPanelState extends State<_SettingsPanel> {
  String? _section;

  void _apply(VoidCallback action) {
    action();
    widget.close();
  }

  Widget _choice(String label, bool selected, VoidCallback onPressed) =>
      ListTile(
        title: Text(label),
        trailing: selected ? const Icon(Icons.check_rounded) : null,
        onTap: () => _apply(onPressed),
      );

  Widget _sectionTile(String title, IconData icon, {String? subtitle}) =>
      ListTile(
        leading: Icon(icon),
        title: Text(title),
        subtitle: subtitle == null ? null : Text(subtitle),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: () => setState(() => _section = title),
      );

  @override
  Widget build(BuildContext context) {
    final settings = widget.settings;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ListTile(
          leading: _section == null
              ? null
              : IconButton(
                  tooltip: 'Back to player settings',
                  icon: const Icon(Icons.arrow_back_rounded),
                  onPressed: () => setState(() => _section = null),
                ),
          title: Text(
            _section ?? 'Player settings',
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          trailing: IconButton(
            tooltip: 'Close settings',
            icon: const Icon(Icons.close_rounded),
            onPressed: widget.close,
          ),
        ),
        const Divider(),
        ...[
          if (_section == null) ...[
            _sectionTile(
              'Playback speed',
              Icons.speed_rounded,
              subtitle: formatPlaybackRate(settings.rate),
            ),
            ...settings.additionalControls,
            _sectionTile('Video fit', Icons.fit_screen_rounded),
            _sectionTile('Aspect ratio', Icons.aspect_ratio_rounded),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.volume_up_outlined),
              title: const Text('Mute / unmute'),
              onTap: () => _apply(settings.onToggleMute),
            ),
            ListTile(
              leading: const Icon(Icons.keyboard_outlined),
              title: const Text('Keyboard shortcuts'),
              onTap: () {
                widget.close();
                settings.onShowShortcuts();
              },
            ),
            ListTile(
              leading: Icon(
                settings.statsEnabled
                    ? Icons.check_rounded
                    : Icons.monitor_heart_outlined,
              ),
              title: const Text('Playback statistics'),
              onTap: () => _apply(settings.onToggleStats),
            ),
          ] else if (_section == 'Playback speed') ...[
            for (final value in playerPlaybackRates)
              _choice(
                formatPlaybackRate(value),
                value == settings.rate,
                () => settings.onRateSelected(value),
              ),
          ] else if (_section == 'Video fit') ...[
            for (final option in [
              (BoxFit.contain, 'Fit video'),
              (BoxFit.cover, 'Fill screen'),
              (BoxFit.fill, 'Stretch video'),
            ])
              _choice(
                option.$2,
                settings.fit == option.$1,
                () => settings.onFitSelected(option.$1),
              ),
          ] else if (_section == 'Aspect ratio') ...[
            for (final option in [
              ('Original ratio', null),
              ('4:3', 4 / 3),
              ('16:9', 16 / 9),
              ('21:9', 21 / 9),
            ])
              _choice(
                option.$1,
                settings.aspectRatio == option.$2,
                () => settings.onAspectRatioSelected(option.$2),
              ),
          ],
        ],
      ],
    );
  }
}
