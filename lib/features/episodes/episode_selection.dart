import 'package:peerstream/core/navigation.dart';
import 'package:peerstream/core/gap_widgets.dart';
import 'package:dartnative/flutter_compat.dart' hide Badge;
import 'package:dartnative/dartnative.dart';
import 'package:peerstream/core/icons.dart';

import '../../core/image_url.dart';
import '../../core/design_tokens.dart';
import '../../core/format.dart';
import '../../core/widgets/app_empty.dart';
import '../../core/widgets/app_error.dart';
import '../../core/widgets/skeletons.dart';
import '../../models/season.dart';
import '../../providers/app_store.dart';

class EpisodeSelection extends StatefulWidget {
  const EpisodeSelection({
    required this.seriesId,
    required this.seasons,
    super.key,
  });
  final int seriesId;
  final List<SeasonSummary> seasons;

  @override
  State<EpisodeSelection> createState() => _EpisodeSelectionState();
}

class _EpisodeSelectionState extends State<EpisodeSelection> {
  late final List<SeasonSummary> _regularSeasons =
      widget.seasons.where((s) => s.number > 0).toList();
  late final List<SeasonSummary> _specialSeasons =
      widget.seasons.where((s) => s.number <= 0).toList();
  bool _showSpecials = false;
  late int? _season = _regularSeasons.firstOrNull?.number ??
      widget.seasons.firstOrNull?.number;

  List<SeasonSummary> get _visibleSeasons =>
      _showSpecials ? widget.seasons : _regularSeasons;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (widget.seasons.isEmpty) {
      return const AppEmpty(
        icon: Icons.video_library_outlined,
        title: 'No seasons listed',
        hint: 'TMDB has no season data for this series yet.',
      );
    }
    if (_season == null ||
        !_visibleSeasons.any((s) => s.number == _season)) {
      _season = _visibleSeasons.firstOrNull?.number;
    }
    final seasonValue = _season;
    if (seasonValue == null) {
      return const AppEmpty(
        icon: Icons.video_library_outlined,
        title: 'No seasons listed',
        hint: 'TMDB has no season data for this series yet.',
      );
    }
    final episodes = AppStore.instance.episodes((
      seriesId: widget.seriesId,
      seasonNumber: seasonValue,
    ))..watch(context);
    final activeSeason = widget.seasons
        .where((s) => s.number == seasonValue)
        .firstOrNull;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              'Episodes',
              style: theme.textTheme.headlineSmall
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const Spacer(),
            if (_specialSeasons.isNotEmpty)
              TextButton(
                onPressed: () =>
                    setState(() => _showSpecials = !_showSpecials),
                child: Text(
                  _showSpecials ? 'Hide specials' : 'Show specials',
                ),
              ),
          ],
        ),
        const SizedBox(height: 4),
        if (activeSeason != null)
          Text(
            '${activeSeason.episodeCount} episode${activeSeason.episodeCount == 1 ? '' : 's'}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: DesignTokens.textTertiary,
            ),
          ),
        const SizedBox(height: 12),
        PopupMenuButton<int>(
          initialValue: seasonValue,
          onSelected: (value) => setState(() => _season = value),
          itemBuilder: (context) => [
            for (final season in _visibleSeasons)
              PopupMenuItem<int>(
                value: season.number,
                child: Text(season.name),
              ),
          ],
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              _visibleSeasons
                      .where((season) => season.number == seasonValue)
                      .firstOrNull
                      ?.name ??
                  'Season',
            ),
          ),
        ),
        const SizedBox(height: 8),
        episodes.when(
          loading: () => const EpisodeListSkeleton(),
          error: (error, _) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: AppError(
              title: 'Could not load episodes',
              detail: friendlyError(error),
              onRetry: () => AppStore.instance
                  .episodes((
                    seriesId: widget.seriesId,
                    seasonNumber: seasonValue,
                  ))
                  .reload(),
              retryLabel: 'Retry',
            ),
          ),
          data: (items) {
            if (items.isEmpty) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: AppEmpty(
                  icon: Icons.video_library_outlined,
                  title: 'No episodes in this season',
                  hint: 'Pick another season to keep browsing.',
                ),
              );
            }
            return Column(
              children: [
                for (var i = 0; i < items.length; i++) ...[
                  _EpisodeRow(
                    episode: items[i],
                    onTap: () => context.push(
                      '/sources/tv/${widget.seriesId}?season=$seasonValue&episode=${items[i].number}',
                    ),
                  ),
                  if (i != items.length - 1)
                    const Divider(height: 1, indent: 112),
                ],
              ],
            );
          },
        ),
      ],
    );
  }
}

class _EpisodeRow extends StatelessWidget {
  const _EpisodeRow({required this.episode, required this.onTap});
  final Episode episode;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final still = resolveImageUrl(episode.stillPath, tmdbSize: 'w342');
    final runtime = formatRuntime(episode.runtimeMinutes);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(DesignTokens.radiusInput),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 96,
              height: 54,
              decoration: BoxDecoration(
                color: DesignTokens.surface2,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: DesignTokens.line),
              ),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (still != null)
                    Image.network(
                      still,
                      fit: BoxFit.cover,
                      cacheWidth: 342,
                      fadeInDuration: const Duration(milliseconds: 150),
                      placeholder: const ColoredBox(
                        color: DesignTokens.surface2,
                      ),
                      errorWidget: const Icon(
                        Icons.image_not_supported_outlined,
                        color: DesignTokens.textTertiary,
                      ),
                    )
                  else
                    const Icon(
                      Icons.movie_outlined,
                      color: DesignTokens.textTertiary,
                    ),
                  Center(
                    child: Container(
                      padding: const EdgeInsets.all(4),
                      decoration: const BoxDecoration(
                        color: Colors.black54,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.play_arrow,
                        size: 18,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: DesignTokens.space3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 26,
                        height: 26,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: DesignTokens.surface2,
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(color: DesignTokens.line),
                        ),
                        child: Text(
                          '${episode.number}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          episode.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      if (runtime.isNotEmpty)
                        Text(
                          runtime,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: DesignTokens.textTertiary,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    episode.overview.isEmpty
                        ? 'No summary available for this episode.'
                        : episode.overview,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: DesignTokens.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
