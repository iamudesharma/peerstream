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
import '../../services/streaming/source_ranking.dart';
import '../../services/torrent/addon_provider.dart';
import '../../services/torrent/source_discovery.dart';
import '../player/player_backend.dart';

enum _SortMode { seeds, size }

/// Picks the torrent most worth warming: exact file match first, then most
/// seeds. Direct URLs need no prefetch.
TorrentSource? _bestPrefetchCandidate(List<TorrentSource> sources) {
  final torrents = sources
      .where((s) => s.inputType != TorrentInputType.directUrl)
      .toList();
  if (torrents.isEmpty) return null;
  torrents.sort((a, b) {
    final aExact = (a.fileIndex != null || a.fileNameHint != null) ? 1 : 0;
    final bExact = (b.fileIndex != null || b.fileNameHint != null) ? 1 : 0;
    if (aExact != bExact) return bExact.compareTo(aExact);
    return (b.seeds ?? -1).compareTo(a.seeds ?? -1);
  });
  return torrents.first;
}

/// Instant-start ranking: Direct streams first (no torrent handshake), then
/// exact file matches, then seeds. Size is a tie-breaker (smaller starts
/// faster on thin swarms). Delegates to the shared playability ranker so
/// browsing and retry agree on "best".
int _compareSources(TorrentSource a, TorrentSource b, _SortMode sort) {
  if (sort == _SortMode.size) {
    final sizeCmp = (b.sizeBytes ?? -1).compareTo(a.sizeBytes ?? -1);
    if (sizeCmp != 0) return sizeCmp;
    return (b.seeds ?? -1).compareTo(a.seeds ?? -1);
  }
  return compareRankedSources(a, b);
}

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
  bool _directOnly = false;
  String _quality = 'All';

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
    // Incremental discovery: fast providers appear immediately while slow
    // ones still load. The banner below surfaces per-provider progress.
    final discovery = ref.watch(sourceDiscoveryProvider(_request));
    // Warm the torrent session while addons resolve, and prefetch the single
    // best torrent candidate once results arrive so metadata is ready by tap
    // time. Deduplication and unused-candidate release live in the service.
    ref.listen(sourceResultsProvider(_request), (_, next) {
      next.whenData((providers) {
        final service = ref.read(streamingServiceProvider);
        // ignore: discarded_futures
        service.warmUp();
        final candidates = providers.expand((p) => p.sources).toList();
        final best = _bestPrefetchCandidate(candidates);
        if (best != null) {
          // ignore: discarded_futures
          service.prefetchSource(best);
        }
      });
    });
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
              ref.invalidate(sourceDiscoveryProvider(_request));
            },
          ),
          IconButton(
            tooltip: 'Search again',
            icon: const Icon(Icons.refresh),
            onPressed: () {
              ref.invalidate(sourceResultsProvider(_request));
              ref.invalidate(sourceDiscoveryProvider(_request));
            },
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
          _FilterBar(
            directOnly: _directOnly,
            quality: _quality,
            onDirectOnlyChanged: (v) => setState(() => _directOnly = v),
            onQualityChanged: (q) => setState(() => _quality = q),
          ),
          Expanded(
            child: results.when(
              loading: () {
                // Show fast incremental results immediately instead of
                // holding everything behind the slowest provider.
                final incremental = discovery.value;
                final fast = incremental?.allSources ?? const [];
                if (fast.isNotEmpty) {
                  final lane = [
                    ProviderResult('Fast results', List.of(fast)),
                  ];
                  return Column(
                    children: [
                      _IncrementalBanner(discovery: incremental),
                      Expanded(
                        child: _Results(
                          providers: lane,
                          sort: _sort,
                          savedIds: _savedSourceIds,
                          directOnly: _directOnly,
                          quality: _quality,
                          onToggleSaved: (id) => setState(() {
                            if (_savedSourceIds.contains(id)) {
                              _savedSourceIds.remove(id);
                            } else {
                              _savedSourceIds.add(id);
                            }
                          }),
                        ),
                      ),
                    ],
                  );
                }
                return ListView(
                  padding: const EdgeInsets.all(DesignTokens.pageGutter),
                  children: [
                    const _SearchingBanner(),
                    _IncrementalBanner(discovery: incremental),
                    const SizedBox(height: DesignTokens.space4),
                    const SourceListSkeleton(),
                  ],
                );
              },
              error: (error, _) => AppError(
                title: 'Could not load sources',
                detail: friendlyError(error),
                onRetry: () {
                  ref.invalidate(sourceResultsProvider(_request));
                  ref.invalidate(sourceDiscoveryProvider(_request));
                },
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
                              directOnly: _directOnly,
                              quality: _quality,
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
                                directOnly: _directOnly,
                                quality: _quality,
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

class _FilterBar extends StatelessWidget {
  const _FilterBar({
    required this.directOnly,
    required this.quality,
    required this.onDirectOnlyChanged,
    required this.onQualityChanged,
  });

  final bool directOnly;
  final String quality;
  final ValueChanged<bool> onDirectOnlyChanged;
  final ValueChanged<String> onQualityChanged;

  static const qualities = ['All', '4K', '1080p', '720p', '480p', 'CAM'];

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: DesignTokens.surface,
        border: Border(bottom: BorderSide(color: DesignTokens.line)),
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: DesignTokens.pageGutter,
        vertical: 8,
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            FilterChip(
              label: const Text('Direct only'),
              avatar: const Icon(Icons.bolt, size: 16),
              selected: directOnly,
              visualDensity: VisualDensity.compact,
              onSelected: onDirectOnlyChanged,
            ),
            const SizedBox(width: 8),
            for (final q in qualities)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: ChoiceChip(
                  label: Text(q),
                  selected: quality == q,
                  visualDensity: VisualDensity.compact,
                  onSelected: (_) => onQualityChanged(q),
                ),
              ),
          ],
        ),
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

class _IncrementalBanner extends StatelessWidget {
  const _IncrementalBanner({required this.discovery});
  final IncrementalDiscoveryState? discovery;

  @override
  Widget build(BuildContext context) {
    final current = discovery;
    if (current == null) return const SizedBox.shrink();
    final providers = current.providers.values.toList();
    final ready = providers
        .where((p) => p.status == ProviderStatus.ready)
        .length;
    final total = providers.length;
    final count = current.allSources.length;
    final complete = current.isComplete;
    if (total == 0) return const SizedBox.shrink();
    final label = complete
        ? 'All $total providers answered · $count sources'
        : '$ready of $total providers answered · $count sources so far';
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: DesignTokens.surface,
        borderRadius: BorderRadius.circular(DesignTokens.radiusCard),
        border: Border.all(color: DesignTokens.line),
      ),
      child: Row(
        children: [
          if (!complete)
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            const Icon(Icons.check_circle_outline, size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
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
    this.directOnly = false,
    this.quality = 'All',
  });

  final List<ProviderResult> providers;
  final _SortMode sort;
  final Set<String> savedIds;
  final ValueChanged<String> onToggleSaved;
  final bool directOnly;
  final String quality;

  @override
  Widget build(BuildContext context) {
    final errors = providers.where((p) => p.error != null).toList();
    var sources = providers.expand((p) => p.sources).toList();
    if (directOnly) {
      sources = sources
          .where((s) => s.inputType == TorrentInputType.directUrl)
          .toList();
    }
    if (quality != 'All') {
      sources = sources
          .where((s) => formatQuality(s.name) == quality)
          .toList();
    }
    sources.sort((a, b) => _compareSources(a, b, sort));
    final itemCount = errors.length + (sources.isEmpty ? 1 : sources.length);
    return ListView.builder(
      padding: const EdgeInsets.all(DesignTokens.pageGutter),
      itemCount: itemCount,
      itemBuilder: (context, index) {
        if (index < errors.length) {
          final provider = errors[index];
          return Container(
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
          );
        }
        if (sources.isEmpty) {
          return AppEmpty(
            icon: Icons.video_library_outlined,
            title: directOnly || quality != 'All'
                ? 'No sources match these filters'
                : 'No sources in this lane',
            hint: directOnly || quality != 'All'
                ? 'Clear Direct-only or quality filters to see more.'
                : 'Switch to the All tab or try another provider.',
          );
        }
        final source = sources[index - errors.length];
        return _SourceCard(
          source: source,
          saved: savedIds.contains(source.id),
          onToggleSaved: () => onToggleSaved(source.id),
        );
      },
    );
  }
}

class _SourceCard extends ConsumerWidget {
  const _SourceCard({
    required this.source,
    required this.saved,
    required this.onToggleSaved,
  });

  final TorrentSource source;
  final bool saved;
  final VoidCallback onToggleSaved;

  void _play(BuildContext context, WidgetRef ref) {
    // Prefetch in case hover did not fire (touch devices), then navigate
    // with the full source as `extra` so the player skips addon re-query.
    // ignore: discarded_futures
    ref.read(streamingServiceProvider).prefetchSource(source);
    // Carry a saved position when history has one for this exact source,
    // mirroring Continue Watching. The player screens still apply
    // trivial/finished filtering, so this never forces a bad resume.
    final resumeMs = resumeMsForSource(
      source: source,
      history: ref.read(watchHistoryProvider).value,
    );
    context.push(
      Uri(
        path: '/player/${source.content.routeKey}',
        queryParameters: {
          'source': source.id,
          if (source.seasonNumber != null)
            'season': '${source.seasonNumber}',
          if (source.episodeNumber != null)
            'episode': '${source.episodeNumber}',
          if (resumeMs != null) 'resume': '$resumeMs',
        },
      ).toString(),
      extra: source,
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
              MouseRegion(
                onEnter: (_) {
                  // Desktop hover: start metadata exchange before tap.
                  // ignore: discarded_futures
                  ref.read(streamingServiceProvider).prefetchSource(source);
                },
                child: FilledButton.icon(
                  onPressed: () => _play(context, ref),
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Play source'),
                ),
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
