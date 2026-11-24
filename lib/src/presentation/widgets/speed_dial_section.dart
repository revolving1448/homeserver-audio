import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:jplayer/src/domain/models/models.dart';
import 'package:jplayer/src/domain/providers/seed_radio_provider.dart';
import 'package:jplayer/src/providers/image_service_provider.dart';
import 'package:jplayer/src/presentation/widgets/context_menu.dart';

class SpeedDialSection extends ConsumerWidget {
  const SpeedDialSection({
    required this.items,
    this.horizontalPadding = 16,
    super.key,
  });
  final AsyncValue<List<LibraryItem>> items;
  final double horizontalPadding;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final radio = ref.watch(seedRadioProvider);
    return Padding(
      padding: EdgeInsets.fromLTRB(horizontalPadding, 4, horizontalPadding, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Speed dial', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 16),
          items.when(
            loading: () => const LinearProgressIndicator(),
            error: (_, _) => const Text(
              'Your speed dial could not load. Pull down to refresh.',
            ),
            data: (songs) => songs.isEmpty
                ? const Text(
                    'Your regular listens will appear here as you play music.',
                  )
                : LayoutBuilder(
                    builder: (context, bounds) {
                      final columns = bounds.maxWidth >= 800 ? 6 : 3;
                      return GridView.builder(
                        padding: EdgeInsets.zero,
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        itemCount: songs.length > 9 ? 9 : songs.length,
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: columns,
                          mainAxisSpacing: 6,
                          crossAxisSpacing: 6,
                        ),
                        itemBuilder: (context, index) {
                          final item = songs[index];
                          return Semantics(
                            button: true,
                            label: 'Start radio from ${item.name}',
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(12),
                              child: Material(
                                color: Theme.of(
                                  context,
                                ).colorScheme.surfaceContainerHighest,
                                child: InkWell(
                                  onLongPress: () => unawaited(
                                    showLongPressContextMenuSheet(
                                      context,
                                      actions: contextMenuActions(
                                        context,
                                        ref,
                                        item,
                                        scope: ContextMenuScope.browse,
                                      ),
                                    ),
                                  ),
                                  onTap: () => unawaited(
                                    ref
                                        .read(seedRadioProvider.notifier)
                                        .start(item),
                                  ),
                                  child: Stack(
                                    fit: StackFit.expand,
                                    children: [
                                      Image(
                                        image: ref
                                            .read(imageServiceProvider)
                                            .itemImage(item),
                                        fit: BoxFit.cover,
                                        errorBuilder: (_, _, _) => const Icon(
                                          Icons.music_note,
                                          size: 42,
                                        ),
                                      ),
                                      const DecoratedBox(
                                        decoration: BoxDecoration(
                                          gradient: LinearGradient(
                                            begin: Alignment.center,
                                            end: Alignment.bottomCenter,
                                            colors: [
                                              Colors.transparent,
                                              Colors.black87,
                                            ],
                                          ),
                                        ),
                                      ),
                                      Positioned(
                                        left: 8,
                                        right: 6,
                                        bottom: 8,
                                        child: Text(
                                          item.name,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ),
                                      if (radio.loading &&
                                          radio.seed?.id == item.id)
                                        const Center(
                                          child: CircularProgressIndicator(),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      );
                    },
                  ),
          ),
          if (radio.active || radio.message != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Row(
                children: [
                  const Icon(Icons.radio, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      radio.message ?? 'Radio from ${radio.seed!.name}',
                      maxLines: 2,
                    ),
                  ),
                  if (radio.active && radio.message != null)
                    IconButton(
                      tooltip: 'Retry recommendations',
                      onPressed: () => unawaited(
                        ref.read(seedRadioProvider.notifier).retry(),
                      ),
                      icon: const Icon(Icons.refresh),
                    ),
                  IconButton(
                    tooltip: 'Stop adding recommendations',
                    onPressed: ref.read(seedRadioProvider.notifier).stop,
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
