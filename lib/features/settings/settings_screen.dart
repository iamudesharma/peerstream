import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/design_tokens.dart';
import '../../core/widgets/app_scaffold.dart';
import '../../core/widgets/settings_widgets.dart';
import '../../providers/app_providers.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final addonUrls = ref.watch(addonUrlsProvider);
    final addonCount = addonUrls.value?.length ?? 0;

    return AppScaffold(
      selectedIndex: 2,
      title: 'Settings',
      body: ListView(
        padding: const EdgeInsets.all(DesignTokens.pageGutter),
        children: [
          Text(
            'Settings',
            style: Theme.of(context)
                .textTheme
                .headlineSmall
                ?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 4),
          Text(
            'Configure PeerStream to your preferences.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: DesignTokens.textSecondary,
                ),
          ),
          const SizedBox(height: 16),
          SettingsSection(
            title: 'Addons',
            subtitle: 'Manage torrent source addons',
            children: [
              SettingsAction(
                title: 'Manage addons',
                subtitle: '$addonCount addon${addonCount == 1 ? '' : 's'} configured',
                icon: Icons.extension_outlined,
                onTap: () => context.push('/settings/addons'),
              ),
            ],
          ),
          SettingsSection(
            title: 'Playback & Storage',
            subtitle: 'Cache and playback preferences',
            children: [
              SettingsAction(
                title: 'Playback & storage',
                subtitle: 'Cache limit, saved video, language preferences',
                icon: Icons.play_circle_outline,
                onTap: () => context.push('/settings/playback'),
              ),
            ],
          ),
          SettingsSection(
            title: 'Subtitles',
            subtitle: 'Subtitle display preferences',
            children: [
              SettingsAction(
                title: 'Subtitle settings',
                subtitle: 'Auto-load, preferred language',
                icon: Icons.subtitles_outlined,
                onTap: () => context.push('/settings/subtitles'),
              ),
            ],
          ),
          SettingsSection(
            title: 'About',
            subtitle: 'App information and diagnostics',
            children: [
              SettingsAction(
                title: 'About PeerStream',
                subtitle: 'Version, engine, configuration status',
                icon: Icons.info_outline,
                onTap: () => context.push('/settings/about'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
