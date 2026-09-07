import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/design_tokens.dart';
import '../../core/widgets/settings_widgets.dart';
import '../../providers/settings_providers.dart';
import '../../services/settings/settings_store.dart';

class SubtitlesScreen extends ConsumerWidget {
  const SubtitlesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(appSettingsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Subtitles')),
      body: ListView(
        padding: const EdgeInsets.all(DesignTokens.pageGutter),
        children: [
          Text(
            'Subtitles',
            style: Theme.of(context)
                .textTheme
                .headlineSmall
                ?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 4),
          Text(
            'Configure how subtitles are loaded and displayed.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: DesignTokens.textSecondary,
                ),
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
                        ref
                            .read(appSettingsProvider.notifier)
                            .setAutoLoadSubtitles(value);
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
                        ref
                            .read(appSettingsProvider.notifier)
                            .setSubtitleLanguage(
                              value == 'None' ? null : value,
                            );
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
