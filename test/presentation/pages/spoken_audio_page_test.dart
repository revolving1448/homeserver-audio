import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jplayer/src/data/backend/subsonic/spoken_audio_service.dart';
import 'package:jplayer/src/domain/providers/spoken_audio_provider.dart';
import 'package:jplayer/src/presentation/pages/spoken_audio_page.dart';
import '../../app_wrapper.dart';
import '../../provider_container.dart';

class _Disconnected extends SpokenAudioSettings {
  @override
  Future<SpokenProfile?> build() async => null;
}

void main() {
  for (final category in SpokenCategory.values) {
    testWidgets(
      'Spoken entry opens $category and switches without a server change',
      (tester) async {
        final container = createProviderContainer(
          overrides: [
            spokenAudioSettingsProvider.overrideWith(_Disconnected.new),
          ],
        );
        await tester.pumpWidget(
          createTestApp(
            providerContainer: container,
            home: SpokenAudioPage(initialCategory: category),
          ),
        );
        await tester.pumpAndSettle();
        ChoiceChip chip(String label) => tester.widget<ChoiceChip>(
          find.widgetWithText(ChoiceChip, label),
        );
        expect(chip('Podcasts').selected, category == SpokenCategory.podcasts);
        expect(
          chip('Audiobooks').selected,
          category == SpokenCategory.audiobooks,
        );
        expect(find.text('Connect spoken audio'), findsOneWidget);
        final other = category == SpokenCategory.podcasts
            ? 'Audiobooks'
            : 'Podcasts';
        await tester.tap(find.widgetWithText(ChoiceChip, other));
        await tester.pumpAndSettle();
        expect(chip(other).selected, isTrue);
        expect(find.text('Connect spoken audio'), findsOneWidget);
        expect(container.read(spokenAudioSettingsProvider).valueOrNull, isNull);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
