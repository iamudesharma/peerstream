import 'package:flutter_test/flutter_test.dart';
import 'package:peerstream/models/media_item.dart';
import 'package:peerstream/models/torrent_models.dart';
import 'package:peerstream/services/torrent/source_policy.dart';

void main() {
  final policy = SourcePolicy.fromJsonString('''
    {
      "blockedDomains": ["blocked.example"],
      "blockedProviderNames": ["Bad Provider"],
      "blockedSourceIds": ["bad-id"]
    }
  ''');

  test('blocks torrent URL domains and their subdomains', () {
    expect(
      policy.check(_source(uri: 'https://cdn.blocked.example/movie.torrent')),
      isA<SourcePolicyViolation>(),
    );
  });

  test('blocks trackers embedded in magnet links', () {
    expect(
      policy.check(
        _source(
          uri: 'magnet:?xt=urn:btih:test&tr=https%3A%2F%2Fblocked.example%2Fannounce',
          inputType: TorrentInputType.magnet,
        ),
      ),
      isA<SourcePolicyViolation>(),
    );
  });

  test('blocks provider names and source IDs case-insensitively', () {
    expect(policy.check(_source(provider: 'BAD PROVIDER')), isNotNull);
    expect(policy.check(_source(id: 'BAD-ID')), isNotNull);
  });

  test('allows the curated WebTorrent demo host', () {
    expect(
      policy.check(_source(uri: 'https://webtorrent.io/torrents/demo.torrent')),
      isNull,
    );
  });

  test('blocks a representative real denylisted torrent index', () {
    final realWorldPolicy = SourcePolicy.fromJsonString('''
      {"blockedDomains": ["1337x.to"]}
    ''');
    expect(
      realWorldPolicy.check(
        _source(uri: 'https://cdn.1337x.to/example.torrent'),
      ),
      isA<SourcePolicyViolation>(),
    );
  });
}

TorrentSource _source({
  String id = 'good-id',
  String provider = 'Legal Provider',
  String uri = 'https://legal.example/movie.torrent',
  TorrentInputType inputType = TorrentInputType.torrentUrl,
}) {
  return TorrentSource(
    id: id,
    content: const MediaRef(id: 1, type: MediaType.movie),
    name: 'Test source',
    uri: Uri.parse(uri),
    inputType: inputType,
    providerName: provider,
    attribution: 'Test',
    license: 'CC BY 3.0',
    provenanceUrl: Uri.parse('https://legal.example'),
  );
}
