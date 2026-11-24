import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:jplayer/src/core/cast/cast_runtime.dart';

// Real native decoder + foreground service, requiring neither account nor GMS.
Uint8List _silence() {
  const samples = 22050 * 3;
  final bytes = Uint8List(44 + samples * 2);
  final data = ByteData.sublistView(bytes);
  void text(int at, String value) =>
      bytes.setRange(at, at + value.length, value.codeUnits);
  text(0, 'RIFF');
  data.setUint32(4, bytes.length - 8, Endian.little);
  text(8, 'WAVE');
  text(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, 22050, Endian.little);
  data.setUint32(28, 44100, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  text(36, 'data');
  data.setUint32(40, samples * 2, Endian.little);
  return bytes;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'AOSP: Cast is optional; real audio advances with current metadata',
    (tester) async {
      await JustAudioBackground.init(
        androidNotificationChannelId: 'local.homeserver.audio.test',
        androidNotificationChannelName: 'Audio verification',
        androidNotificationIcon: 'drawable/ic_stat_music',
      );
      await initializeCast();
      // This test is intended for a stock AOSP image without Google Play services.
      expect(castSupported, isFalse);
      final directory = await Directory.systemTemp.createTemp(
        'homeserver-audio-',
      );
      final file = File('${directory.path}/test.wav');
      await file.writeAsBytes(_silence());
      final player = AudioPlayer();
      try {
        await player.setAudioSources([
          for (final title in ['First track', 'Second track'])
            AudioSource.file(
              file.path,
              tag: MediaItem(id: title, title: title),
            ),
        ]);
        await tester.pumpWidget(
          MaterialApp(
            home: StreamBuilder<int?>(
              stream: player.currentIndexStream,
              builder: (_, snapshot) =>
                  Text(snapshot.data == 1 ? 'Second track' : 'First track'),
            ),
          ),
        );
        final advanced = player.currentIndexStream.firstWhere(
          (index) => index == 1,
        );
        unawaited(player.play());
        await tester.runAsync(
          () => advanced.timeout(const Duration(seconds: 25)),
        );
        await tester.pump();
        expect(find.text('Second track'), findsOneWidget);
        expect(
          (player.sequenceState.currentSource?.tag as MediaItem?)?.title,
          'Second track',
        );
        await player.pause();
        await player.seek(const Duration(seconds: 1), index: 1);
        expect(player.position.inMilliseconds, greaterThanOrEqualTo(900));
      } finally {
        await player.dispose();
        await directory.delete(recursive: true);
      }
    },
  );
}
