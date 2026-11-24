import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:jplayer/src/data/backend/subsonic/spoken_audio_service.dart';
import 'package:jplayer/src/data/backend/subsonic/spoken_discovery_client.dart';
import 'package:jplayer/src/domain/models/models.dart';
import 'package:jplayer/src/domain/providers/playback_provider.dart';
import 'package:jplayer/src/domain/providers/seed_radio_provider.dart';
import 'package:jplayer/src/domain/providers/spoken_audio_provider.dart';
import 'package:jplayer/src/providers/image_service_provider.dart';
import 'spoken_connection_dialog.dart';
import 'spoken_discovery_view.dart';

class SpokenAudioHub extends ConsumerStatefulWidget {
  const SpokenAudioHub({required this.category, super.key});
  final SpokenCategory category;
  @override
  ConsumerState<SpokenAudioHub> createState() => _SpokenAudioHubState();
}

class _SpokenAudioHubState extends ConsumerState<SpokenAudioHub> {
  String? _show, _title, _error;
  LibraryItem? _folder;
  Future<List<LibraryItem>>? _contents;
  String _filter = '';
  bool _busy = false, _discover = false;
  Timer? _poll;
  final _pending = <String>{};
  bool get _books => widget.category == SpokenCategory.audiobooks;

  void _resetBrowse() {
    _poll?.cancel();
    _poll = null;
    _pending.clear();
    _show = null;
    _title = null;
    _folder = null;
    _contents = null;
    _filter = '';
    _error = null;
  }

  @override
  void didUpdateWidget(SpokenAudioHub oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.category != oldWidget.category) {
      _resetBrowse();
      _discover = false;
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _connect() async {
    final input = await showDialog<SpokenConnectionInput>(
      context: context,
      builder: (_) => SpokenConnectionDialog(
        profile: ref.read(spokenAudioSettingsProvider).valueOrNull,
      ),
    );
    if (input == null || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(spokenAudioSettingsProvider.notifier)
          .connect(
            url: input.url,
            username: input.username,
            password: input.password,
          );
    } on Object catch (error) {
      debugPrint('[Spoken] connection failed (${error.runtimeType})');
      if (mounted)
        setState(() => _error = SpokenDiscoveryClient.errorMessage(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _refresh() {
    ref.invalidate(podcastShowsProvider);
    ref.invalidate(bookFeedShowsProvider);
    ref.invalidate(audiobookRootsProvider);
    if (_show != null)
      ref.invalidate(spokenEpisodeEntriesProvider((_show!, _books)));
    if (_folder != null)
      setState(
        () => _contents = ref
            .read(spokenAudioServiceProvider)!
            .directory(_folder!.id),
      );
  }

  Future<void> _play(LibraryItem song, List<LibraryItem> siblings) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final position = await ref
          .read(spokenAudioServiceProvider)!
          .resumePosition(song.id);
      if (!mounted) return;
      ref.read(seedRadioProvider.notifier).stop();
      await ref
          .read(playbackProvider.notifier)
          .play(
            song,
            siblings.where((s) => s.kind == ItemKind.song).toList(),
            _folder ?? song,
            sourceId: _folder?.id ?? 'spoken:${widget.category.name}:$_show',
            initialPosition: position,
            reshuffle: false,
          );
    } on Object {
      if (mounted)
        setState(
          () => _error =
              'Could not load this audio or its saved position. Please retry.',
        );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _download(SpokenEpisode episode) async {
    setState(() {
      _pending.add(episode.id);
      _error = null;
    });
    try {
      await ref.read(spokenAudioServiceProvider)!.downloadEpisode(episode.id);
      if (!mounted) return;
      _refresh();
      _ensurePoll();
    } on Object {
      if (mounted)
        setState(() {
          _pending.remove(episode.id);
          _error =
              'The server could not start this download. Check podcast permissions and retry.';
        });
    }
  }

  void _ensurePoll() {
    if (_poll?.isActive == true) return;
    _poll = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted || _show == null) {
        _poll?.cancel();
        return;
      }
      ref.invalidate(spokenEpisodeEntriesProvider((_show!, _books)));
    });
  }

  Widget _message(String text) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 20),
    child: Text(text),
  );
  Widget _cover(LibraryItem item) => ClipRRect(
    borderRadius: BorderRadius.circular(8),
    child: Image(
      image: ref.read(imageServiceProvider).itemImage(item),
      fit: BoxFit.cover,
      width: 56,
      height: 56,
      errorBuilder: (_, _, _) =>
          const SizedBox(width: 56, height: 56, child: Icon(Icons.headphones)),
    ),
  );

