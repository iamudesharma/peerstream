import 'dart:async';
import 'dart:typed_data';

import 'package:dartnative/dartnative.dart';
import 'package:libtorrent_flutter/libtorrent_flutter.dart' as lt;

import 'app.dart';
import 'core/navigation.dart';
import 'dartnative_plugin_registrant.dart';
import 'providers/app_store.dart';
import 'services/torrent/torrent_engine.dart';

Future<void> main() async {
  DartNativePluginRegistrant.registerAll();
  SystemChrome.defaultStyle = const SystemUiOverlayStyle(
    statusBarColor: Color(0x00000000),
    statusBarBrightness: Brightness.dark,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: Color(0xFF07090D),
    systemNavigationBarIconBrightness: Brightness.light,
  );
  lt.loadCaBundle = () async {
    final bytes = loadAssetBytes('assets/cacert.pem');
    return bytes == null ? null : Uint8List.fromList(bytes);
  };
  setAppBrightness(Brightness.dark);
  registerPeerStreamRoutes();
  final store = AppStore.instance;
  unawaited(AppStore.instance.myList.reload());
  unawaited(AppStore.instance.history.reload());
  unawaited(AppStore.instance.addonUrls.reload());
  WidgetsBinding.instance.addObserver(_QuitObserver(store));
  runApp(PeerStreamApp());
}

class _QuitObserver with WidgetsBindingObserver {
  _QuitObserver(this.store);

  final AppStore store;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      final engine = AppStore.instance.streaming.engine;
      if (engine is TorrentStatePersistence) {
        final persistence = engine as TorrentStatePersistence;
        unawaited(persistence.persistSessionState());
      }
    }
  }
}
