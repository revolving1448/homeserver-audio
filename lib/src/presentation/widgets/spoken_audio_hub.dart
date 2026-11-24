import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:jplayer/src/data/backend/subsonic/spoken_audio_service.dart';
import 'package:jplayer/src/domain/models/models.dart';
import 'package:jplayer/src/domain/providers/spoken_audio_provider.dart';
import 'package:jplayer/src/domain/providers/playback_provider.dart';
import 'package:jplayer/src/domain/providers/seed_radio_provider.dart';
import 'package:jplayer/src/providers/image_service_provider.dart';

class SpokenAudioHub extends ConsumerStatefulWidget {
  const SpokenAudioHub({required this.category, super.key});
  final SpokenCategory category;
  @override
  ConsumerState<SpokenAudioHub> createState() => _SpokenAudioHubState();
}

class _SpokenAudioHubState extends ConsumerState<SpokenAudioHub> {
  String? _show;
  String? _title;
  LibraryItem? _folder;
  Future<List<LibraryItem>>? _contents;
  String _filter = '';
  bool _busy = false;
  @override
  void didUpdateWidget(SpokenAudioHub oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.category != oldWidget.category) {
      _show = null;
      _folder = null;
      _contents = null;
      _title = null;
      _filter = '';
    }
  }

  Future<void> _connect() async {
    final old = ref.read(spokenAudioSettingsProvider).valueOrNull;
    final url = TextEditingController(
      text: old?.url ?? '',
    );
    final user = TextEditingController(text: old?.username ?? '');
    final password = TextEditingController();
    try {
      final save = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Connect podcasts & audiobooks'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Connect once. Music keeps using your current account.',
                ),
                TextField(
                  controller: url,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    labelText: 'Spoken audio server',
                  ),
                ),
                TextField(
                  controller: user,
                  autocorrect: false,
                  decoration: const InputDecoration(labelText: 'Username'),
                ),
                TextField(
                  controller: password,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(labelText: 'Password'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Connect'),
            ),
          ],
        ),
      );
      if (save != true || !mounted) return;
      setState(() => _busy = true);
      await ref
          .read(spokenAudioSettingsProvider.notifier)
          .connect(url: url.text, username: user.text, password: password.text);
    } on Object {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Could not connect. Check the address, login and Tailscale.',
            ),
          ),
        );
    } finally {
      url.dispose();
      user.dispose();
      password.dispose();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _play(LibraryItem song, List<LibraryItem> siblings) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final service = ref.read(spokenAudioServiceProvider)!;
      final position = await service.resumePosition(song.id);
      ref.read(seedRadioProvider.notifier).stop();
      final playable = siblings.where((s) => s.kind == ItemKind.song).toList();
      await ref
          .read(playbackProvider.notifier)
          .play(
            song,
            playable,
            _folder ?? song,
            sourceId: _folder?.id ?? 'spoken:${widget.category.name}:$_show',
            initialPosition: position,
            reshuffle: false,
          );
    } on Object {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Could not load this audio or its saved position. Please retry.',
            ),
          ),
        );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _back() => setState(() {
    _show = null;
    _folder = null;
    _title = null;
    _contents = null;
  });
  Widget _message(String text) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 24),
    child: Text(text),
  );
  Widget _cover(LibraryItem song) => ClipRRect(
    borderRadius: BorderRadius.circular(8),
    child: Image(
      image: ref.read(imageServiceProvider).itemImage(song),
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
        widget.category == SpokenCategory.podcasts
            ? 'No downloaded episodes yet. Download an episode on your server, then refresh. Feed-only entries are not playable.'
            : 'No audiobooks here yet. Add an Audiobooks library folder on the spoken audio server.',
      );
    if (visible.isEmpty) return _message('No matching titles.');
    return Column(
      children: [
        for (final song in visible)
          ListTile(
            contentPadding: const EdgeInsets.symmetric(vertical: 6),
            leading: _cover(song),
            title: Text(song.name),
            subtitle: Text(song.artistLabel),
            trailing: Icon(
              song.kind == ItemKind.album
                  ? Icons.chevron_right
                  : Icons.play_arrow,
            ),
            onTap: _busy
                ? null
                : () {
                    if (song.kind == ItemKind.album) {
                      setState(() {
                        _folder = song;
                        _title = song.name;
                        _contents = ref
                            .read(spokenAudioServiceProvider)!
                            .directory(song.id);
                      });
                    } else {
                      unawaited(_play(song, all));
                    }
                  },
          ),
      ],
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
                  onPressed: _back,
                  tooltip: 'Back to titles',
                  icon: const Icon(Icons.arrow_back),
                ),
              Expanded(
                child: Text(
                  _title ??
                      (widget.category == SpokenCategory.podcasts
                          ? 'Podcasts'
                          : 'Audiobooks'),
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
              ),
              IconButton(
                tooltip: 'Refresh',
                onPressed: () {
                  ref.invalidate(podcastShowsProvider);
                  ref.invalidate(audiobookRootsProvider);
                  if (_show != null)
                    ref.invalidate(podcastEpisodesProvider(_show!));
                  if (_folder != null)
                    setState(
                      () => _contents = ref
                          .read(spokenAudioServiceProvider)!
                          .directory(_folder!.id),
                    );
                },
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
              child: TextField(
                onChanged: (value) => setState(() => _filter = value),
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: 'Search these titles',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            if (_folder != null)
              FutureBuilder<List<LibraryItem>>(
                future: _contents,
                builder: (_, snapshot) => snapshot.hasError
                    ? _message('Could not load this folder. Try refresh.')
                    : !snapshot.hasData
                    ? const CircularProgressIndicator()
                    : _items(snapshot.data!),
              )
            else if (widget.category == SpokenCategory.audiobooks)
              ref
                  .watch(audiobookRootsProvider)
                  .when(
                    data: _items,
                    loading: () => const CircularProgressIndicator(),
                    error: (_, _) => _message(
                      'Could not load audiobooks. Check the connection.',
                    ),
                  )
            else if (_show != null)
              ref
                  .watch(podcastEpisodesProvider(_show!))
                  .when(
                    data: _items,
                    loading: () => const CircularProgressIndicator(),
                    error: (_, _) =>
                        _message('Could not load episodes. Try refresh.'),
                  )
            else
              ref
                  .watch(podcastShowsProvider)
                  .when(
                    data: (shows) => shows.isEmpty
                        ? _message(
                            'No podcast subscriptions yet. Add a feed on your server, then refresh.',
                          )
                        : Column(
                            children: [
                              for (final show in shows)
                                if (show.title.toLowerCase().contains(
                                  _filter.toLowerCase(),
                                ))
                                  ListTile(
                                    leading: _cover(
                                      LibraryItem(
                                        id: 'spoken:podcast:show-${show.id}',
                                        name: show.title,
                                        kind: ItemKind.album,
                                        images: ImageRefs(
                                          primary: show.coverId,
                                        ),
                                        externalIds: {
                                          'spokenCategory': 'podcast',
                                          if (show.coverId != null)
                                            'spokenCoverId': show.coverId!,
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
                          ),
                    loading: () => const CircularProgressIndicator(),
                    error: (_, _) => _message(
                      'Could not load podcasts. Check the connection.',
                    ),
                  ),
          ],
        ],
      ),
    );
  }
}
