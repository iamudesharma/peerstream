import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/media_item.dart';
import '../../models/torrent_models.dart';
import '../../providers/settings_providers.dart';
import 'default_player_screen.dart';
import 'media_forge_player_screen.dart';
import 'player_backend.dart';

/// Thin host that selects the playback backend once per playback session.
///
/// Reads `AppSettings.useMediaForgePlayer` on first data and freezes the
/// choice: changing the setting mid-playback never hot-swaps engines; the
/// new value applies to the next media open. Each implementation owns its
/// controller/UI so `media_kit` and MediaForge types never intertwine.
class PlayerScreen extends ConsumerStatefulWidget {
  const PlayerScreen({
    required this.mediaRef,
    required this.sourceId,
    this.season,
    this.episode,
    this.resumeMs,
    this.initialSource,
    super.key,
  });
  final MediaRef mediaRef;
  final String sourceId;
  final int? season;
  final int? episode;
  final int? resumeMs;
  final TorrentSource? initialSource;

  @override
  ConsumerState<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends ConsumerState<PlayerScreen> {
  PlayerBackend? _frozen;

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(appSettingsProvider);
    return settings.when(
      loading: () => const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      ),
      error: (_, _) => DefaultPlayerScreen(
        mediaRef: widget.mediaRef,
        sourceId: widget.sourceId,
        season: widget.season,
        episode: widget.episode,
        resumeMs: widget.resumeMs,
        initialSource: widget.initialSource,
      ),
      data: (s) {
        _frozen = freezeBackendChoice(_frozen, resolveBackend(s));
        final backend = _frozen!;
        if (backend == PlayerBackend.mediaForge) {
          return MediaForgePlayerScreen(
            mediaRef: widget.mediaRef,
            sourceId: widget.sourceId,
            season: widget.season,
            episode: widget.episode,
            resumeMs: widget.resumeMs,
            initialSource: widget.initialSource,
          );
        }
        return DefaultPlayerScreen(
          mediaRef: widget.mediaRef,
          sourceId: widget.sourceId,
          season: widget.season,
          episode: widget.episode,
          resumeMs: widget.resumeMs,
          initialSource: widget.initialSource,
        );
      },
    );
  }
}
