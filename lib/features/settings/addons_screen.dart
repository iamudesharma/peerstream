import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/design_tokens.dart';
import '../../core/widgets/app_empty.dart';
import '../../core/widgets/settings_widgets.dart';
import '../../providers/app_providers.dart';
import '../../services/torrent/addon_provider.dart';

class AddonsScreen extends ConsumerWidget {
  const AddonsScreen({super.key});

  Future<void> _addAddon(BuildContext context, WidgetRef ref) async {
    final controller = TextEditingController();
    String? errorText;

    final result = await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Add addon'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Enter the manifest URL of a Stremio-compatible addon.',
              ),
              const SizedBox(height: 16),
              TextField(
                controller: controller,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: 'Addon URL',
                  hintText: 'https://example.com/manifest.json',
                  prefixIcon: const Icon(Icons.link),
                  errorText: errorText,
                ),
                onChanged: (_) {
                  if (errorText != null) {
                    setState(() => errorText = null);
                  }
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final url = controller.text.trim();
                try {
                  AddonTorrentProvider.validateUrl(url);
                  Navigator.pop(context, url);
                } on FormatException {
                  setState(
                    () => errorText =
                        'Use an HTTP(S) URL ending in /manifest.json.',
                  );
                }
              },
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );

    if (result != null) {
      final notifier = ref.read(addonUrlsProvider.notifier);
      final current = ref.read(addonUrlsProvider).value ?? [];
      if (!current.contains(result)) {
        await notifier.save([...current, result]);
      }
    }
  }

  Future<void> _removeAddon(
    BuildContext context,
    WidgetRef ref,
    String url,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove addon?'),
        content: Text(
          'This will stop using:\n$url\n\nYou can add it again later.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      final notifier = ref.read(addonUrlsProvider.notifier);
      final current = ref.read(addonUrlsProvider).value ?? [];
      await notifier.save(current.where((u) => u != url).toList());
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final addonUrls = ref.watch(addonUrlsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Addons'),
        actions: [
          IconButton(
            tooltip: 'Add addon',
            icon: const Icon(Icons.add),
            onPressed: () => _addAddon(context, ref),
          ),
        ],
      ),
      body: addonUrls.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, _) => const AppEmpty(
          icon: Icons.error_outline,
          title: 'Could not load addons',
          hint: 'Try reopening this screen.',
        ),
        data: (urls) {
          if (urls.isEmpty) {
            return AppEmpty(
              icon: Icons.extension_off_outlined,
              title: 'No addons configured',
              hint: 'Add a Stremio-compatible torrent addon to get started.',
              action: FilledButton.icon(
                onPressed: () => _addAddon(context, ref),
                icon: const Icon(Icons.add),
                label: const Text('Add addon'),
              ),
            );
          }
          return ListView(
            padding: const EdgeInsets.all(DesignTokens.pageGutter),
            children: [
              Text(
                'Addons',
                style: Theme.of(context)
                    .textTheme
                    .headlineSmall
                    ?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 4),
              Text(
                'Torrent source addons provide video streams. '
                'Add or remove Stremio-compatible addons.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: DesignTokens.textSecondary,
                    ),
              ),
              const SizedBox(height: 16),
              SettingsSection(
                title: 'Configured addons',
                children: [
                  for (final url in urls)
                    SettingsTile(
                      title: _displayName(url),
                      subtitle: url,
                      icon: Icons.extension_outlined,
                      trailing: IconButton(
                        tooltip: 'Remove addon',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => _removeAddon(context, ref, url),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              Center(
                child: TextButton.icon(
                  onPressed: () => _addAddon(context, ref),
                  icon: const Icon(Icons.add),
                  label: const Text('Add addon'),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  String _displayName(String url) {
    try {
      final uri = Uri.parse(url);
      return uri.host;
    } catch (_) {
      return url;
    }
  }
}
