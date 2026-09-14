import 'package:flutter_test/flutter_test.dart';
import 'package:peerstream/services/streaming/playback_config.dart';

void main() {
  group('PlayerProfile', () {
    test('torrent profile bounds FFmpeg probing and disables disk cache', () {
      const profile = PlayerProfile.torrent;
      expect(profile.probeSizeBytes, isNotNull);
      expect(profile.probeSizeBytes! > 0, isTrue);
      expect(profile.analyzeDurationSecs, isNotNull);
      expect(profile.analyzeDurationSecs! > 0, isTrue);
      expect(profile.cacheOnDisk, isFalse);
    });

    test('direct and cache profiles keep default probing', () {
      expect(PlayerProfile.direct.probeSizeBytes, isNull);
      expect(PlayerProfile.direct.analyzeDurationSecs, isNull);
      expect(PlayerProfile.cache.probeSizeBytes, isNull);
      expect(PlayerProfile.cache.analyzeDurationSecs, isNull);
    });

    test('forOrigin selects the right profile', () {
      expect(PlayerProfile.forOrigin(true, false), PlayerProfile.cache);
      expect(PlayerProfile.forOrigin(false, true), PlayerProfile.direct);
      expect(PlayerProfile.forOrigin(false, false), PlayerProfile.torrent);
    });
  });
}
