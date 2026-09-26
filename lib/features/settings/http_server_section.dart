import 'package:dartnative/flutter_compat.dart' hide Badge;
import 'package:peerstream/core/gap_widgets.dart';
import 'package:dartnative/dartnative.dart';
import 'package:peerstream/core/icons.dart';

import '../../core/widgets/settings_widgets.dart';
import '../../providers/app_store.dart';
import '../../services/torrent/torrent_engine.dart';

class HttpServerSection extends StatefulWidget {
  const HttpServerSection({super.key});

  @override
  State<HttpServerSection> createState() => _HttpServerSectionState();
}

class _HttpServerSectionState extends State<HttpServerSection> {
  late Future<HttpServerInfo> _info = AppStore.instance.httpServerInfo();

  void _reload() {
    setState(() => _info = AppStore.instance.httpServerInfo());
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<HttpServerInfo>(
      future: _info,
      builder: (context, snapshot) {
        final info = snapshot.data;
        final checking =
            snapshot.connectionState == ConnectionState.waiting &&
            info == null;
        final status = info?.status;
        final running = status == HttpServerStatus.running;
        final label = checking
            ? 'Checking…'
            : snapshot.hasError
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
            : status == HttpServerStatus.unavailable || snapshot.hasError
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
                        onPressed: checking ? null : _reload,
                        icon: const Icon(Icons.refresh),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Row(
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
                    Text(url.toString()),
                    const SizedBox(height: 8),
                    textIconButton(
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
                  if (info?.message != null || snapshot.hasError) ...[
                    const SizedBox(height: 8),
                    Text(
                      snapshot.hasError
                          ? 'Could not read server status. Try refreshing.'
                          : info!.message!,
                    ),
                  ],
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}
