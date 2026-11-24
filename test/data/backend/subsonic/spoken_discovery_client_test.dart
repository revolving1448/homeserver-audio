import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jplayer/src/data/backend/subsonic/spoken_audio_service.dart';
import 'package:jplayer/src/data/backend/subsonic/spoken_discovery_client.dart';
import 'package:mocktail/mocktail.dart';
import 'subsonic_test_support.dart';

void main() {
  setUpAll(registerSubsonicFallbacks);
  test(
    'discovery uses the spoken host, POST credentials and no query secrets',
    () async {
      final adapter = MockHttpClientAdapter();
      RequestOptions? captured;
      when(() => adapter.fetch(any(), any(), any())).thenAnswer((
        invocation,
      ) async {
        captured = invocation.positionalArguments.first as RequestOptions;
        return ResponseBody.fromString(
          jsonEncode({
            'results': [
              {
                'id': 'opaque',
                'kind': 'release',
                'title': 'A book',
                'source': 'Indexer',
                'bytes': 12345,
                'seeders': 4,
              },
            ],
            'warnings': [],
          }),
          200,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        );
      });
      final client = SpokenDiscoveryClient(
        const SpokenProfile(
          url: 'http://spoken.test:4040',
          username: 'reader',
          token: 'fixture:salt',
        ),
        dio: Dio()..httpClientAdapter = adapter,
      );
      final result = await client.search(SpokenCategory.audiobooks, 'A book');
      expect(captured!.uri, Uri.parse('http://spoken.test:4041/v1/search'));
      expect(captured!.method, 'POST');
      expect((captured!.data as Map)['auth'], {
        'u': 'reader',
        't': 'fixture',
        's': 'salt',
      });
      expect(result.results.single.isDownload, isTrue);
      expect(result.results.single.seeders, 4);
      client.dio.close();
    },
  );
  test('only real book feeds are classified as audiobooks', () {
    expect(
      const PodcastShow(
        id: '1',
        title: 'Book',
        feedUrl: 'https://librivox.org/rss/1',
      ).isAudiobook,
      isTrue,
    );
    expect(
      const PodcastShow(
        id: '2',
        title: 'Book',
        feedUrl: 'http://spoken.test:4041/feeds/books/abc.xml',
      ).isAudiobook,
      isTrue,
    );
    expect(
      const PodcastShow(
        id: '3',
        title: 'Not book',
        feedUrl: 'https://notlibrivox.org/podcast.xml',
      ).isAudiobook,
      isFalse,
    );
  });
  test(
    'error display never falls back to credential-bearing exception URLs',
    () {
      final error = DioException(
        requestOptions: RequestOptions(
          path: 'http://private/rest?password=fixture',
        ),
        type: DioExceptionType.connectionError,
      );
      expect(
        SpokenDiscoveryClient.errorMessage(error),
        isNot(contains('fixture')),
      );
    },
  );
  test(
    'book chapters sort naturally and unfinished entries remain unplayable',
    () async {
      final server = SubsonicFakeServer();
      server.ok('getPodcasts', {
        'podcasts': {
          'channel': [
            {
              'episode': [
                {'id': '9', 'title': '012 · Ending', 'status': 'skipped'},
                {
                  'id': '8',
                  'title': '002 · Middle',
                  'status': 'completed',
                  'streamId': '7',
                },
                {'id': '7', 'title': '001 · Start', 'status': 'downloading'},
              ],
            },
          ],
        },
      });
      final service = SpokenAudioService(
        const SpokenProfile(
          url: 'http://spoken.test',
          username: 'fixture',
          token: 'fixture:salt',
        ),
        dio: server.dio,
      );
      final entries = await service.episodeEntries('book', audiobook: true);
      expect(entries.map((x) => x.title), [
        '001 · Start',
        '002 · Middle',
        '012 · Ending',
      ]);
      expect(entries.first.playable, isNull);
      expect(entries[1].playable!.id, 'spoken:book:7');
      expect(entries.last.playable, isNull);
      service.dio.close();
    },
  );
}
