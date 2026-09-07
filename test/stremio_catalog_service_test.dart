import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peerstream/core/image_url.dart';
import 'package:peerstream/models/media_item.dart';
import 'package:peerstream/services/stremio/stremio_catalog_service.dart';

void main() {
  test('resolves TMDB paths and absolute Stremio URLs', () {
    expect(resolveImageUrl(null), isNull);
    expect(resolveImageUrl(''), isNull);
    expect(
      resolveImageUrl('/abc.jpg'),
      'https://image.tmdb.org/t/p/w342/abc.jpg',
    );
    expect(
      resolveImageUrl('abc.jpg', tmdbSize: 'w780'),
      'https://image.tmdb.org/t/p/w780/abc.jpg',
    );
    const absolute = 'https://images.justwatch.com/poster/1/s332/img';
    expect(resolveImageUrl(absolute), absolute);
  });

  test('maps Stremio movie meta to TMDB-compatible MediaItem', () {
    final item = MediaItem.fromStremio({
      'id': 'tt0120791',
      'imdb_id': 'tt0120791',
      'moviedb_id': 6435,
      'name': 'Practical Magic',
      'description': 'Two witch sisters...',
      'poster': 'https://images.justwatch.com/poster/11005490/s332/img',
      'background': 'https://images.metahub.space/background/medium/tt0120791/img',
      'released': '1998-10-16T00:00:00.000Z',
      'imdbRating': '6.4',
    }, MediaType.movie);

    expect(item.id, 6435);
    expect(item.type, MediaType.movie);
    expect(item.title, 'Practical Magic');
    expect(item.releaseDate, '1998-10-16');
    expect(item.rating, 6.4);
    expect(item.posterPath, contains('justwatch.com'));
    expect(item.backdropPath, contains('metahub.space'));
  });

  test('falls back to stable negative id without moviedb_id', () {
    final first = MediaItem.fromStremio({
      'id': 'tt9999999',
      'name': 'Unknown',
    }, MediaType.tv);
    final second = MediaItem.fromStremio({
      'id': 'tt9999999',
      'name': 'Unknown',
    }, MediaType.tv);
    expect(first.id, lessThan(0));
    expect(first.id, second.id);
  });

  test('orders USA platforms first and parses catalogs', () async {
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            if (options.uri.path.endsWith('manifest.json')) {
              handler.resolve(
                Response(
                  requestOptions: options,
                  data: {
                    'catalogs': [
                      {'id': 'atp', 'type': 'series', 'name': 'Apple TV+'},
                      {'id': 'nfx', 'type': 'movie', 'name': 'Netflix'},
                      {'id': 'zzz', 'type': 'movie', 'name': 'Other'},
                    ],
                  },
                ),
              );
              return;
            }
            handler.reject(
              DioException(requestOptions: options, message: 'unexpected'),
            );
          },
        ),
      );
    final service = StremioCatalogService(dio: dio);
    final catalogs = await service.catalogs();
    expect(catalogs.map((c) => c.id).toList(), ['nfx', 'atp', 'zzz']);
    expect(catalogs.first.title, 'Netflix Movies');
  });

  test('catalog remembers imdb ids and builds keyless details', () async {
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            final path = options.uri.path;
            if (path.endsWith('manifest.json')) {
              handler.resolve(
                Response(
                  requestOptions: options,
                  data: {
                    'catalogs': [
                      {'id': 'nfx', 'type': 'movie', 'name': 'Netflix'},
                    ],
                  },
                ),
              );
              return;
            }
            if (path.contains('/catalog/movie/nfx.json')) {
              handler.resolve(
                Response(
                  requestOptions: options,
                  data: {
                    'metas': [
                      {
                        'id': 'tt0120791',
                        'imdb_id': 'tt0120791',
                        'moviedb_id': 6435,
                        'name': 'Practical Magic',
                        'description': 'Overview',
                        'poster':
                            'https://images.justwatch.com/poster/1/s332/img',
                        'background':
                            'https://images.metahub.space/background/medium/tt0120791/img',
                        'released': '1998-10-16T00:00:00.000Z',
                        'imdbRating': '6.4',
                        'genres': ['Comedy'],
                        'runtime': '104 min',
                      },
                    ],
                  },
                ),
              );
              return;
            }
            handler.reject(
              DioException(requestOptions: options, message: 'unexpected $path'),
            );
          },
        ),
      );
    final service = StremioCatalogService(dio: dio);
    final items = await service.catalog(MediaType.movie, 'nfx');
    expect(items, hasLength(1));
    expect(items.first.id, 6435);

    // Keyless imdb lookup for stream addons without TMDB.
    expect(service.lookupImdbId(items.first.ref), 'tt0120791');

    // Details fallback from catalog cache when Cinemeta is unreachable
    // is covered implicitly: details() tries Cinemeta first, then cache.
    // Here Cinemeta would fail (no stub), so it should throw a friendly
    // StateError rather than a Dio error when nothing is cached... but since
    // we cached the row, details() returns the cached lightweight details.
    final details = await service.details(items.first.ref);
    expect(details.item.title, 'Practical Magic');
    expect(details.runtimeMinutes, 104);
    expect(details.genres, ['Comedy']);
  });

  test('parses Cinemeta meta seasons and runtime', () {
    expect(StremioCatalogService.parseRuntime('104 min'), 104);
    expect(StremioCatalogService.parseRuntime(90), 90);
    expect(
      StremioCatalogService.genresOf({
        'genres': ['Action', 'Comedy'],
      }),
      ['Action', 'Comedy'],
    );
    final seasons = StremioCatalogService.seasonsOf({
      'videos': [
        {'season': 1, 'episode': 1},
        {'season': 1, 'episode': 2},
        {'season': 2, 'episode': 1},
        {'season': 0, 'episode': 1},
      ],
    }, MediaType.tv);
    expect(seasons.map((s) => s.number), [1, 2]);
    expect(seasons.first.episodeCount, 2);
    expect(
      StremioCatalogService.seasonsOf({}, MediaType.movie),
      isEmpty,
    );
  });
}
