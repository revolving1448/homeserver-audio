import 'package:flutter_test/flutter_test.dart';
import 'package:jplayer/src/data/backend/subsonic/linked_subsonic_client.dart';
import 'package:jplayer/src/data/backend/subsonic/spoken_audio_service.dart';
import 'subsonic_test_support.dart';

void main() {
  setUpAll(registerSubsonicFallbacks);
  late SubsonicFakeServer music, spoken;
  late LinkedSubsonicClient client;
  setUp(() {
    music = SubsonicFakeServer();
    spoken = SubsonicFakeServer();
    client = LinkedSubsonicClient(
      dio: music.dio,
      baseUrl: 'http://music.test',
      userId: 'listener',
      token: 'fixture:salt',
      deviceId: 'test',
      spoken: SpokenAudioService(
        const SpokenProfile(
          url: 'http://spoken.test',
          username: 'reader',
          token: 'fixture:salt',
        ),
        dio: spoken.dio,
      ),
    );
  });
  test(
    'same numeric media ID routes favourites and ratings to correct server',
    () async {
      music.ok('star', {});
      spoken.ok('star', {});
      spoken.ok('setRating', {});
      await client.setFavorite('10', favorite: true);
      await client.setFavorite('spoken:book:10', favorite: true);
      await client.setRating('spoken:book:10', 9);
      expect(music.calls('star').single.queryParameters['id'], '10');
      expect(spoken.calls('star').single.queryParameters['id'], '10');
      expect(spoken.calls('setRating').single.queryParameters['rating'], '5');
      expect(music.calls('setRating'), isEmpty);
    },
  );
  test(
    'spoken media never requests a music radio or music playlist mutation',
    () async {
      expect(await client.getInstantMix('spoken:podcast:10'), isEmpty);
      expect(
        () => client.addPlaylistItems(
          playlistId: 'music-list',
          itemIds: ['spoken:podcast:10'],
        ),
        throwsUnsupportedError,
      );
      expect(music.requests, isEmpty);
      expect(spoken.requests, isEmpty);
    },
  );
}
