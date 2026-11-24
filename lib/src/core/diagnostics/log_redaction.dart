/// Keep diagnostics useful without persisting URL authentication material.
String redactDiagnosticText(String text) {
  final urls = text.replaceAllMapped(RegExp(r'https?://\S+'), (match) {
    final uri = Uri.tryParse(match[0]!);
    if (uri == null || uri.host.isEmpty) return '[URL]';
    return '${uri.origin}${uri.path}${uri.hasQuery ? '?[redacted]' : ''}';
  });
  return urls.replaceAllMapped(
    RegExp(
      r'(Authorization\s*[:=]\s*)(Bearer|Basic)\s+\S+',
      caseSensitive: false,
    ),
    (match) => '${match[1]}${match[2]} [redacted]',
  );
}
