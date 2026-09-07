import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config.dart';
import '../../core/design_tokens.dart';
import '../../core/widgets/settings_widgets.dart';
import '../../providers/settings_providers.dart';

class AboutScreen extends ConsumerWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appInfo = ref.watch(appInfoProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('About')),
      body: ListView(
        padding: const EdgeInsets.all(DesignTokens.pageGutter),
        children: [
          Text(
            'About',
            style: Theme.of(context)
                .textTheme
                .headlineSmall
                ?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 4),
          Text(
            'App information and diagnostics.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: DesignTokens.textSecondary,
                ),
          ),
          const SizedBox(height: 16),
          SettingsSection(
            title: 'Application',
            children: [
              const SettingsInfo(
                title: 'App name',
                value: 'PeerStream',
                icon: Icons.play_circle_fill,
              ),
              const Divider(height: 1),
              SettingsInfo(
                title: 'Version',
                value: '1.0.0',
                icon: Icons.tag,
              ),
              const Divider(height: 1),
              const SettingsInfo(
                title: 'Description',
                value: 'Legal peer-to-peer video streaming',
                icon: Icons.description_outlined,
              ),
            ],
          ),
          SettingsSection(
            title: 'Engine',
            subtitle: 'Native torrent engine status',
            children: [
              appInfo.when(
                loading: () => const Padding(
                  padding: EdgeInsets.all(16),
                  child: Center(child: CircularProgressIndicator()),
                ),
                error: (_, _) => const SettingsInfo(
                  title: 'Engine status',
                  value: 'Unknown',
                  icon: Icons.error_outline,
                ),
                data: (info) => Column(
                  children: [
                    SettingsInfo(
                      title: 'Native build',
                      value: info.nativeBuildIdentity,
                      icon: Icons.memory,
                    ),
                    const Divider(height: 1),
                    SettingsInfo(
                      title: 'Engine status',
                      value: info.engineSupported
                          ? 'Supported'
                          : 'Unsupported',
                      icon: info.engineSupported
                          ? Icons.check_circle_outline
                          : Icons.error_outline,
                    ),
                    if (info.engineUnsupportedReason != null) ...[
                      const Divider(height: 1),
                      SettingsInfo(
                        title: 'Status detail',
                        value: info.engineUnsupportedReason!,
                        icon: Icons.info_outline,
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          SettingsSection(
            title: 'Configuration',
            subtitle: 'External service configuration',
            children: [
              SettingsInfo(
                title: 'TMDB',
                value: AppConfig.hasTmdbToken ? 'Configured' : 'Not configured',
                icon: AppConfig.hasTmdbToken
                    ? Icons.check_circle_outline
                    : Icons.warning_amber_outlined,
              ),
              const Divider(height: 1),
              SettingsInfo(
                title: 'Streaming catalogs',
                value: AppConfig.hasStreamingCatalogs
                    ? 'Configured'
                    : 'Not configured',
                icon: AppConfig.hasStreamingCatalogs
                    ? Icons.check_circle_outline
                    : Icons.warning_amber_outlined,
              ),
            ],
          ),
          SettingsSection(
            title: 'Legal',
            children: [
              const SettingsInfo(
                title: 'Disclaimer',
                value: 'For educational purposes only',
                icon: Icons.gavel_outlined,
              ),
              const Divider(height: 1),
              SettingsTile(
                title: 'Third-party notices',
                icon: Icons.description_outlined,
                onTap: () {
                  showLicensePage(
                    context: context,
                    applicationName: 'PeerStream',
                    applicationVersion: '1.0.0',
                  );
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}
