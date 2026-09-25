import 'package:test/test.dart';
import 'package:peerstream/services/history/watch_history_store.dart';

void main() {
  test('memory store round trip normalizes entries', () async {
    await writeWatchHistory(const []);
    expect(await readWatchHistory(), isEmpty);
  });
}