  Widget _items(List<LibraryItem> all) {
    final visible = all
        .where(
          (s) => '${s.name} ${s.artistLabel}'.toLowerCase().contains(
            _filter.toLowerCase(),
          ),
        )
        .toList();
    if (all.isEmpty)
      return _message(
        _books
            ? 'No imported audiobook files yet. Use Discover to add a book or request a download.'
            : 'No downloaded audio yet.',
      );
    if (visible.isEmpty) return _message('No matching titles.');
    return Column(
      children: [
        for (final item in visible)
          ListTile(
            contentPadding: const EdgeInsets.symmetric(vertical: 6),
            leading: _cover(item),
            title: Text(item.name),
            subtitle: Text(item.artistLabel),
            trailing: Icon(
              item.kind == ItemKind.album
                  ? Icons.chevron_right
                  : Icons.play_arrow,
            ),
            onTap: _busy
                ? null
                : () {
                    if (item.kind == ItemKind.album) {
                      setState(() {
                        _folder = item;
                        _title = item.name;
                        _filter = '';
                        _contents = ref
                            .read(spokenAudioServiceProvider)!
                            .directory(item.id);
                      });
                    } else {
                      unawaited(_play(item, all));
                    }
                  },
          ),
      ],
    );
  }

  Widget _shows(List<PodcastShow> shows) => Column(
    children: [
      for (final show in shows)
        if (show.title.toLowerCase().contains(_filter.toLowerCase()))
          ListTile(
            contentPadding: const EdgeInsets.symmetric(vertical: 6),
            leading: _cover(
              LibraryItem(
                id: 'spoken:${_books ? 'book' : 'podcast'}:show-${show.id}',
                name: show.title,
                kind: ItemKind.album,
                images: ImageRefs(primary: show.coverId),
                externalIds: {
                  'spokenCategory': _books ? 'book' : 'podcast',
                  if (show.coverId != null) 'spokenCoverId': show.coverId!,
                },
              ),
            ),
            title: Text(show.title),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => setState(() {
              _show = show.id;
              _title = show.title;
              _filter = '';
            }),
          ),
    ],
  );

