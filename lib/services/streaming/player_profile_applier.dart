import 'playback_config.dart';

/// Applies profiles to the app-lifetime player, restoring its original probe
/// settings when switching from a torrent to a direct URL or completed file.
class PlayerProfileApplier {
  PlayerProfileApplier({required this.read, required this.write});

  final Future<String> Function(String) read;
  final Future<void> Function(String, String) write;
  final Map<String, String> _defaults = {};
  final Set<String> _overridden = {};

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
        // Leave untouched automatic options alone on an initial direct open.
        if (property.value == null && !_overridden.contains(property.key)) {
          continue;
        }
        // Capture before the first mutation, once per player lifetime. If an
        // older mpv lacks an option, leave it alone and continue playback.
        final original = _defaults[property.key] ??= await read(property.key);
        var value = property.value ?? original;
        if (property.key == 'demuxer-lavf-probesize' &&
            property.value == null &&
            (int.tryParse(value) ?? 0) < 32) {
          // Bundled mpv exposes an initial 0 sentinel but rejects writing it
          // back (minimum 32). Restore libavformat's standard 5 MB probe budget
          // after a torrent override; never send that invalid sentinel to mpv.
          value = '5000000';
        }
        await write(property.key, value);
        if (property.value != null) _overridden.add(property.key);
      } catch (_) {}
    }
  }
}
