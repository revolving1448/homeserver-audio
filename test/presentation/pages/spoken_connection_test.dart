import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jplayer/src/data/backend/subsonic/spoken_audio_service.dart';
import 'package:jplayer/src/domain/providers/spoken_audio_provider.dart';
import 'package:jplayer/src/presentation/widgets/spoken_audio_hub.dart';
import '../../app_wrapper.dart';
import '../../provider_container.dart';

class _Connects extends SpokenAudioSettings {
  @override
  Future<SpokenProfile?> build() async => null;
  @override
  Future<void> connect({
    required String url,
    required String username,
    required String password,
  }) async {
    state = AsyncData(
      SpokenProfile(url: url, username: username, token: 'fixture:salt'),
    );
  }
}

class _Rejects extends _Connects {
  @override
  Future<void> connect({
    required String url,
    required String username,
    required String password,
  }) async {
    throw DioException.badResponse(
      statusCode: 401,
      requestOptions: RequestOptions(path: 'private'),
      response: Response(
        requestOptions: RequestOptions(path: 'private'),
        statusCode: 401,
      ),
    );
  }
}

void main() {
  for (final rejected in [false, true]) {
    testWidgets(
      'connection dialog ${rejected ? 'keeps errors visible' : 'switches to linked library without controller races'}',
      (tester) async {
        final container = createProviderContainer(
          overrides: [
            spokenAudioSettingsProvider.overrideWith(
              rejected ? _Rejects.new : _Connects.new,
            ),
            podcastShowsProvider.overrideWith((ref) async => []),
          ],
        );
        await tester.pumpWidget(
          createTestApp(
            providerContainer: container,
            home: const Scaffold(
              body: SingleChildScrollView(
                child: SpokenAudioHub(category: SpokenCategory.podcasts),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Connect spoken audio'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.widgetWithText(TextFormField, 'Spoken audio server'),
          'http://spoken.test:4040',
        );
        await tester.enterText(
          find.widgetWithText(TextFormField, 'Username'),
          'fixture',
        );
        await tester.enterText(
          find.widgetWithText(TextFormField, 'Password'),
          'fixture',
        );
        await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
        await tester.pumpAndSettle();
        if (rejected) {
          expect(
            find.textContaining('login or download permission was rejected'),
            findsOneWidget,
          );
          await tester.pump(const Duration(seconds: 8));
          expect(
            find.textContaining('login or download permission was rejected'),
            findsOneWidget,
          );
        } else {
          expect(find.text('Discover'), findsOneWidget);
          expect(find.text('Connect spoken audio'), findsNothing);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }
}
