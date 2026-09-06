import 'package:flutter/material.dart' hide Badge;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/design_tokens.dart';
import '../../core/format.dart';
import '../../core/widgets/app_empty.dart';
import '../../core/widgets/app_error.dart';
import '../../core/widgets/badges.dart';
import '../../core/widgets/skeletons.dart';
import '../../models/media_item.dart';
import '../../models/torrent_models.dart';
import '../../providers/app_providers.dart';
import '../../services/torrent/addon_provider.dart';

enum _SortMode { seeds, size }

class SourceSelectionScreen extends ConsumerStatefulWidget {
  const SourceSelectionScreen({
    required this.mediaRef,
    this.season,
    this.episode,
    super.key,
  });
  final MediaRef mediaRef;
  final int? season;
  final int? episode;

  @override
  ConsumerState<SourceSelectionScreen> createState() =>
      _SourceSelectionScreenState();
}

class _SourceSelectionScreenState
    extends ConsumerState<SourceSelectionScreen> {
  _SortMode _sort = _SortMode.seeds;
  final _savedSourceIds = <String>{};

  SourceRequest get _request => (
        media: widget.mediaRef,
        season: widget.season,
        episode: widget.episode,
      );

  String _contextLabel() {
    if (widget.mediaRef.type == MediaType.tv &&
        widget.season != null &&
        widget.episode != null) {
      return 'S${widget.season} E${widget.episode}';
    }
    return widget.mediaRef.type == MediaType.movie ? 'Movie' : 'Series';
  }

  @override
  Widget build(BuildContext context) {
    final results = ref.watch(sourceResultsProvider(_request));
    final details = ref.watch(detailsProvider(widget.mediaRef));
    final title = details.when(
      data: (value) => value.item.title,
      loading: () => 'Sources',
      error: (_, _) => 'Sources',
    );
    return Scaffold(
      appBar: AppBar(
        title: Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            tooltip: 'Providers',
            icon: const Icon(Icons.tune),
            onPressed: () async {
              await showDialog<void>(
                context: context,
                builder: (_) => const _ProviderSettings(),
              );
              ref.invalidate(sourceResultsProvider(_request));
            },
          ),
          IconButton(
            tooltip: 'Search again',
            icon: const Icon(Icons.refresh),
            onPressed: () => ref.invalidate(sourceResultsProvider(_request)),
          ),
        ],
      ),
      body: Column(
        children: [
          _ContextBar(
            contextLabel: _contextLabel(),
            sort: _sort,
            onSortChanged: (sort) => setState(() => _sort = sort),
          ),
          Expanded(
            child: results.when(
              loading: () => ListView(
                padding: const EdgeInsets.all(DesignTokens.pageGutter),
                children: const [
                  _SearchingBanner(),
                  SizedBox(height: DesignTokens.space4),
                  SourceListSkeleton(),
                ],
              ),
              error: (error, _) => AppError(
                title: 'Could not load sources',
                detail: friendlyError(error),
                onRetry: () =>
                    ref.invalidate(sourceResultsProvider(_request)),
                retryLabel: 'Retry search',
                secondary: OutlinedButton.icon(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => const _ProviderSettings(),
                  ),
                  icon: const Icon(Icons.tune),
                  label: const Text('Edit providers'),
                ),
              ),
              data: (providers) {
                final total =
                    providers.expand((p) => p.sources).length;
                if (total == 0 && providers.every((p) => p.error == null)) {
                  return AppEmpty(
                    icon: Icons.video_library_outlined,
                    title: 'No playable sources found',
                    hint:
                        'Try another provider or search again. For a series, choose an episode first.',
                    action: FilledButton.icon(
                      onPressed: () => showDialog<void>(
                        context: context,
                        builder: (_) => const _ProviderSettings(),
                      ),
                      icon: const Icon(Icons.tune),
                      label: const Text('Edit providers'),
                    ),
                  );
                }
                return DefaultTabController(
                  length: providers.length + 1,
                  child: Column(
                    children: [
                      TabBar(
                        isScrollable: true,
                        tabAlignment: TabAlignment.start,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        tabs: [
                          Tab(text: 'All ($total)'),
                          for (final p in providers)
                            Tab(
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  StatusDot(
                                    color: p.error != null
                                        ? DesignTokens.danger
                                        : DesignTokens.accent,
                                    semanticLabel: p.error != null
                                        ? '${p.name} has an error'
                                        : '${p.name} is healthy',
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    '${p.name} (${p.sources.length})',
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),
                      Expanded(
                        child: TabBarView(
                          children: [
                            _Results(
                              providers: providers,
                              sort: _sort,
                              savedIds: _savedSourceIds,
                              onToggleSaved: (id) => setState(() {
                                if (_savedSourceIds.contains(id)) {
                                  _savedSourceIds.remove(id);
                                } else {
                                  _savedSourceIds.add(id);
                                }
                              }),
                            ),
                            for (final p in providers)
                              _Results(
                                providers: [p],
                                sort: _sort,
                                savedIds: _savedSourceIds,
                                onToggleSaved: (id) => setState(() {
                                  if (_savedSourceIds.contains(id)) {
                                    _savedSourceIds.remove(id);
                                  } else {
                                    _savedSourceIds.add(id);
                                  }
                                }),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _ContextBar extends StatelessWidget {
  const _ContextBar({
    required this.contextLabel,
    required this.sort,
    required this.onSortChanged,
  });

  final String contextLabel;
  final _SortMode sort;
  final ValueChanged<_SortMode> onSortChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: const BoxDecoration(
        color: DesignTokens.surface,
        border: Border(bottom: BorderSide(color: DesignTokens.line)),
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: DesignTokens.pageGutter,
        vertical: 10,
      ),
      child: Row(
        children: [
          Badge(label: contextLabel, tone: BadgeTone.neutral),
          const Spacer(),
          Text(
            'Sort',
            style: theme.textTheme.bodySmall?.copyWith(
              color: DesignTokens.textTertiary,
            ),
          ),
          const SizedBox(width: 8),
          SegmentedButton<_SortMode>(
            style: const ButtonStyle(
              visualDensity: VisualDensity.compact,
            ),
            segments: const [
              ButtonSegment(
                value: _SortMode.seeds,
                icon: Icon(Icons.arrow_downward, size: 14),
                label: Text('Seeds'),
              ),
              ButtonSegment(
                value: _SortMode.size,
                icon: Icon(Icons.storage_outlined, size: 14),
                label: Text('Size'),
              ),
            ],
            selected: {sort},
            onSelectionChanged: (selected) =>
                onSortChanged(selected.first),
          ),
        ],
      ),
    );
  }
}

class _SearchingBanner extends StatelessWidget {
  const _SearchingBanner();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(DesignTokens.space3),
      decoration: BoxDecoration(
        color: DesignTokens.surface,
        borderRadius:
            BorderRadius.circular(DesignTokens.radiusCard),
        border: Border.all(color: DesignTokens.line),
      ),
      child: Row(
        children: [
          const SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          ),
          const SizedBox(width: DesignTokens.space3),
          Expanded(
            child: Text(
              'Searching all configured providers',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: DesignTokens.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Results extends StatelessWidget {
  const _Results({
    required this.providers,
    required this.sort,
    required this.savedIds,
    required this.onToggleSaved,
  });

  final List<ProviderResult> providers;
  final _SortMode sort;
  final Set<String> savedIds;
  final ValueChanged<String> onToggleSaved;

  @override
  Widget build(BuildContext context) {
    final sources = providers.expand((p) => p.sources).toList()
      ..sort((a, b) {
        if (sort == _SortMode.size) {
          return (b.sizeBytes ?? -1).compareTo(a.sizeBytes ?? -1);
        }
        return (b.seeds ?? -1).compareTo(a.seeds ?? -1);
      });
    return ListView(
      padding: const EdgeInsets.all(DesignTokens.pageGutter),
      children: [
        for (final provider in providers.where((p) => p.error != null))
          Container(
            margin: const EdgeInsets.only(bottom: DesignTokens.space3),
            decoration: BoxDecoration(
              color: DesignTokens.surface,
              borderRadius:
                  BorderRadius.circular(DesignTokens.radiusCard),
              border: Border.all(
                color: DesignTokens.danger.withValues(alpha: 0.4),
              ),
            ),
            child: ListTile(
              leading: const Icon(
                Icons.error_outline,
                color: DesignTokens.danger,
              ),
              title: Text(provider.name),
              subtitle: Text(
                provider.error!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        if (sources.isEmpty)
          const AppEmpty(
            icon: Icons.video_library_outlined,
            title: 'No sources in this lane',
            hint: 'Switch to the All tab or try another provider.',
          ),
        for (final source in sources)
          _SourceCard(
            source: source,
            saved: savedIds.contains(source.id),
            onToggleSaved: () => onToggleSaved(source.id),
          ),
      ],
    );
  }
}

class _SourceCard extends StatelessWidget {
  const _SourceCard({
    required this.source,
    required this.saved,
    required this.onToggleSaved,
  });

  final TorrentSource source;
  final bool saved;
  final VoidCallback onToggleSaved;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final quality = formatQuality(source.name);
    return Container(
      margin: const EdgeInsets.only(bottom: DesignTokens.space3),
      decoration: BoxDecoration(
        color: DesignTokens.surface,
        borderRadius:
            BorderRadius.circular(DesignTokens.radiusCard),
        border: Border.all(color: DesignTokens.line),
      ),
      padding: const EdgeInsets.all(DesignTokens.space4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: SelectableText(
                  source.name,
                  maxLines: 2,
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              IconButton(
                tooltip: saved ? 'Remove bookmark' : 'Bookmark source',
                visualDensity: VisualDensity.compact,
                icon: Icon(
                  saved ? Icons.bookmark : Icons.bookmark_border,
                  color: saved ? DesignTokens.accent : null,
                ),
                onPressed: onToggleSaved,
              ),
            ],
          ),
          Text(
            source.providerName,
            style: theme.textTheme.bodySmall?.copyWith(
              color: DesignTokens.textTertiary,
            ),
          ),
          if (source.description?.isNotEmpty == true) ...[
            const SizedBox(height: DesignTokens.space2),
            Text(
              source.description!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: DesignTokens.textSecondary,
              ),
            ),
          ],
          const SizedBox(height: DesignTokens.space3),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              Badge(
                label: source.inputType == TorrentInputType.directUrl
                    ? 'Direct'
                    : 'Torrent',
                tone: source.inputType == TorrentInputType.directUrl
                    ? BadgeTone.accent
                    : BadgeTone.neutral,
                icon: source.inputType == TorrentInputType.directUrl
                    ? Icons.bolt
                    : Icons.hub_outlined,
              ),
              if (quality != null)
                Badge(
                  label: quality,
                  icon: Icons.high_quality_outlined,
                ),
              if (source.inputType != TorrentInputType.directUrl &&
                  source.seeds != null)
                Badge(
                  label: 'Seeds ${source.seeds}',
                  icon: Icons.arrow_upward,
                ),
              if (source.peers != null)
                Badge(
                  label: 'Peers ${source.peers}',
                  icon: Icons.people_outline,
                ),
              if (source.sizeBytes != null)
                Badge(label: formatBytes(source.sizeBytes!)),
            ],
          ),
          if (source.license.isNotEmpty) ...[
            const SizedBox(height: DesignTokens.space2),
            Text(
              source.license,
              style: theme.textTheme.bodySmall?.copyWith(
                color: DesignTokens.textTertiary,
              ),
            ),
          ],
          const SizedBox(height: DesignTokens.space3),
          Row(
            children: [
              FilledButton.icon(
                onPressed: () => context.push(
                  Uri(
                    path: '/player/${source.content.routeKey}',
                    queryParameters: {
                      'source': source.id,
                      if (source.seasonNumber != null)
                        'season': '${source.seasonNumber}',
                      if (source.episodeNumber != null)
                        'episode': '${source.episodeNumber}',
                    },
                  ).toString(),
                ),
                icon: const Icon(Icons.play_arrow),
                label: const Text('Play source'),
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: 'Copy link',
                icon: const Icon(Icons.link_outlined),
                onPressed: () async {
                  await Clipboard.setData(
                    ClipboardData(text: source.uri.toString()),
                  );
                  if (context.mounted) {
                    ScaffoldMessenger.of(context)
                      ..hideCurrentSnackBar()
                      ..showSnackBar(
                        const SnackBar(content: Text('Link copied')),
                      );
                  }
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ProviderSettings extends ConsumerStatefulWidget {
  const _ProviderSettings();
  @override
  ConsumerState<_ProviderSettings> createState() =>
      _ProviderSettingsState();
}

class _ProviderSettingsState extends ConsumerState<_ProviderSettings> {
  TextEditingController? _text;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _text?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final urls = ref.watch(addonUrlsProvider);
    return PopScope(
      canPop: !_saving,
      child: AlertDialog(
        title: const Text('Source providers'),
        content: LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth > 420
                ? 420.0
                : constraints.maxWidth;
            return SizedBox(
              width: width,
              child: SingleChildScrollView(
                child: urls.when(
                  loading: () => const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child:
                        Center(child: CircularProgressIndicator()),
                  ),
                  error: (error, _) => AppError(
                    title: 'Could not load providers',
                    detail: friendlyError(error),
                    onRetry: () =>
                        ref.invalidate(addonUrlsProvider),
                    retryLabel: 'Retry',
                  ),
                  data: (value) {
                    _text ??= TextEditingController(
                      text: value.join('\n'),
                    );
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'All saved catalogs are searched together. Put one catalog link per line. Changes stay on this device.',
                          style: Theme.of(context)
                              .textTheme
                              .bodyMedium
                              ?.copyWith(
                                color: DesignTokens.textSecondary,
                              ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _text,
                          minLines: 3,
                          maxLines: 6,
                          decoration: InputDecoration(
                            labelText: 'Catalog links',
                            hintText:
                                'https://torrentio.strem.fun/manifest.json',
                            errorText: _error,
                          ),
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          'Start with the default Torrentio catalog. Extra catalogs add more results but vary in reliability.',
                          style: TextStyle(
                            color: DesignTokens.textTertiary,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            );
          },
        ),
        actions: [
          TextButton(
            onPressed: _saving ? null : () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: urls.hasValue && !_saving
                ? () async {
                    setState(() {
                      _saving = true;
                      _error = null;
                    });
                    try {
                      final controller = _text;
                      if (controller == null) {
                        throw StateError('Editor is not ready.');
                      }
                      await ref
                          .read(addonUrlsProvider.notifier)
                          .save(
                            controller.text
                                .split('\n')
                                .map((s) => s.trim())
                                .where((s) => s.isNotEmpty)
                                .toList(),
                          );
                      if (context.mounted) Navigator.pop(context);
                    } catch (_) {
                      if (mounted) {
                        setState(() {
                          _saving = false;
                          _error =
                              'Could not save. Check the links and try again.';
                        });
                      }
                    }
                  }
                : null,
            child: Text(_saving ? 'Saving' : 'Save and search'),
          ),
        ],
      ),
    );
  }
}
