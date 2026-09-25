import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/torrent/torrent_engine.dart';
import 'app_providers.dart';

final httpServerInfoProvider = FutureProvider.autoDispose<HttpServerInfo>((
  ref,
) {
  // Follow lifecycle changes without probing on every torrent statistics tick.
  ref.watch(playbackPhaseProvider.select((value) => value.value));
  ref.watch(streamingStateProvider.select((value) => value.value?.playback?.uri));
  final engine = ref.watch(streamingServiceProvider).engine;
  if (engine is HttpServerDiagnosticsProvider) {
    return (engine as HttpServerDiagnosticsProvider).httpServerInfo();
  }
  return HttpServerInfo(
    status: HttpServerStatus.unsupported,
    message:
        engine.unsupportedReason ??
        'The built-in HTTP server is unavailable on this platform.',
  );
});
