import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:jplayer/src/data/providers/media_server_client_provider.dart';
import 'package:jplayer/src/domain/models/models.dart';
import 'package:jplayer/src/domain/providers/playback_provider.dart';

class SeedRadioState {
  const SeedRadioState({this.seed, this.loading = false, this.message});
  final LibraryItem? seed;
  final bool loading;
  final String? message;
  bool get active => seed != null;
}

/// A radio owns only the queue it started. Manual replacement and newer seeds
/// cancel in-flight recommendations; manual play-next/append entries are kept.
class SeedRadioNotifier extends StateNotifier<SeedRadioState> {
  SeedRadioNotifier(this.ref) : super(const SeedRadioState()) {
    ref.listen<PlaybackState>(playbackProvider, (_, next) {
      if (_starting || !state.active) return;
      if (next.sourceId != _queueId) {
        stop();
        return;
      }
      final remaining = next.songs.length - (next.currentMediaIndex ?? 0) - 1;
      if (remaining <= 5 && !state.loading && state.message == null) {
        unawaited(_refill());
      }
    });
  }
  final Ref ref;
  int _generation = 0;
  String? _queueId;
  bool _starting = false;
  DateTime? _lastRefill;

  void stop() {
    _generation++;
    _queueId = null;
    _starting = false;
    _lastRefill = null;
    if (mounted) state = const SeedRadioState();
  }

  Future<void> start(LibraryItem item) async {
    final generation = ++_generation;
    _starting = true;
    _lastRefill = null;
    state = SeedRadioState(seed: item, loading: true);
    try {
      final client = ref.read(mediaServerClientProvider);
      LibraryItem seed = item;
      if (item.kind != ItemKind.song) {
        final songs = item.kind == ItemKind.album
            ? (await client.getSongs(item.id)).items
            : await client.getInstantMix(item.id, limit: 20);
        if (generation != _generation || !mounted) return;
        if (songs.isEmpty) {
          state = SeedRadioState(
            message: 'No playable songs found for ${item.name}.',
          );
          return;
        }
        seed = songs.first;
      }
      if (generation != _generation || !mounted) return;
      _queueId = 'seed-radio:$generation:${seed.id}';
      await ref
          .read(playbackProvider.notifier)
          .play(seed, [seed], item, sourceId: _queueId, reshuffle: false);
      if (generation != _generation || !mounted) return;
      state = SeedRadioState(seed: seed);
    } on Object {
      if (generation == _generation && mounted) {
        state = const SeedRadioState(
          message: 'Could not start this radio. Try again.',
        );
      }
    } finally {
      if (generation == _generation) _starting = false;
    }
    if (generation == _generation && state.active) await _refill();
  }

  Future<void> retry() async {
    if (!state.active || state.loading) return;
    state = SeedRadioState(seed: state.seed);
    _lastRefill = null;
    await _refill();
  }

  Future<void> _refill() async {
    if (!state.active || state.loading || _queueId == null) return;
    final now = DateTime.now();
    if (_lastRefill != null &&
        now.difference(_lastRefill!) < const Duration(seconds: 15))
      return;
    _lastRefill = now;
    final generation = _generation;
    final queueId = _queueId;
    final before = ref.read(playbackProvider);
    if (before.sourceId != queueId) return;
    final seed =
        before.songs.elementAtOrNull(before.currentMediaIndex ?? 0) ??
        state.seed!;
    state = SeedRadioState(seed: state.seed, loading: true);
    try {
      final candidates = await ref
          .read(mediaServerClientProvider)
          .getInstantMix(seed.id, limit: 30)
          .timeout(const Duration(seconds: 30));
      if (!mounted || generation != _generation) return;
      final current = ref.read(playbackProvider);
      if (current.sourceId != queueId) return;
      final ids = {for (final song in current.songs) song.id};
      final names = {for (final song in current.songs) _identity(song)};
      final fresh = [
        for (final song in candidates)
          if (song.kind == ItemKind.song &&
              song.id.trim().isNotEmpty &&
              song.name.trim().isNotEmpty &&
              !song.externalIds.containsKey('spokenCategory') &&
              ids.add(song.id) &&
              names.add(_identity(song)))
            song,
      ];
      if (fresh.isEmpty) {
        state = SeedRadioState(
          seed: state.seed,
          message:
              'No new recommendations right now. Your queued songs will keep playing.',
        );
        return;
      }
      final added = await ref
          .read(playbackProvider.notifier)
          .addAllToQueue(
            fresh,
            accept: () =>
                mounted &&
                generation == _generation &&
                ref.read(playbackProvider).sourceId == queueId,
          );
      if (mounted && generation == _generation) {
        state = SeedRadioState(
          seed: state.seed,
          message: added
              ? null
              : 'Recommendations could not be queued. Tap to retry.',
        );
      }
    } on Object {
      if (mounted && generation == _generation)
        state = SeedRadioState(
          seed: state.seed,
          message:
              'Radio could not refresh. Queued songs are still available. Tap to retry.',
        );
    }
  }

  String _identity(LibraryItem song) =>
      '${song.artistLabel.trim()}|${song.name.trim()}'.toLowerCase();
}

final seedRadioProvider =
    StateNotifierProvider<SeedRadioNotifier, SeedRadioState>(
      SeedRadioNotifier.new,
    );
