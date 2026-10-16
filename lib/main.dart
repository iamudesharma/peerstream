import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';

import 'app.dart';
import 'services/local_service/service_backend.dart';
import 'services/experience/playback_experience.dart';
import 'core/theme.dart';
import 'core/widgets/storage_startup_error.dart';
import 'providers/app_providers.dart';
import 'providers/player_providers.dart';
import 'services/storage/app_storage.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  await _startApp();
}

bool _startingApp = false;
Future<void> _startApp() async {
  if (_startingApp) return;
  _startingApp = true;
  runApp(
    MaterialApp(
      theme: buildPeerStreamTheme(),
      home: const Scaffold(body: Center(child: Text('Preparing saved data…'))),
    ),
  );
  try {
    await appStorage.initialize();
    await playbackExperience.load();
    await configureExperimentalService();
  } catch (_) {
    _startingApp = false;
    runApp(
      MaterialApp(
        theme: buildPeerStreamTheme(),
        home: StorageStartupError(onRetry: () => unawaited(_startApp())),
      ),
    );
    return;
  }
  _startingApp = false;
  final container = ProviderContainer();
  // Prepare the shared default player and renderer while Home loads, so the
  // first Play tap does not also pay libmpv/video-output initialization.
  if (!kIsWeb) container.read(mediaKitVideoControllerProvider);
  unawaited(
    container
        .read(myListProvider.future)
        .then<void>((_) {}, onError: (Object _, StackTrace _) {}),
  );
  unawaited(
    container
        .read(watchHistoryProvider.future)
        .then<void>((_) {}, onError: (Object _, StackTrace _) {}),
  );
  unawaited(
    container
        .read(addonUrlsProvider.future)
        .then<void>((_) {}, onError: (Object _, StackTrace _) {}),
  );
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
  var exiting = false;
  WidgetsBinding.instance.addObserver(
    _PlaybackMemoryPressureObserver(() {
      if (exiting) return;
      PaintingBinding.instance.imageCache.clear();
      unawaited(
        container
            .read(streamingServiceProvider)
            .handleMemoryPressure()
            .catchError((Object _) {}),
      );
    }),
  );
  AppLifecycleListener(
    onStateChange: (state) {
      if (!exiting &&
          (state == AppLifecycleState.paused ||
              state == AppLifecycleState.hidden ||
              state == AppLifecycleState.detached)) {
        unawaited(container.read(streamingServiceProvider).persistState());
      }
    },
    onExitRequested: () {
      exiting = true;
      return performAppExit(
        persistState: () =>
            container.read(streamingServiceProvider).persistState(),
        stopPlayer: () => container.read(mediaKitPlayerProvider).stop(),
        disposeServices: () async {
          final service = container.read(streamingServiceProvider);
          // Unobserved Riverpod streams are paused, so their subscriptions must
          // be cancelled before awaiting the service's broadcast stream close.
          container.dispose();
          await service.dispose();
        },
      );
    },
  );
  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const PeerStreamApp(),
    ),
  );
}

class _PlaybackMemoryPressureObserver extends WidgetsBindingObserver {
  _PlaybackMemoryPressureObserver(this.onPressure);
  final VoidCallback onPressure;
  @override
  void didHaveMemoryPressure() => onPressure();
}
