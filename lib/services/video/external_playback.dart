import '../../models/torrent_models.dart';
import '../streaming/streaming_service.dart';
import 'desktop_video.dart';
import 'external_video_relay.dart';

/// Owns the native Range server until the user stops external playback.
/// Delivery to an app is not treated as first-frame or watch-position evidence.
class ExternalPlayback {
  ExternalPlayback(this.service, this.desktop, {ExternalVideoRelay? relay})
    : _relay = relay ?? ExternalVideoRelay();
  final StreamingService service;
  final DesktopVideo desktop;
  final ExternalVideoRelay _relay;
  int? _session;
  bool _closed = false;
  Future<void> start(TorrentSource source, ExternalVideoPlayer player) async {
    if (_closed || _session != null) {
      throw StateError(
        'This external playback session is no longer available.',
      );
    }
    final token = service.beginSession(source);
    _session = token.id;
    try {
      await service.start(source, claimed: token);
      if (_closed || service.state.sessionId != token.id) return;
      final state = service.state;
      if (state.phase == StreamingPhase.error ||
          state.phase == StreamingPhase.unsupported ||
          state.playback == null) {
        throw StateError(state.message ?? 'The source could not be prepared.');
      }
      var uri = state.playback!.uri;
      if (source.inputType == TorrentInputType.directUrl &&
          source.headers.isNotEmpty &&
          uri.scheme != 'file') {
        uri = await _relay.start(uri, source.headers);
      }
      if (_closed || service.state.sessionId != token.id) {
        await _relay.close();
        return;
      }
      await desktop.open(uri, player);
      if (!_closed && service.state.sessionId == token.id) {
        service.externalPlayerOpened();
      }
    } catch (_) {
      await close();
      rethrow;
    }
  }

  Future<void> close() async {
    _closed = true;
    await _relay.close();
    if (_session != null && service.state.sessionId == _session) {
      await service.stop();
    }
  }
}
