import 'package:jplayer/src/core/audio/audio_container_mime.dart';
import 'package:jplayer/src/core/audio/stream_target_profile.dart';
import 'package:jplayer/src/data/backend/playback_report.dart';
import 'package:jplayer/src/data/backend/stream_source.dart';
import 'package:jplayer/src/data/backend/subsonic/subsonic_client.dart';
import 'package:jplayer/src/data/backend/subsonic/spoken_audio_service.dart';
import 'package:jplayer/src/domain/models/models.dart';

/// Music stays on Octo; explicit namespaced spoken items use the linked backend.
/// Numerically identical IDs on the two servers can never select the wrong file.
class LinkedSubsonicClient extends SubsonicClient {
  LinkedSubsonicClient({
    required super.dio,
    required super.baseUrl,
    required super.userId,
    required super.token,
    required super.deviceId,
    required this.spoken,
  });
  final SpokenAudioService? spoken;
  SpokenAudioService _spoken() =>
      spoken ?? (throw StateError('Connect podcasts and audiobooks first.'));
  final _lastBookmark = <String, DateTime>{};

  @override
  Future<void> setFavorite(String itemId, {required bool favorite}) async {
    if (!SpokenAudioService.owns(itemId)) {
      return super.setFavorite(itemId, favorite: favorite);
    }
    await _spoken().api.call(favorite ? 'star' : 'unstar', {
      'id': SpokenAudioService.rawId(itemId),
    });
  }

  @override
  Future<void> setRating(String itemId, int rating) async {
    if (!SpokenAudioService.owns(itemId))
      return super.setRating(itemId, rating);
    await _spoken().api.call('setRating', {
      'id': SpokenAudioService.rawId(itemId),
      'rating': rating.clamp(0, 5),
    });
  }

  @override
  Future<List<LibraryItem>> getInstantMix(String itemId, {int limit = 100}) =>
      SpokenAudioService.owns(itemId)
      ? Future.value(const [])
      : super.getInstantMix(itemId, limit: limit);

  @override
  Future<void> addPlaylistItems({
    required String playlistId,
    required List<String> itemIds,
  }) {
    if (itemIds.any(SpokenAudioService.owns)) {
      throw UnsupportedError(
        'Spoken audio cannot be added to a music-server playlist.',
      );
    }
    return super.addPlaylistItems(playlistId: playlistId, itemIds: itemIds);
  }

  @override
  Future<StreamSource> resolveStreamSource(
    LibraryItem song, {
    required String playSessionId,
    required StreamTargetProfile target,
    bool forceTranscode = false,
    Duration? startPosition,
  }) {
    if (!SpokenAudioService.owns(song.id))
      return super.resolveStreamSource(
        song,
        playSessionId: playSessionId,
        target: target,
        forceTranscode: forceTranscode,
        startPosition: startPosition,
      );
    final container = song.audioSources.firstOrNull?.container ?? 'mp3';
    return Future.value(
      StreamSource(
        uri: _spoken().stream(song.id),
        isHls: false,
        outputContainer: container,
        mimeType: mimeTypeForContainer(container),
        delivered: song.audioSources.firstOrNull,
      ),
    );
  }

  @override
  Uri? imageUri(
    LibraryItem item, {
    ImageKind kind = ImageKind.primary,
    int? size,
  }) => SpokenAudioService.owns(item.id)
      ? _spoken().cover(item, size: size)
      : super.imageUri(item, kind: kind, size: size);
  @override
  Future<LibraryItem> getItem(String itemId, {required ItemKind kind}) =>
      SpokenAudioService.owns(itemId)
      ? _spoken().song(itemId)
      : super.getItem(itemId, kind: kind);
  @override
  Future<List<LibraryItem>> getItemsByIds(List<String> ids) async {
    final music = await super.getItemsByIds([
      for (final id in ids)
        if (!SpokenAudioService.owns(id)) id,
    ]);
    final spokenItems = await Future.wait([
      for (final id in ids)
        if (SpokenAudioService.owns(id)) _spoken().song(id),
    ]);
    final byId = {
      for (final item in [...music, ...spokenItems]) item.id: item,
    };
    return [
      for (final id in ids)
        if (byId[id] case final item?) item,
    ];
  }

  @override
  Future<Lyrics?> getLyrics(String itemId) => SpokenAudioService.owns(itemId)
      ? Future.value(null)
      : super.getLyrics(itemId);
  Future<void> _bookmark(PlaybackReport report, {bool force = false}) async {
    final now = DateTime.now();
    final previous = _lastBookmark[report.itemId];
    if (!force &&
        previous != null &&
        now.difference(previous) < const Duration(seconds: 15))
      return;
    await _spoken().bookmark(report.itemId, report.position ?? Duration.zero);
    _lastBookmark[report.itemId] = now;
  }

  @override
  Future<void> reportPlaybackStarted(PlaybackReport report) =>
      SpokenAudioService.owns(report.itemId)
      ? Future.value()
      : super.reportPlaybackStarted(report);
  @override
  Future<void> reportPlaybackProgress(PlaybackReport report) =>
      SpokenAudioService.owns(report.itemId)
      ? _bookmark(report)
      : super.reportPlaybackProgress(report);
  @override
  Future<void> reportPlaybackSuspended(PlaybackReport report) =>
      SpokenAudioService.owns(report.itemId)
      ? _bookmark(report, force: true)
      : super.reportPlaybackSuspended(report);
  @override
  Future<void> reportPlaybackStopped(PlaybackReport report) =>
      SpokenAudioService.owns(report.itemId)
      ? _bookmark(report, force: true)
      : super.reportPlaybackStopped(report);
}
