import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jplayer/src/core/cast/remote_cast_gateway.dart';
import 'package:mocktail/mocktail.dart';
import '../../data/backend/subsonic/subsonic_test_support.dart';

void main() {
  setUpAll(registerSubsonicFallbacks);
  test('only overlay addresses need remote receiver links', () {
    for (final host in [
      '100.64.0.1',
      '100.127.255.1',
      'server.example.ts.net',
    ]) {
      expect(
        needsRemoteCastGateway(Uri.parse('http://$host:5274/rest/stream.view')),
        isTrue,
      );
    }
    for (final host in [
      '192.168.1.1',
      '100.63.1.1',
      '100.128.1.1',
      '127.0.0.1',
      'music.example.org',
    ]) {
      expect(
        needsRemoteCastGateway(Uri.parse('http://$host:5274/rest/stream.view')),
        isFalse,
      );
    }
  });
  test(
    'local casting keeps its original URL and never calls gateway',
    () async {
      final adapter = MockHttpClientAdapter();
      final gateway = RemoteCastGateway(
        dio: Dio()..httpClientAdapter = adapter,
      );
      final media = Uri.parse('http://192.168.1.1:5274/rest/stream.view?id=1');
      final result = await gateway.resolve(media, null);
      expect(result.mediaUri, media);
      verifyNever(() => adapter.fetch(any(), any(), any()));
      gateway.dio.close();
    },
  );
  test(
    'remote links are minted privately without URL authentication leakage',
    () async {
      final adapter = MockHttpClientAdapter();
      RequestOptions? captured;
      when(() => adapter.fetch(any(), any(), any())).thenAnswer((call) async {
        captured = call.positionalArguments[0] as RequestOptions;
        return ResponseBody.fromString(
          jsonEncode({
            'media_url': 'https://cast.example:10000/play?token=opaque',
            'art_url': 'https://cast.example:10000/cover?token=art',
          }),
          200,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        );
      });
      final gateway = RemoteCastGateway(
        dio: Dio()..httpClientAdapter = adapter,
      );
      final media = Uri.parse(
        'http://100.64.0.1:5274/rest/stream.view?id=1&u=user&t=private&s=salt',
      );
      final art = media.replace(path: '/rest/getCoverArt.view');
      final result = await gateway.resolve(media, art);
      expect(captured!.uri.toString(), 'http://100.64.0.1:4042/v1/cast');
      expect(captured!.method, 'POST');
      expect((captured!.data as Map)['media_url'], media.toString());
      expect(
        result.mediaUri.toString(),
        'https://cast.example:10000/play?token=opaque',
      );
      expect(result.artUri!.host, 'cast.example');
      gateway.dio.close();
    },
  );
  test('large queues bound concurrent link registrations', () async {
    final adapter = MockHttpClientAdapter();
    var active = 0;
    var peak = 0;
    when(() => adapter.fetch(any(), any(), any())).thenAnswer((_) async {
      active++;
      if (active > peak) peak = active;
      await Future<void>.delayed(const Duration(milliseconds: 2));
      active--;
      return ResponseBody.fromString(
        jsonEncode({'media_url': 'https://cast.example/play?token=opaque'}),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    });
    final gateway = RemoteCastGateway(dio: Dio()..httpClientAdapter = adapter);
    final results = await Future.wait([
      for (var i = 0; i < 40; i++)
        gateway.resolve(
          Uri.parse('http://100.64.0.1:5274/rest/stream.view?id=$i'),
          null,
        ),
    ]);
    expect(results, hasLength(40));
    expect(peak, inInclusiveRange(2, 4));
    gateway.dio.close();
  });
  test(
    'gateway failures do not include authentication or response details',
    () async {
      final adapter = MockHttpClientAdapter();
      when(
        () => adapter.fetch(any(), any(), any()),
      ).thenAnswer((_) async => ResponseBody.fromString('private-secret', 500));
      final gateway = RemoteCastGateway(
        dio: Dio()..httpClientAdapter = adapter,
      );
      await expectLater(
        gateway.resolve(
          Uri.parse(
            'http://100.64.0.1:5274/rest/stream.view?u=user&t=private-secret&s=salt&id=1',
          ),
          null,
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.toString(),
            'safe message',
            isNot(contains('private-secret')),
          ),
        ),
      );
      gateway.dio.close();
    },
  );
}
