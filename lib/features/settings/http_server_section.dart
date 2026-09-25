import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/widgets/settings_widgets.dart';
import '../../providers/server_providers.dart';
import '../../services/torrent/torrent_engine.dart';

class HttpServerSection extends ConsumerWidget {
  const HttpServerSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final result = ref.watch(httpServerInfoProvider);
    final info = result.value;
    final checking = result.isLoading;
    final status = info?.status;
    final running = status == HttpServerStatus.running;
    final label = checking
        ? 'Checking…'
        : result.hasError
        ? 'Unable to check'
        : switch (status) {
            HttpServerStatus.running => 'Running',
            HttpServerStatus.notStarted => 'Not started',
            HttpServerStatus.unavailable => 'Not responding',
            _ => 'Unavailable',
          };
    final colors = Theme.of(context).colorScheme;
    final color = running
        ? Colors.green
        : status == HttpServerStatus.unavailable || result.hasError
        ? colors.error
        : colors.onSurfaceVariant;
    final url = info?.url;

    return SettingsSection(
      title: 'Streaming HTTP server',
      subtitle: 'Live preview of the server running on this device',
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.dns_outlined),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Built-in server',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const Text('This device · Local HTTP'),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Refresh server status',
                    onPressed: checking
                        ? null
                        : () => ref.invalidate(httpServerInfoProvider),
                    icon: const Icon(Icons.refresh),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Semantics(
                liveRegion: true,
                child: Row(
                  children: [
                    if (checking)
                      const SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    else
                      Icon(Icons.circle, size: 10, color: color),
                    const SizedBox(width: 8),
                    Text(label, style: TextStyle(color: color)),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Text(
                url == null
                    ? 'Port: assigned automatically when streaming starts'
                    : 'Host: ${url.host}  ·  Port: ${url.port}',
              ),
              if (url != null) ...[
                const SizedBox(height: 12),
                Text(
                  'Stream URL',
                  style: Theme.of(context).textTheme.labelMedium,
                ),
                const SizedBox(height: 4),
                SelectableText(url.toString()),
                const SizedBox(height: 8),
                TextButton.icon(
                  icon: const Icon(Icons.copy_outlined, size: 18),
                  label: const Text('Copy URL'),
                  onPressed: () async {
                    await Clipboard.setData(
                      ClipboardData(text: url.toString()),
                    );
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Stream URL copied')),
                      );
                    }
                  },
                ),
                const Text(
                  'This address works only on this device and may '
                  'change with the next stream.',
                ),
              ],
              if (info?.message != null || result.hasError) ...[
                const SizedBox(height: 8),
                Text(
                  result.hasError
                      ? 'Could not read server status. Try refreshing.'
                      : info!.message!,
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
