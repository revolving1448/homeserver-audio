import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:jplayer/src/data/providers/play_history_database_provider.dart';
import 'package:jplayer/src/domain/models/models.dart';
import 'package:jplayer/src/domain/providers/current_user_provider.dart';
import 'package:jplayer/src/domain/providers/on_repeat_provider.dart';
import 'package:jplayer/src/domain/providers/home_sections_provider.dart';
import 'package:jplayer/src/data/providers/media_server_client_provider.dart';
import 'package:jplayer/src/data/backend/library_query.dart';

final speedDialSongsProvider = FutureProvider.autoDispose<List<LibraryItem>>((
  ref,
) async {
  if (ref.watch(currentUserProvider) == null) return const [];
  ref.watch(playHistoryChangedProvider);
  final history = ref.watch(playHistoryDatabaseProvider);
  final rows = await history.topPlayed(
    window: const Duration(days: 90),
    limit: 12,
  );
  if (rows.isEmpty) {
    // A new installation can still use the server's real play counts.
    final page = await ref
        .read(mediaServerClientProvider)
        .getAllSongs(
          const LibraryQuery(
            sort: ItemSort.playCount,
            direction: SortDirection.descending,
            filters: {ItemFilterFlag.played},
            limit: 12,
          ),
        );
    return page.items.where((song) => song.userData.playCount > 0).toList();
  }
  final stored = await history.playedSongsByIds([
    for (final r in rows) r.songId,
  ]);
  return [
    for (final r in rows)
      if (stored[r.songId] case final song?) song,
  ];
});

final forgottenFavouritesProvider =
    FutureProvider.autoDispose<List<LibraryItem>>((ref) async {
      if (ref.watch(currentUserProvider) == null) return const [];
      ref.watch(playHistoryChangedProvider);
      final history = ref.watch(playHistoryDatabaseProvider);
      final rows = await history.forgottenFavourites();
      final stored = await history.playedSongsByIds([
        for (final r in rows) r.songId,
      ]);
      return [
        for (final r in rows)
          if (stored[r.songId] case final song?) song,
      ];
    });

/// Mix real frequently played songs and albums into the home shortcut grid.
final speedDialItemsProvider = FutureProvider.autoDispose<List<LibraryItem>>((
  ref,
) async {
  final songsFuture = ref.watch(speedDialSongsProvider.future);
  final albumsFuture = ref.watch(frequentlyPlayedAlbumsProvider.future);
  final songs = await songsFuture;
  final albums = await albumsFuture;
  final result = <LibraryItem>[];
  final seen = <String>{};
  for (var i = 0; i < songs.length || i < albums.length; i++) {
    for (final item in [
      if (i < songs.length) songs[i],
      if (i < albums.length) albums[i],
    ]) {
      if (seen.add('${item.kind}:${item.id}')) result.add(item);
      if (result.length == 9) return result;
    }
  }
  return result;
});
