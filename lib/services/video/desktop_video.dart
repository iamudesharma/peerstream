import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class ExternalVideoPlayer {
  const ExternalVideoPlayer(this.id, this.name);
  final String id;
  final String name;
}

/// Uses macOS Launch Services, without shell commands or URL scheme wrappers.
class DesktopVideo {
  const DesktopVideo();
  static const channel = MethodChannel('dev.peerstream/video');
  bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

  Future<List<ExternalVideoPlayer>> players() async {
    if (!supported) return const [];
    final rows = await channel.invokeListMethod<dynamic>('players') ?? [];
    return rows
        .map(
          (row) =>
              ExternalVideoPlayer(row['id'] as String, row['name'] as String),
        )
        .toList();
  }

  Future<ExternalVideoPlayer?> choosePlayer() async {
    if (!supported) {
      throw UnsupportedError('External players are available on macOS.');
    }
    final row = await channel.invokeMapMethod<String, dynamic>('choosePlayer');
    return row == null
        ? null
        : ExternalVideoPlayer(row['id'] as String, row['name'] as String);
  }

  Future<void> open(Uri uri, ExternalVideoPlayer player) async {
    if (!supported) {
      throw UnsupportedError('External players are available on macOS.');
    }
    if (!['http', 'https', 'file'].contains(uri.scheme)) {
      throw ArgumentError('A playable video URL or file is required.');
    }
    await channel.invokeMethod<void>('open', {
      'uri': uri.toString(),
      'application': player.id,
    });
  }

  Future<String?> exportFile(String path, String name) async {
    if (!supported) {
      throw UnsupportedError('Saving a copy is available on macOS.');
    }
    return channel.invokeMethod<String>('export', {'path': path, 'name': name});
  }
}