  Widget _episodes(List<SpokenEpisode> entries) {
    final playable = [
      for (final entry in entries)
        if (entry.playable != null) entry.playable!,
    ];
    _pending.removeWhere(
      (id) => entries.any(
        (e) => e.id == id && (e.playable != null || e.status == 'error'),
      ),
    );
    final downloading =
        entries.any((e) => e.status == 'downloading') || _pending.isNotEmpty;
    if (downloading) {
      _ensurePoll();
    } else {
      _poll?.cancel();
      _poll = null;
    }
    if (entries.isEmpty)
      return _message('The feed is still loading. Try Refresh shortly.');
    final visible = entries
        .where((e) => e.title.toLowerCase().contains(_filter.toLowerCase()))
        .toList();
    return Column(
      children: [
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 10),
          child: Text(
            'Download individual episodes or chapters. Only completed audio is queued for playback.',
          ),
        ),
        for (final entry in visible)
          ListTile(
            contentPadding: const EdgeInsets.symmetric(vertical: 6),
            title: Text(entry.title),
            leading: entry.playable == null
                ? const SizedBox(
                    width: 56,
                    height: 56,
                    child: Icon(Icons.headphones),
                  )
                : _cover(entry.playable!),
            subtitle: Text(
              entry.playable != null
                  ? 'Ready to play'
                  : _pending.contains(entry.id) || entry.status == 'downloading'
                  ? 'Downloading…'
                  : entry.status == 'error'
                  ? 'Download failed—tap to retry'
                  : 'Available to download',
            ),
            trailing: entry.playable != null
                ? const Icon(Icons.play_arrow)
                : _pending.contains(entry.id) || entry.status == 'downloading'
                ? const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.download_outlined),
            onTap: entry.playable != null
                ? () => unawaited(_play(entry.playable!, playable))
                : _pending.contains(entry.id) || entry.status == 'downloading'
                ? null
                : () => unawaited(_download(entry)),
          ),
      ],
    );
  }

  Widget _library() {
    if (_folder != null)
      return FutureBuilder<List<LibraryItem>>(
        future: _contents,
        builder: (_, snapshot) => snapshot.hasError
            ? _message('Could not load this folder. Try refresh.')
            : !snapshot.hasData
            ? const CircularProgressIndicator()
            : _items(snapshot.data!),
      );
    if (_show != null)
      return ref
          .watch(spokenEpisodeEntriesProvider((_show!, _books)))
          .when(
            data: _episodes,
            loading: () => const CircularProgressIndicator(),
            error: (_, _) => _message('Could not load episodes. Try refresh.'),
          );
    if (_books)
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ref
              .watch(bookFeedShowsProvider)
              .when(
                data: _shows,
                loading: () => const LinearProgressIndicator(),
                error: (_, _) => _message('Could not load subscribed books.'),
              ),
          ref
              .watch(audiobookRootsProvider)
              .when(
                data: _items,
                loading: () => const LinearProgressIndicator(),
                error: (_, _) =>
                    _message('Could not load imported audiobooks.'),
              ),
        ],
      );
    return ref
        .watch(podcastShowsProvider)
        .when(
          data: (shows) => shows.isEmpty
              ? _message(
                  'No subscriptions yet. Open Discover to find a podcast.',
                )
              : _shows(shows),
          loading: () => const CircularProgressIndicator(),
          error: (_, _) =>
              _message('Could not load podcasts. Check connection settings.'),
        );
  }

  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(spokenAudioSettingsProvider);
    final connected = profile.valueOrNull != null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 36),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (_show != null || _folder != null)
                IconButton(
                  tooltip: 'Back to titles',
                  onPressed: () => setState(_resetBrowse),
                  icon: const Icon(Icons.arrow_back),
                ),
              Expanded(
                child: Text(
                  _title ?? (_books ? 'Audiobooks' : 'Podcasts'),
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
              ),
              IconButton(
                tooltip: 'Refresh',
                onPressed: _refresh,
                icon: const Icon(Icons.refresh),
              ),
              IconButton(
                tooltip: 'Connection settings',
                onPressed: _busy ? null : _connect,
                icon: const Icon(Icons.settings_outlined),
              ),
            ],
          ),
          if (_busy || profile.isLoading) const LinearProgressIndicator(),
          if (_error != null) _message(_error!),
          if (profile.hasError)
            _message(
              'The saved spoken-audio connection could not be loaded. Reconnect in Connection settings.',
            ),
          if (!connected) ...[
            _message(
              'Your music, podcasts and audiobooks live in one app. Connect spoken audio once to get started.',
            ),
            FilledButton.icon(
              onPressed: _busy ? null : _connect,
              icon: const Icon(Icons.link),
              label: const Text('Connect spoken audio'),
            ),
          ] else ...[
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(
                    value: false,
                    icon: Icon(Icons.library_books_outlined),
                    label: Text('Library'),
                  ),
                  ButtonSegment(
                    value: true,
                    icon: Icon(Icons.search),
                    label: Text('Discover'),
                  ),
                ],
                selected: {_discover},
                onSelectionChanged: (value) => setState(() {
                  _resetBrowse();
                  _discover = value.single;
                }),
              ),
            ),
            if (_discover)
              SpokenDiscoveryView(
                category: widget.category,
                onAdded: () => setState(() {
                  _resetBrowse();
                  _discover = false;
                }),
              )
            else ...[
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: TextField(
                  onChanged: (value) => setState(() => _filter = value),
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    hintText: 'Filter your library',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              _library(),
            ],
          ],
        ],
      ),
    );
  }
}
