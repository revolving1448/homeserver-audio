import 'package:flutter_test/flutter_test.dart';
import 'package:jplayer/src/core/diagnostics/log_redaction.dart';

void main() {
  test(
    'stream errors retain endpoint but remove URL credentials and all query values',
    () {
      final text = redactDiagnosticText(
        'Failed http://admin:private@server:5274/rest/stream?id=10&t=secret&s=salt',
      );
      expect(text, 'Failed http://server:5274/rest/stream?[redacted]');
      expect(text, isNot(contains('private')));
      expect(text, isNot(contains('secret')));
    },
  );
  test('authorization headers and URL fragments never persist secrets', () {
    expect(
      redactDiagnosticText('Authorization: Bearer private-token'),
      'Authorization: Bearer [redacted]',
    );
    expect(
      redactDiagnosticText('https://server/music#secret'),
      'https://server/music',
    );
    expect(
      redactDiagnosticText('loaded index 2 in 814ms'),
      'loaded index 2 in 814ms',
    );
  });
}
