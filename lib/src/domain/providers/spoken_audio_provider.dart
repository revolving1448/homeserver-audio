import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:jplayer/src/data/backend/subsonic/spoken_audio_service.dart';
import 'package:jplayer/src/data/backend/subsonic/spoken_discovery_client.dart';
import 'package:jplayer/src/data/backend/subsonic/subsonic_credentials.dart';
import 'package:jplayer/src/data/providers/secure_storage_provider.dart';
import 'package:jplayer/src/domain/providers/current_user_provider.dart';
import 'package:jplayer/src/providers/current_server_id_provider.dart';
import 'package:jplayer/src/domain/models/models.dart';

class SpokenAudioSettings extends AsyncNotifier<SpokenProfile?> {
  String get _storageKey =>
      'spoken_audio_${sha256.convert(utf8.encode('${ref.read(currentServerIdProvider)}|${ref.read(currentUserProvider)?.userId}'))}';
  @override
  Future<SpokenProfile?> build() async {
    final server = ref.watch(currentServerIdProvider);
    final user = ref.watch(currentUserProvider);
    if (server == null || user == null) return null;
    final saved = await ref.read(secureStorageProvider).read(key: _storageKey);
    return saved == null
        ? null
        : SpokenProfile.fromJson(jsonDecode(saved) as Map<String, dynamic>);
  }

  Future<void> connect({
    required String url,
    required String username,
    required String password,
  }) async {
    final uri = Uri.tryParse(url.trim());
    if (uri == null ||
        !{'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        username.trim().isEmpty ||
        password.isEmpty) {
      throw const FormatException(
        'Enter a server address, username and password.',
      );
    }
    final key = _storageKey;
    final profile = SpokenProfile(
      url: uri.toString().replaceAll(RegExp(r'/+$'), ''),
      username: username.trim(),
      token: SubsonicCredentials.fromPassword(
        username: username.trim(),
        password: password,
      ).encodedToken,
    );
    final probe = SpokenAudioService(profile);
    try {
      await probe.verify();
    } finally {
      probe.dio.close();
    }
    if (key != _storageKey) return;
    await ref
        .read(secureStorageProvider)
        .write(key: key, value: jsonEncode(profile.toJson()));
    state = AsyncData(profile);
  }

  Future<void> disconnect() async {
    await ref.read(secureStorageProvider).delete(key: _storageKey);
    state = const AsyncData(null);
  }
}

final spokenAudioSettingsProvider =
    AsyncNotifierProvider<SpokenAudioSettings, SpokenProfile?>(
      SpokenAudioSettings.new,
    );
final spokenAudioServiceProvider = Provider<SpokenAudioService?>((ref) {
  final profile = ref.watch(spokenAudioSettingsProvider).valueOrNull;
  if (profile == null) return null;
  final service = SpokenAudioService(profile);
  ref.onDispose(() => service.dio.close());
  return service;
});
final podcastShowsProvider = FutureProvider.autoDispose<List<PodcastShow>>(
  (ref) async =>
      (await ref.watch(spokenAudioServiceProvider)?.shows() ?? <PodcastShow>[])
          .where((show) => !show.isAudiobook)
          .toList(),
);
final bookFeedShowsProvider = FutureProvider.autoDispose<List<PodcastShow>>(
  (ref) async =>
      (await ref.watch(spokenAudioServiceProvider)?.shows() ?? <PodcastShow>[])
          .where((show) => show.isAudiobook)
          .toList(),
);
final spokenEpisodeEntriesProvider = FutureProvider.autoDispose
    .family<List<SpokenEpisode>, (String, bool)>(
      (ref, key) async =>
          ref
              .watch(spokenAudioServiceProvider)
              ?.episodeEntries(key.$1, audiobook: key.$2) ??
          Future.value([]),
    );
final spokenDiscoveryClientProvider = Provider<SpokenDiscoveryClient?>((ref) {
  final profile = ref.watch(spokenAudioSettingsProvider).valueOrNull;
  if (profile == null) return null;
  final client = SpokenDiscoveryClient(profile);
  ref.onDispose(() => client.dio.close());
  return client;
});
final podcastEpisodesProvider = FutureProvider.autoDispose
    .family<List<LibraryItem>, String>(
      (ref, id) async =>
          ref.watch(spokenAudioServiceProvider)?.episodes(id) ??
          Future.value(const []),
    );
final audiobookRootsProvider = FutureProvider.autoDispose<List<LibraryItem>>(
  (ref) async =>
      ref.watch(spokenAudioServiceProvider)?.bookRoots() ??
      Future.value(const []),
);
