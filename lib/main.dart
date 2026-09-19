import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';

import 'app.dart';
import 'providers/app_providers.dart';
import 'providers/player_providers.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  final container = ProviderContainer();
  unawaited(container.read(myListProvider.future));
  unawaited(container.read(watchHistoryProvider.future));
  unawaited(container.read(addonUrlsProvider.future));
  // Warm the torrent session (DHT bootstrap, native init) at app launch so
  // the first Play tap does not pay cold-start cost in the player.
  unawaited(container.read(streamingServiceProvider).warmUp());
  // Tear native work down before the Dart isolate is destroyed. Without this,
  // libmpv/libtorrent wakeups delivered during isolate teardown invoke FFI
  // callbacks the VM has already deleted ("Callback invoked after it has been
  // deleted"), aborting debug builds on quit. Disposing the streaming service
  // also records the final verified cache state.
  // The binding retains the listener as an observer; no field needed. It is
  // deliberately never disposed: exit dispatch awaits each observer in turn
  // (WidgetsBinding.handleRequestAppExit), so disposing during teardown can
  // invalidate a listener mid-dispatch and trip the used-after-dispose
  // assertion. This is the sole exit-handling listener, so it stays valid
  // for the full dispatch; state saving (persistState) runs before teardown.
  AppLifecycleListener(
    onStateChange: (state) {
      if (state == AppLifecycleState.paused ||
          state == AppLifecycleState.hidden ||
          state == AppLifecycleState.detached) {
        unawaited(container.read(streamingServiceProvider).persistState());
      }
    },
    onExitRequested: () => performAppExit(
      persistState: () =>
          container.read(streamingServiceProvider).persistState(),
      stopPlayer: () => container.read(mediaKitPlayerProvider).stop(),
      disposeServices: () =>
          container.read(streamingServiceProvider).dispose(),
    ),
  );
  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const PeerStreamApp(),
    ),
  );
}
