import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// An ordinary Cast receiver cannot use the phone's private Tailscale route.
bool needsRemoteCastGateway(Uri uri) {
  if (uri.host.endsWith('.ts.net')) return true;
  final ip = InternetAddress.tryParse(uri.host);
  if (ip == null || ip.type != InternetAddressType.IPv4) return false;
  final bytes = ip.rawAddress;
  return bytes[0] == 100 && bytes[1] >= 64 && bytes[1] <= 127;
}

class RemoteCastGateway {
  RemoteCastGateway({Dio? dio})
    : dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 8),
              receiveTimeout: const Duration(seconds: 20),
            ),
          );
  final Dio dio;

  Future<({Uri mediaUri, Uri? artUri})> resolve(Uri media, Uri? art) async {
    if (!needsRemoteCastGateway(media)) return (mediaUri: media, artUri: art);
    final privateApi = Uri(
      scheme: 'http',
      host: media.host,
      port: 4042,
      path: '/v1/cast',
    );
    final proxyArt =
        art != null &&
        art.host == media.host &&
        art.port == media.port &&
        art.path == '/rest/getCoverArt.view';
    try {
      final response = await dio.postUri<Object?>(
        privateApi,
        data: {
          'media_url': media.toString(),
          if (proxyArt) 'art_url': art.toString(),
        },
        options: Options(contentType: Headers.jsonContentType),
      );
      final data = Map<String, dynamic>.from(response.data! as Map);
      final playable = Uri.parse(data['media_url'] as String);
      if (playable.scheme != 'https' ||
          playable.host.isEmpty ||
          playable.userInfo.isNotEmpty ||
          !playable.queryParameters.containsKey('token')) {
        throw const FormatException('Invalid cast link');
      }
      Uri? artwork;
      if (data['art_url'] is String) {
        artwork = Uri.parse(data['art_url'] as String);
        if (artwork.scheme != 'https' ||
            artwork.host != playable.host ||
            artwork.port != playable.port ||
            artwork.userInfo.isNotEmpty) {
          throw const FormatException('Invalid artwork link');
        }
      } else if (art != null &&
          !proxyArt &&
          art.scheme == 'https' &&
          !needsRemoteCastGateway(art) &&
          InternetAddress.tryParse(art.host) == null &&
          !art.host.endsWith('.local')) {
        artwork = art;
      }
      return (mediaUri: playable, artUri: artwork);
    } on Object {
      // Dio errors can retain the POST body containing upstream authentication.
      throw StateError(
        'Could not prepare remote casting. Check Tailscale and the playback gateway.',
      );
    }
  }
}

final remoteCastGatewayProvider = Provider<RemoteCastGateway>((ref) {
  final gateway = RemoteCastGateway();
  ref.onDispose(gateway.dio.close);
  return gateway;
});
