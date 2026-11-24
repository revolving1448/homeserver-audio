import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:jplayer/src/data/backend/media_server_client.dart';
import 'package:jplayer/src/data/providers/media_server_client_provider.dart';
import 'package:jplayer/src/domain/models/models.dart';
import 'package:jplayer/src/domain/providers/playback_provider.dart';
import 'package:jplayer/src/domain/providers/seed_radio_provider.dart';
import '../../provider_container.dart';

class _Client extends Mock implements MediaServerClient {}

class _Playback extends StateNotifier<PlaybackState>
    with Mock
    implements PlaybackNotifier {
  _Playback() : super(PlaybackState.initial());
  @override
  Future<void> play(
    LibraryItem song,
    List<LibraryItem> songs,
    LibraryItem album, {
    String? sourceId,
    Duration? initialPosition,
    bool autoPlay = true,
    bool reshuffle = true,
    bool keepStreamsOffline = false,
    bool resuming = false,
  }) async {
    state = state.copyWith(
      songs: songs,
      album: album,
      currentMediaIndex: 0,
      sourceId: sourceId,
      status: PlaybackStatus.playing,
    );
  }

  @override
  Future<bool> addAllToQueue(
    List<LibraryItem> songs, {
    LibraryItem? set,
    bool Function()? accept,
  }) async {
    if (accept != null && !accept()) return false;
    state = state.copyWith(songs: [...state.songs, ...songs]);
    return true;
  }

  void manual(LibraryItem song) =>
      state = state.copyWith(songs: [song], sourceId: 'manual');
  void insert(LibraryItem song) =>
      state = state.copyWith(songs: [...state.songs, song]);
}

LibraryItem song(String id) =>
    LibraryItem(id: id, name: id, kind: ItemKind.song);

void main() {
  late _Playback playback;
  late _Client client;
  late ProviderContainer container;
  setUp(() {
    playback = _Playback();
    client = _Client();
    container = createProviderContainer(
      overrides: [
        playbackProvider.overrideWith((_) => playback),
        mediaServerClientProvider.overrideWithValue(client),
      ],
    );
  });
  test(
    'starts seed before recommendations and preserves manual insertions',
    () async {
      final pending = Completer<List<LibraryItem>>();
      when(
        () => client.getInstantMix('seed', limit: 30),
      ).thenAnswer((_) => pending.future);
      final task = container
          .read(seedRadioProvider.notifier)
          .start(song('seed'));
      await Future<void>.delayed(Duration.zero);
      expect(playback.state.songs.map((s) => s.id), ['seed']);
      playback.insert(song('manual'));
      pending.complete([
        song('seed'),
        song('new'),
        song('new'),
        song(''),
        song(
          'spoken:podcast:7',
        ).copyWith(externalIds: {'spokenCategory': 'podcast'}),
      ]);
      await task;
      expect(playback.state.songs.map((s) => s.id), ['seed', 'manual', 'new']);
    },
  );
  test(
    'late radio response cannot replace a manually selected queue',
    () async {
      final pending = Completer<List<LibraryItem>>();
      when(
        () => client.getInstantMix('seed', limit: 30),
      ).thenAnswer((_) => pending.future);
      final task = container
          .read(seedRadioProvider.notifier)
          .start(song('seed'));
      await Future<void>.delayed(Duration.zero);
      playback.manual(song('other'));
      pending.complete([song('late')]);
      await task;
      expect(playback.state.songs.single.id, 'other');
      expect(container.read(seedRadioProvider).active, isFalse);
    },
  );
  test('empty radio answer stops retrying on position changes', () async {
    when(
      () => client.getInstantMix('seed', limit: 30),
    ).thenAnswer((_) async => [song('seed')]);
    await container.read(seedRadioProvider.notifier).start(song('seed'));
    for (var n = 1; n < 20; n++) {
      playback.state = playback.state.copyWith(position: Duration(seconds: n));
    }
    await Future<void>.delayed(Duration.zero);
    verify(() => client.getInstantMix('seed', limit: 30)).called(1);
    expect(container.read(seedRadioProvider).message, isNotNull);
    expect(playback.state.songs.single.id, 'seed');
  });
  test('new seed supersedes an older in-flight station', () async {
    final pending = Completer<List<LibraryItem>>();
    when(
      () => client.getInstantMix('first', limit: 30),
    ).thenAnswer((_) => pending.future);
    when(
      () => client.getInstantMix('second', limit: 30),
    ).thenAnswer((_) async => [song('new')]);
    final first = container
        .read(seedRadioProvider.notifier)
        .start(song('first'));
    await Future<void>.delayed(Duration.zero);
    await container.read(seedRadioProvider.notifier).start(song('second'));
    pending.complete([song('old')]);
    await first;
    expect(playback.state.songs.map((s) => s.id), ['second', 'new']);
  });
}
