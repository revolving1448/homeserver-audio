import 'package:flutter_test/flutter_test.dart';
import 'package:jplayer/src/data/backend/subsonic/spoken_audio_service.dart';
import 'subsonic_test_support.dart';

void main() {
  setUpAll(registerSubsonicFallbacks);
  late SubsonicFakeServer server;
  late SpokenAudioService service;
  setUp(() {
    server = SubsonicFakeServer();
    service = SpokenAudioService(
      const SpokenProfile(
        url: 'http://spoken.test:4040',
        username: 'reader',
        token: 'fixture:salt',
      ),
      dio: server.dio,
    );
  });
  test('Airsonic uses1.15 without changing music protocol', () async {
    server.ok('ping', {});
    await service.verify();
    expect(server.calls('ping').single.queryParameters['v'], '1.15.0');
  });
  test(
    'queues only downloaded episodes using streamId, not episodeId',
    () async {
      server.ok('getPodcasts', {
        'podcasts': {
          'channel': [
            {
              'id': '1',
              'episode': [
                {
                  'id': '633',
                  'streamId': '10',
                  'title': 'Downloaded',
                  'status': 'completed',
                },
                {'id': '634', 'title': 'Feed only', 'status': 'skipped'},
                {'id': '635', 'title': 'Downloading', 'status': 'downloading'},
              ],
            },
          ],
        },
      });
      final episodes = await service.episodes('1');
      expect(episodes.map((s) => s.id), ['spoken:podcast:10']);
      expect(service.stream(episodes.single.id).queryParameters['id'], '10');
    },
  );
  test('book and podcast IDs cannot collide with music or each other', () {
    final podcast = service.item({'id': '10', 'title': 'Episode'}, 'podcast');
    final book = service.item({'id': '10', 'title': 'Chapter'}, 'book');
    expect(podcast.id, isNot(book.id));
    expect(podcast.id, isNot('10'));
    expect(SpokenAudioService.rawId(book.id), '10');
  });
  test(
    'audiobook chapters follow disc and track numbers rather than feed order',
    () async {
      server.ok('getMusicDirectory', {
        'directory': {
          'child': [
            {'id': 'c3', 'title': 'Chapter 3', 'track': 1, 'discNumber': 2},
            {'id': 'c2', 'title': 'Chapter 2', 'track': 2, 'discNumber': 1},
            {'id': 'c1', 'title': 'Chapter 1', 'track': 1, 'discNumber': 1},
          ],
        },
      });
      final chapters = await service.directory('spoken:book:album');
      expect(chapters.map((s) => s.id), [
        'spoken:book:c1',
        'spoken:book:c2',
        'spoken:book:c3',
      ]);
    },
  );

  test('resume position is read from matching entry in milliseconds', () async {
    server.ok('getBookmarks', {
      'bookmarks': {
        'bookmark': [
          {
            'position': 123456,
            'entry': {'id': '10'},
          },
          {
            'position': 444,
            'entry': {'id': '11'},
          },
        ],
      },
    });
    expect(
      await service.resumePosition('spoken:book:10'),
      const Duration(milliseconds: 123456),
    );
    server.ok('createBookmark', {});
    await service.bookmark('spoken:book:10', const Duration(seconds: 73));
    expect(
      server.calls('createBookmark').single.queryParameters['position'],
      '73000',
    );
    expect(server.calls('createBookmark').single.queryParameters['id'], '10');
  });
}
