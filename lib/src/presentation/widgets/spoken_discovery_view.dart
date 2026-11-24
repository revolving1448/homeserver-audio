import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:jplayer/src/data/backend/subsonic/spoken_audio_service.dart';
import 'package:jplayer/src/data/backend/subsonic/spoken_discovery_client.dart';
import 'package:jplayer/src/domain/providers/spoken_audio_provider.dart';

class SpokenDiscoveryView extends ConsumerStatefulWidget {
  const SpokenDiscoveryView({
    required this.category,
    required this.onAdded,
    super.key,
  });
  final SpokenCategory category;
  final VoidCallback onAdded;
  @override
  ConsumerState<SpokenDiscoveryView> createState() =>
      _SpokenDiscoveryViewState();
}

class _SpokenDiscoveryViewState extends ConsumerState<SpokenDiscoveryView> {
  final _query = TextEditingController();
  List<SpokenDiscoveryResult> _results = [];
  List<String> _warnings = [];
  List<Map<String, dynamic>> _jobs = [];
  String? _error;
  final _working = <String>{};
  final _imported = <String>{};
  Timer? _poll;
  int _generation = 0;
  bool _busy = false;
  bool _loadingJobs = false;

  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      if (mounted) {
        unawaited(_search());
        unawaited(_loadJobs());
      }
    });
  }

  @override
  void didUpdateWidget(SpokenDiscoveryView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.category != widget.category) {
      _generation++;
      _query.clear();
      _results = [];
      unawaited(_search());
    }
  }

  @override
  void dispose() {
    _generation++;
    _poll?.cancel();
    _query.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final generation = ++_generation;
    final client = ref.read(spokenDiscoveryClientProvider);
    if (client == null) return;
    setState(() {
      _busy = true;
      _error = null;
      _warnings = [];
    });
    try {
      final data = await client.search(widget.category, _query.text);
      if (!mounted || generation != _generation) return;
      setState(() {
        _results = data.results;
        _warnings = data.warnings;
      });
    } on Object catch (error) {
      if (mounted && generation == _generation)
        setState(() => _error = SpokenDiscoveryClient.errorMessage(error));
    } finally {
      if (mounted && generation == _generation) setState(() => _busy = false);
    }
  }

  Future<void> _loadJobs() async {
    if (_loadingJobs || !mounted) return;
    _loadingJobs = true;
    try {
      final client = ref.read(spokenDiscoveryClientProvider);
      if (client == null) return;
      final data = await client.call('jobs');
      if (!mounted) return;
      setState(
        () => _jobs = [
          for (final x in data['jobs'] as List? ?? const [])
            Map<String, dynamic>.from(x as Map),
        ],
      );
      _poll?.cancel();
      if (_jobs.any(
        (job) => ['downloading', 'importing'].contains(job['status']),
      )) {
        _poll = Timer(
          const Duration(seconds: 10),
          () => unawaited(_loadJobs()),
        );
      }
      for (final job in _jobs) {
        if (job['status'] == 'imported' && _imported.add(job['id'] as String)) {
          ref.invalidate(audiobookRootsProvider);
        }
      }
    } on Object {
      // Search/request errors are shown explicitly. A transient status refresh
      // must not replace useful search results or start an investigation loop.
      if (mounted &&
          _jobs.any(
            (job) => ['downloading', 'importing'].contains(job['status']),
          )) {
        _poll?.cancel();
        _poll = Timer(
          const Duration(seconds: 15),
          () => unawaited(_loadJobs()),
        );
      }
    } finally {
      _loadingJobs = false;
    }
  }

  Future<void> _add(SpokenDiscoveryResult result) async {
    setState(() {
      _working.add(result.id);
      _error = null;
    });
    try {
      final client = ref.read(spokenDiscoveryClientProvider)!;
      await client.call(result.isDownload ? 'request' : 'subscribe', {
        'id': result.id,
      });
      if (!mounted) return;
      ref.invalidate(podcastShowsProvider);
      ref.invalidate(bookFeedShowsProvider);
      if (!mounted) return;
      if (result.isDownload) {
        await _loadJobs();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Added. Choose an episode or chapter to download.'),
          ),
        );
        widget.onAdded();
      }
    } on Object catch (error) {
      if (mounted)
        setState(() => _error = SpokenDiscoveryClient.errorMessage(error));
    } finally {
      if (mounted) setState(() => _working.remove(result.id));
    }
  }

  Future<void> _retry(String id) async {
    setState(() {
      _working.add(id);
      _error = null;
    });
    try {
      await ref.read(spokenDiscoveryClientProvider)!.call('retry', {'id': id});
      if (mounted) await _loadJobs();
    } on Object catch (error) {
      if (mounted)
        setState(() => _error = SpokenDiscoveryClient.errorMessage(error));
    } finally {
      if (mounted) setState(() => _working.remove(id));
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      TextField(
        controller: _query,
        onSubmitted: (_) => unawaited(_search()),
        decoration: InputDecoration(
          labelText: widget.category == SpokenCategory.podcasts
              ? 'Search podcasts outside your library'
              : 'Search audiobooks and your indexers',
          suffixIcon: IconButton(
            tooltip: 'Search',
            onPressed: _busy ? null : () => unawaited(_search()),
            icon: const Icon(Icons.search),
          ),
        ),
      ),
      if (_busy)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: LinearProgressIndicator(),
        ),
      if (_error != null)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Text(_error!),
        ),
      for (final warning in _warnings)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text(warning),
        ),
      if (!_busy && _error == null && _results.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 16),
          child: Text('No results. Try another title or author.'),
        ),
      for (final result in _results)
        ListTile(
          contentPadding: const EdgeInsets.symmetric(vertical: 6),
          leading: SizedBox(
            width: 56,
            height: 56,
            child: result.image == null
                ? const Icon(Icons.headphones)
                : Image.network(
                    result.image!,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => const Icon(Icons.headphones),
                  ),
          ),
          title: Text(result.title),
          subtitle: Text(
            [
              if (result.author.isNotEmpty) result.author,
              result.source,
              if (result.isDownload)
                '${(result.bytes / 1024 / 1024).round()} MB · ${result.seeders} seeders',
            ].join(' · '),
          ),
          trailing: _working.contains(result.id)
              ? const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : IconButton(
                  tooltip: result.isDownload
                      ? 'Download audiobook'
                      : 'Add to library',
                  icon: Icon(
                    result.isDownload ? Icons.download_outlined : Icons.add,
                  ),
                  onPressed: () => unawaited(_add(result)),
                ),
        ),
      if (widget.category == SpokenCategory.audiobooks && _jobs.isNotEmpty) ...[
        const Padding(
          padding: EdgeInsets.only(top: 24, bottom: 8),
          child: Text('Audiobook requests', style: TextStyle(fontSize: 20)),
        ),
        for (final job in _jobs.reversed)
          ListTile(
            title: Text('${job['title']}'),
            subtitle: Text(
              job['message'] as String? ??
                  '${job['status']} · ${((job['progress'] as num? ?? 0) * 100).round()}%',
            ),
            leading: Icon(
              job['status'] == 'imported'
                  ? Icons.library_books
                  : job['status'] == 'failed'
                  ? Icons.error_outline
                  : Icons.downloading,
            ),
            trailing: job['status'] == 'failed'
                ? TextButton(
                    onPressed: _working.contains(job['id'])
                        ? null
                        : () => unawaited(_retry(job['id'] as String)),
                    child: const Text('Retry'),
                  )
                : null,
          ),
      ],
    ],
  );
}
