import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../services/streaming/player_profile_applier.dart';

/// App-lifetime media_kit player shared by every playback screen.
///
/// Deliberately never disposed during navigation: media_kit 1.2.6 closes the
/// native libmpv wakeup callback in `Player.dispose()` while libmpv may still
/// invoke it (the handle is destroyed on a 5s delay), which aborts debug
/// builds with "Callback invoked after it has been deleted". Screens stop
/// playback when they close; the next screen reuses the same instance.
final mediaKitPlayerProvider = Provider<Player>((ref) => Player());

final mediaKitProfileApplierProvider = Provider<PlayerProfileApplier?>((ref) {
  final native = ref.watch(mediaKitPlayerProvider).platform;
  if (native is! NativePlayer) return null;
  return PlayerProfileApplier(
    read: native.getProperty,
    write: native.setProperty,
  );
});

/// Video output controller bound to [mediaKitPlayerProvider]. Reused for the
/// same reason as the player.
final mediaKitVideoControllerProvider = Provider<VideoController>(
  (ref) => VideoController(ref.watch(mediaKitPlayerProvider)),
);
