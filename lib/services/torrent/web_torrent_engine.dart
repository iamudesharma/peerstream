import '../../models/torrent_models.dart';
import 'torrent_engine.dart';

class WebTorrentEngine
    implements
        TorrentEngine,
        FileCompletenessChecker,
        EngineDiagnosticsProvider {
  static const _reason =
      'Torrent playback is not available in the Web MVP. Browse TMDB here, then use a native PeerStream app to play legal torrents.';

  @override
  bool get isSupported => false;
  @override
  String? get unsupportedReason => _reason;
  Never _unsupported() => throw UnsupportedError(_reason);
  @override
  Future<void> initialize() async {}
  @override
  Future<TorrentHandle> add(TorrentSource source) async => _unsupported();
  @override
  Future<List<TorrentFileEntry>> waitForFiles(TorrentHandle handle) async =>
      _unsupported();
  @override
  Stream<TorrentStats> watch(TorrentHandle handle) => const Stream.empty();
  @override
  Future<TorrentPlaybackStream> startStream(
    TorrentHandle handle,
    TorrentFileEntry file,
  ) async => _unsupported();
  @override
  Future<void> stop(TorrentHandle handle, {bool deleteFiles = false}) async {}
  @override
  Future<void> dispose() async {}

  @override
  String get bridgeVersion => 'web-unsupported';

  @override
  Future<EngineDiagnostics> engineDiagnostics() async =>
      const EngineDiagnostics(bridgeVersion: 'web-unsupported');

  @override
  Future<bool> isFileComplete(
    TorrentHandle handle,
    TorrentFileEntry file,
  ) async => false;
}
