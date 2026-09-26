import 'package:peerstream/providers/app_store.dart';
import 'package:dartnative/dartnative.dart';
import 'package:peerstream/core/icons.dart';

import '../../core/design_tokens.dart';
import '../../core/widgets/settings_widgets.dart';
import '../../services/settings/settings_store.dart';

class SubtitlesScreen extends StatelessWidget {
  const SubtitlesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = (AppStore.instance.settings..watch(context));

    return Scaffold(

      // The screen colour belongs on the Scaffold: with no backgroundColor the

      // route reports the white default and dark screens flash white.

      backgroundColor: DesignTokens.background,
      appBar: AppBar(title: const Text('Subtitles')),
      body: ListView(
        padding: const EdgeInsets.all(DesignTokens.pageGutter),
        children: [
          Text(
            'Subtitles',
            style: Theme.of(context).textTheme.headlineSmall
                ?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 4),
          Text(
            'Configure how subtitles are loaded and displayed.',
            style: Theme.of(context).textTheme.bodyMedium
                ?.copyWith(color: DesignTokens.textSecondary),
          ),
          const SizedBox(height: 16),
          settings.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (_, _) => const SizedBox.shrink(),
            data: (s) => Column(
              children: [
                SettingsSection(
                  title: 'General',
                  children: [
                    SettingsToggle(
                      title: 'Auto-load subtitles',
                      subtitle: 'Automatically fetch subtitles when available',
                      icon: Icons.subtitles_outlined,
                      value: s.autoLoadSubtitles,
                      onChanged: (value) {
                        AppStore.instance.settings.setAutoLoadSubtitles(
                          value,
                        );
                      },
                    ),
                  ],
                ),
                SettingsSection(
                  title: 'Language',
                  subtitle: 'Preferred subtitle language',
                  children: [
                    SettingsSelect<String>(
                      title: 'Preferred language',
                      icon: Icons.language,
                      value: s.preferredSubtitleLanguage ?? 'None',
                      options: [
                        for (final lang in AppSettings.subtitleLanguages)
                          SelectOption(value: lang, label: lang),
                      ],
                      onChanged: (value) {
                        AppStore.instance.settings.setSubtitleLanguage(
                          value == 'None' ? null : value,
                        );
                      },
                    ),
                  ],
                ),
                SettingsSection(
                  title: 'Display',
                  subtitle: 'How subtitles appear in the player',
                  children: [
                    SettingsSelect<double>(
                      title: 'Text size',
                      icon: Icons.format_size,
                      value: s.subtitleTextScale,
                      options: [
                        for (final scale in AppSettings.subtitleTextScales)
                          SelectOption(
                            value: scale,
                            label: AppSettings.subtitleTextScaleLabel(scale),
                          ),
                      ],
                      onChanged: (value) {
                        AppStore.instance.settings.setSubtitleTextScale(value);
                      },
                    ),
                    const Divider(height: 1),
                    SettingsSelect<SubtitleBackgroundStyle>(
                      title: 'Background',
                      icon: Icons.format_color_fill,
                      value: s.subtitleBackground,
                      options: [
                        for (final style in SubtitleBackgroundStyle.values)
                          SelectOption(
                            value: style,
                            label: AppSettings.subtitleBackgroundLabel(style),
                          ),
                      ],
                      onChanged: (value) {
                        AppStore.instance.settings.setSubtitleBackground(value);
                      },
                    ),
                  ],
                ),
                SettingsSection(
                  title: 'About',
                  children: [
                    const SettingsInfo(
                      title: 'Subtitle sources',
                      value: 'Stremio addons',
                      icon: Icons.extension_outlined,
                    ),
                    const Divider(height: 1),
                    SettingsInfo(
                      title: 'Supported addons',
                      value: 'OpenSubtitles, Subscene',
                      icon: Icons.info_outline,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
