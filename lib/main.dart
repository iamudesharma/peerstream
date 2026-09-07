import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';

import 'app.dart';
import 'providers/app_providers.dart';

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
  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const PeerStreamApp(),
    ),
  );
}
