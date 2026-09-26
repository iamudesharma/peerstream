import 'playback_config.dart';

/// Applies profiles to the app-lifetime player, restoring its original probe
/// settings when switching from a torrent to a direct URL or completed file.
class PlayerProfileApplier {
  PlayerProfileApplier({required this.read, required this.write});

  final Future<String> Function(String) read;
  final Future<void> Function(String, String) write;
  final Map<String, String> _defaults = {};

  Future<void> apply(PlayerProfile profile) async {
    final properties = <String, String?>{
      'network-timeout': profile.networkTimeoutSecs,
      'demuxer-max-bytes': profile.demuxerMaxBytes,
      'cache-secs': profile.cacheSecs,
      'demuxer-readahead-secs': profile.readaheadSecs,
      'cache-on-disk': profile.cacheOnDisk ? 'yes' : 'no',
      'demuxer-lavf-probesize': profile.probeSizeBytes?.toString(),
      'demuxer-lavf-analyzeduration': profile.analyzeDurationSecs?.toString(),
    };
    for (final property in properties.entries) {
      try {
        // Capture before the first mutation, once per player lifetime. If an
        // older mpv lacks an option, leave it alone and continue playback.
        final original = _defaults[property.key] ??= await read(property.key);
        await write(property.key, property.value ?? original);
      } catch (_) {}
    }
  }
}
