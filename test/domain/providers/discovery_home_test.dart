import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jplayer/src/domain/models/models.dart';
import 'package:jplayer/src/domain/providers/discovery_home_provider.dart';
import 'package:jplayer/src/domain/providers/home_sections_provider.dart';

void main() {
  test(
    'speed dial includes individual songs and albums and caps the visible grid',
    () async {
      final songs = List.generate(
        8,
        (i) => LibraryItem(id: 's$i', name: 'Song $i', kind: ItemKind.song),
      );
      final albums = List.generate(
        8,
        (i) => LibraryItem(id: 'a$i', name: 'Album $i', kind: ItemKind.album),
      );
      final container = ProviderContainer(
        overrides: [
          speedDialSongsProvider.overrideWith((_) async => songs),
          frequentlyPlayedAlbumsProvider.overrideWith((_) async => albums),
        ],
      );
      addTearDown(container.dispose);
      final shortcuts = await container.read(speedDialItemsProvider.future);
      expect(shortcuts, hasLength(9));
      expect(shortcuts.take(4), [songs[0], albums[0], songs[1], albums[1]]);
    },
  );
  test('real songs fill speed dial when no frequent albums exist', () async {
    const song = LibraryItem(id: 'polka', name: 'Polka', kind: ItemKind.song);
    final container = ProviderContainer(
      overrides: [
        speedDialSongsProvider.overrideWith((_) async => [song, song]),
        frequentlyPlayedAlbumsProvider.overrideWith((_) async => []),
      ],
    );
    addTearDown(container.dispose);
    expect(await container.read(speedDialItemsProvider.future), [song]);
  });
}
