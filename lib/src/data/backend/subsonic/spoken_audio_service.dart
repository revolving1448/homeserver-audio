import 'package:dio/dio.dart';
import 'package:jplayer/src/data/api/subsonic/subsonic_api.dart';
import 'package:jplayer/src/data/backend/subsonic/subsonic_credentials.dart';
import 'package:jplayer/src/data/backend/subsonic/subsonic_envelope_interceptor.dart';
import 'package:jplayer/src/domain/models/models.dart';

enum SpokenCategory { podcasts, audiobooks }

class SpokenProfile {
  const SpokenProfile({
    required this.url,
    required this.username,
    required this.token,
  });
  final String url, username, token;
  Map<String, String> toJson() => {
    'url': url,
    'username': username,
    'token': token,
  };
  factory SpokenProfile.fromJson(Map<String, dynamic> j) => SpokenProfile(
    url: j['url'] as String,
    username: j['username'] as String,
    token: j['token'] as String,
  );
}

class PodcastShow {
  const PodcastShow({required this.id, required this.title, this.coverId});
  final String id, title;
  final String? coverId;
}

class SpokenAudioService {
  SpokenAudioService(SpokenProfile profile, {Dio? dio})
    : dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 25),
            ),
          ) {
    SubsonicEnvelopeInterceptor.install(this.dio);
    api = SubsonicApi(
      this.dio,
      baseUrl: profile.url,
      protocolVersion: '1.15.0',
      credentials: SubsonicCredentials.decode(
        username: profile.username,
        encodedToken: profile.token,
      ),
    );
  }
  final Dio dio;
  late final SubsonicApi api;
  static bool owns(String id) =>
      id.startsWith('spoken:podcast:') || id.startsWith('spoken:book:');
  static String rawId(String id) => id.split(':').skip(2).join(':');
  static String categoryOf(String id) =>
      id.startsWith('spoken:podcast:') ? 'podcast' : 'book';
  static List<Map<String, dynamic>> rows(Object? value) => value is List
      ? value
            .whereType<Map<Object?, Object?>>()
            .map((v) => Map<String, dynamic>.from(v))
            .toList()
      : const [];

  Future<void> verify() async {
    final body = await api.call('ping');
    if (body['status'] != 'ok') throw StateError('Spoken audio sign-in failed');
  }

  Future<List<PodcastShow>> shows() async {
    final body = await api.call('getPodcasts', {'includeEpisodes': false});
    return [
      for (final x in rows((body['podcasts'] as Map?)?['channel']))
        if (x['id'] != null)
          PodcastShow(
            id: '${x['id']}',
            title: '${x['title'] ?? 'Podcast'}',
            coverId: x['coverArt'] as String?,
          ),
    ];
  }

  Future<List<LibraryItem>> episodes(String channel) async {
    final body = await api.call('getPodcasts', {
      'id': channel,
      'includeEpisodes': true,
    });
    final channels = rows((body['podcasts'] as Map?)?['channel']);
    if (channels.isEmpty) return const [];
    // Feed-only entries have no streamId and cannot play yet. Never enqueue them.
    return [
      for (final x in rows(channels.first['episode']))
        if (x['status'] == 'completed' && x['streamId'] != null)
          item({...x, 'id': x['streamId']}, 'podcast'),
    ];
  }

  Future<List<LibraryItem>> bookRoots() async {
    final body = await api.call('getMusicFolders');
    final folders = rows((body['musicFolders'] as Map?)?['musicFolder']);
    final result = <LibraryItem>[];
    for (final f in folders) {
      if (!'${f['name']}'.toLowerCase().contains('audiobook')) continue;
      final indexes = await api.call('getIndexes', {'musicFolderId': f['id']});
      final root = indexes['indexes'] as Map?;
      for (final group in rows(root?['index'])) {
        for (final artist in rows(group['artist'])) {
          if (artist['id'] != null)
            result.add(
              item({...artist, 'title': artist['name'], 'isDir': true}, 'book'),
            );
        }
      }
      for (final child in rows(root?['child'])) {
        if (child['id'] != null) result.add(item(child, 'book'));
      }
    }
    return result;
  }

  Future<List<LibraryItem>> directory(String id) async {
    final body = await api.call('getMusicDirectory', {'id': rawId(id)});
    final children = [
      for (final x in rows((body['directory'] as Map?)?['child']))
        if (x['id'] != null) item(x, categoryOf(id)),
    ];
    if (categoryOf(id) == 'book') children.sort(LibraryItem.compareAlbumOrder);
    return children;
  }

  Future<LibraryItem> song(String id) async {
    final body = await api.call('getSong', {'id': rawId(id)});
    return item(Map<String, dynamic>.from(body['song'] as Map), categoryOf(id));
  }

  LibraryItem item(Map<String, dynamic> x, String category) {
    final raw = '${x['id']}';
    final cover = x['coverArt']?.toString();
    return LibraryItem(
      id: 'spoken:$category:$raw',
      name: '${x['title'] ?? x['name'] ?? 'Untitled'}',
      kind: x['isDir'] == true ? ItemKind.album : ItemKind.song,
      indexNumber: (x['track'] as num?)?.toInt() ?? 0,
      discNumber: (x['discNumber'] as num?)?.toInt(),
      duration: Duration(seconds: (x['duration'] as num?)?.toInt() ?? 0),
      albumName: x['album'] as String?,
      albumArtist: x['artist'] as String?,
      overview: x['description'] as String?,
      images: ImageRefs(primary: cover, primaryItemId: 'spoken:$category:$raw'),
      audioSources: [
        AudioSourceInfo(container: x['suffix'] as String? ?? 'mp3'),
      ],
      externalIds: {
        'spokenCategory': category,
        'spokenId': raw,
        if (cover != null) 'spokenCoverId': cover,
      },
    );
  }

  Uri stream(String id) =>
      api.uri('stream', {'id': rawId(id), 'format': 'raw'});
  Uri? cover(LibraryItem item, {int? size}) {
    final id = item.externalIds['spokenCoverId'];
    return id == null
        ? null
        : api.uri('getCoverArt', {'id': id, 'size': size ?? 420});
  }

  Future<void> bookmark(String id, Duration position) async {
    await api.call('createBookmark', {
      'id': rawId(id),
      'position': position.inMilliseconds,
    });
  }

  Future<Duration> resumePosition(String id) async {
    final body = await api.call('getBookmarks');
    for (final mark in rows((body['bookmarks'] as Map?)?['bookmark'])) {
      if ('${(mark['entry'] as Map?)?['id']}' == rawId(id)) {
        return Duration(milliseconds: (mark['position'] as num?)?.toInt() ?? 0);
      }
    }
    return Duration.zero;
  }
}
