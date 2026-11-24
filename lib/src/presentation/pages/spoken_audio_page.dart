import 'package:flutter/material.dart';
import 'package:jplayer/src/data/backend/subsonic/spoken_audio_service.dart';
import 'package:jplayer/src/presentation/widgets/scrollable_page_scaffold.dart';
import 'package:jplayer/src/presentation/widgets/spoken_audio_hub.dart';

/// One connection and player, with separate browsing for speech and music.
class SpokenAudioPage extends StatefulWidget {
  const SpokenAudioPage({required this.initialCategory, super.key});

  final SpokenCategory initialCategory;

  @override
  State<SpokenAudioPage> createState() => _SpokenAudioPageState();
}

class _SpokenAudioPageState extends State<SpokenAudioPage> {
  late SpokenCategory _category = widget.initialCategory;

  @override
  Widget build(BuildContext context) => ScrollablePageScaffold(
    useGradientBackground: true,
    slivers: [
      SliverToBoxAdapter(
        child: SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Wrap(
              spacing: 8,
              children: [
                for (final category in SpokenCategory.values)
                  ChoiceChip(
                    label: Text(
                      category == SpokenCategory.podcasts
                          ? 'Podcasts'
                          : 'Audiobooks',
                    ),
                    selected: _category == category,
                    onSelected: (_) => setState(() => _category = category),
                  ),
              ],
            ),
          ),
        ),
      ),
      SliverToBoxAdapter(child: SpokenAudioHub(category: _category)),
    ],
  );
}
