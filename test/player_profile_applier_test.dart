import 'package:test/test.dart';
import 'package:peerstream/services/streaming/playback_config.dart';
import 'package:peerstream/services/streaming/player_profile_applier.dart';

void main() {
  test(
    'torrent limits reach the player and reset for subsequent URLs',
    () async {
      final properties = <String, String>{
        'demuxer-lavf-probesize': '5000000',
        'demuxer-lavf-analyzeduration': '0',
        'cache-on-disk': 'yes',
      };
      final applier = PlayerProfileApplier(
        read: (key) async => properties[key] ?? 'default',
        write: (key, value) async {
          properties[key] = value;
        },
      );
      await applier.apply(PlayerProfile.torrent);
      expect(properties['demuxer-lavf-probesize'], '2097152');
      expect(properties['demuxer-lavf-analyzeduration'], '1.0');
      expect(properties['cache-on-disk'], 'no');
      await applier.apply(PlayerProfile.direct);
      expect(properties['demuxer-lavf-probesize'], '5000000');
      expect(properties['demuxer-lavf-analyzeduration'], '0');
      await applier.apply(PlayerProfile.torrent);
      await applier.apply(PlayerProfile.cache);
      expect(properties['demuxer-lavf-probesize'], '5000000');
      expect(properties['demuxer-lavf-analyzeduration'], '0');
    },
  );

  test(
    'unsupported optional properties do not block remaining tuning',
    () async {
      final written = <String, String>{};
      final applier = PlayerProfileApplier(
        read: (key) async {
          if (key == 'cache-on-disk') throw StateError('unsupported');
          return 'original';
        },
        write: (key, value) async {
          if (key == 'network-timeout') throw StateError('unsupported');
          written[key] = value;
        },
      );
      await applier.apply(PlayerProfile.torrent);
      expect(written['demuxer-lavf-analyzeduration'], '1.0');
      expect(written, isNot(contains('cache-on-disk')));
    },
  );
}
