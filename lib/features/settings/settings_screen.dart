import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/design_tokens.dart';
import '../../core/widgets/app_scaffold.dart';
import '../../core/widgets/settings_widgets.dart';
import '../../providers/app_providers.dart';
import 'http_server_section.dart';

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
            style: Theme.of(context).textTheme.headlineLarge
                ?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 4),
          Text(
            'Make yourself at home. Set up your perfect watch.',
            style: Theme.of(context).textTheme.bodyMedium
                ?.copyWith(color: DesignTokens.textSecondary),
          ),
          const SizedBox(height: 16),

          SettingsSection(
            title: 'Addons',
            subtitle: 'Manage torrent source addons',
            children: [
              SettingsAction(
                title: 'Manage addons',
                subtitle:
                    '$addonCount addon${addonCount == 1 ? '' : 's'} configured',
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
                title: 'Downloads',
                subtitle: 'Download videos, play saved files, or save a copy',
                icon: Icons.download_outlined,
                onTap: () => context.push('/downloads'),
              ),
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
          const SizedBox(height: 8),
          SettingsSection(
            title: 'Library',
            children: [
              SettingsAction(
                title: 'Organize saved titles',
                subtitle: 'Collections and watched filters',
                icon: Icons.video_library_outlined,
                onTap: () => context.push('/library'),
              ),
            ],
          ),
          SettingsSection(
            title: 'Play queue',
            children: [
              SettingsAction(
                title: 'Manage queue',
                subtitle: 'Reorder upcoming videos',
                icon: Icons.queue_play_next,
                onTap: () => context.push('/queue'),
              ),
            ],
          ),
          const HttpServerSection(),
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
