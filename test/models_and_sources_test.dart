import 'package:flutter_test/flutter_test.dart';
import 'package:peerstream/models/media_item.dart';
import 'package:peerstream/models/torrent_models.dart';
import 'package:peerstream/services/torrent/torrent_engine.dart';
import 'package:peerstream/services/torrent/torrent_provider.dart';

void main() {
  test('parses TV title and date fields', () {
    final item = MediaItem.fromJson({
      'id': 42,
      'name': 'Example series',
      'overview': 'Summary',
      'first_air_date': '2026-01-02',
      'vote_average': 8,
      'genre_ids': [16, 18],
    }, MediaType.tv);
    expect(item.title, 'Example series');
    expect(item.releaseDate, '2026-01-02');
    expect(item.genreIds, [16, 18]);
  });

  test('legal provider maps only exact movie identities', () async {
    const provider = WebTorrentLegalDemoProvider();
    final sources = await provider.findSources(
      const MediaRef(id: 10378, type: MediaType.movie),
    );
    expect(sources.single.id, 'bbb-webtorrent');
    expect(sources.single.license, contains('Creative Commons'));
    expect(
      await provider.findSources(
        const MediaRef(id: 550, type: MediaType.movie),
      ),
      isEmpty,
    );
    expect(
      await provider.findSources(
        const MediaRef(id: 10378, type: MediaType.tv),
        seasonNumber: 1,
        episodeNumber: 1,
      ),
      isEmpty,
    );
  });

  test(
    'file selection uses hint, excludes samples, then falls back by size',
    () {
      const files = [
        TorrentFileEntry(
          index: 0,
          name: 'sample.mp4',
          size: 500,
          isStreamable: true,
        ),
        TorrentFileEntry(
          index: 1,
          name: 'Big Buck Bunny 1080p.mp4',
          size: 5000,
          isStreamable: true,
        ),
        TorrentFileEntry(
          index: 2,
          name: 'extras.mkv',
          size: 8000,
          isStreamable: true,
        ),
      ];
      expect(selectVideoFile(files, hint: 'big buck bunny').index, 1);
      expect(selectVideoFile(files).index, 2);
    },
  );

  test('file selection rejects torrents without streamable video', () {
    expect(
      () => selectVideoFile(const [
        TorrentFileEntry(
          index: 0,
          name: 'readme.txt',
          size: 100,
          isStreamable: false,
        ),
      ]),
      throwsStateError,
    );
  });
}
