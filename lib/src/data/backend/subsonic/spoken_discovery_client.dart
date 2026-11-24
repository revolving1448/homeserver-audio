import 'package:dio/dio.dart';
import 'package:jplayer/src/data/backend/subsonic/spoken_audio_service.dart';
import 'package:jplayer/src/data/backend/subsonic/subsonic_credentials.dart';

class SpokenDiscoveryResult {
  const SpokenDiscoveryResult(this.json);
  final Map<String, dynamic> json;
  String get id => json['id'] as String;
  String get title => json['title'] as String? ?? 'Untitled';
  String get author => json['author'] as String? ?? '';
  String get source => json['source'] as String? ?? '';
  String? get image => json['image'] as String?;
  bool get isDownload => json['kind'] == 'release';
  int get bytes => (json['bytes'] as num?)?.toInt() ?? 0;
  int get seeders => (json['seeders'] as num?)?.toInt() ?? 0;
}

class SpokenDiscoveryClient {
  SpokenDiscoveryClient(this.profile, {Dio? dio})
    : dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 8),
              receiveTimeout: const Duration(seconds: 90),
            ),
          );
  final SpokenProfile profile;
  final Dio dio;

  Uri get base => Uri.parse(
    profile.url,
  ).replace(port: 4041, path: '', query: null, fragment: null);

  Future<Map<String, dynamic>> call(
    String action, [
    Map<String, Object?> args = const {},
  ]) async {
    final credentials = SubsonicCredentials.decode(
      username: profile.username,
      encodedToken: profile.token,
    );
    if (credentials == null || credentials.usesPlainPassword) {
      throw StateError('Reconnect spoken audio to enable discovery.');
    }
    final response = await dio.postUri<Object?>(
      base.resolve('/v1/$action'),
      data: {'auth': credentials.queryParameters, ...args},
      options: Options(contentType: Headers.jsonContentType),
    );
    return Map<String, dynamic>.from(response.data! as Map);
  }

  Future<({List<SpokenDiscoveryResult> results, List<String> warnings})> search(
    SpokenCategory category,
    String query,
  ) async {
    final data = await call('search', {
      'category': category.name,
      'query': query.trim(),
    });
    return (
      results: [
        for (final x in data['results'] as List? ?? const [])
          SpokenDiscoveryResult(Map<String, dynamic>.from(x as Map)),
      ],
      warnings: [for (final x in data['warnings'] as List? ?? const []) '$x'],
    );
  }

  static String errorMessage(Object error) {
    if (error is DioException) {
      final data = error.response?.data;
      if (data is Map && data['error'] is String)
        return data['error'] as String;
      if (error.response?.statusCode == 401 ||
          error.response?.statusCode == 403) {
        return 'The spoken-audio login or download permission was rejected. Check connection settings.';
      }
      return 'Discovery could not reach the HP. Check Tailscale and try again.';
    }
    return 'Could not complete this request. Please retry.';
  }
}
