import '../../models/watch_progress.dart';

List<WatchEntry> _entries = const [];

Future<List<WatchEntry>> readWatchHistory() async => List.of(_entries);

Future<void> writeWatchHistory(List<WatchEntry> entries) async {
  _entries = normalizeWatchHistory(entries);
}
