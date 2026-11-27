import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:jplayer/src/domain/playback/local_playback_target.dart';
import 'package:jplayer/src/domain/playback/playback_target.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';

Uint8List tone(double frequency) {
  const rate = 22050;
  const samples = rate * 4;
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
  data.setUint32(24, rate, Endian.little);
  data.setUint32(28, rate * 2, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  text(36, 'data');
  data.setUint32(40, samples * 2, Endian.little);
  for (var i = 0; i < samples; i++) {
    data.setInt16(
      44 + i * 2,
      (2000 * math.sin(2 * math.pi * frequency * i / rate)).round(),
      Endian.little,
    );
  }
  return bytes;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native audio and UI continue across automatic transitions and cache adoption',
    (tester) async {
      await JustAudioBackground.init(
        androidNotificationChannelId: 'local.homeserver.audio.transition',
        androidNotificationChannelName: 'Playback verification',
        androidNotificationIcon: 'drawable/ic_stat_music',
      );
      final directory = await Directory.systemTemp.createTemp(
        'audio-transition-',
      );
      final player = AudioPlayer();
      final target = LocalPlaybackTarget(player);
      try {
        final tracks = <TargetTrack>[];
        for (var i = 0; i < 4; i++) {
          final file = File('${directory.path}/track-$i.wav');
          await file.writeAsBytes(tone(440 + i * 110));
          tracks.add(
            TargetTrack(
              itemId: 'track-$i',
              title: 'Track $i',
              uri: file.uri,
              mimeType: 'audio/wav',
              isHls: false,
              duration: const Duration(seconds: 4),
            ),
          );
        }
        await tester.pumpWidget(
          MaterialApp(
            home: StreamBuilder<TargetPlaybackState>(
              stream: target.stateStream,
              builder: (_, snapshot) =>
                  Text('Track ${snapshot.data?.currentIndex ?? 0}'),
            ),
          ),
        );
        final visited = <int>[];
        final subscription = target.stateStream.listen((state) {
          final index = state.currentIndex;
          if (index != null && (visited.isEmpty || visited.last != index)) {
            visited.add(index);
          }
        });
        try {
          await target.load(
            tracks,
            initialIndex: 0,
            initialPosition: Duration.zero,
            autoPlay: true,
          );
          await tester.runAsync(() async {
            await target.stateStream
                .firstWhere((state) => state.currentIndex == 1)
                .timeout(const Duration(seconds: 30));
            // A download finishing at this boundary must not remove the playing item.
            await target.replace(1, tracks[1]);
            await target.replace(2, tracks[2]);
            await target.stateStream
                .firstWhere((state) => state.currentIndex == 3)
                .timeout(const Duration(seconds: 30));
            await player.pause();
          });
          await tester.pump();
          expect(find.text('Track 3'), findsOneWidget);
          expect(visited, containsAllInOrder([0, 1, 2, 3]));
          expect(target.state.currentIndex, 3);
          expect(
            (player.sequenceState.currentSource?.tag as MediaItem?)?.id,
            'track-3',
          );
        } finally {
          await subscription.cancel();
        }
      } finally {
        await target.dispose();
        await player.dispose();
        await directory.delete(recursive: true);
      }
    },
  );
}
