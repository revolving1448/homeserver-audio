import 'package:flutter/material.dart';
import 'package:jplayer/src/data/backend/subsonic/spoken_audio_service.dart';

typedef SpokenConnectionInput = ({
  String url,
  String username,
  String password,
});

class SpokenConnectionDialog extends StatefulWidget {
  const SpokenConnectionDialog({this.profile, super.key});
  final SpokenProfile? profile;
  @override
  State<SpokenConnectionDialog> createState() => _SpokenConnectionDialogState();
}

class _SpokenConnectionDialogState extends State<SpokenConnectionDialog> {
  final _form = GlobalKey<FormState>();
  late final _url = TextEditingController(text: widget.profile?.url ?? '');
  late final _user = TextEditingController(
    text: widget.profile?.username ?? '',
  );
  final _password = TextEditingController();
  @override
  void dispose() {
    _url.dispose();
    _user.dispose();
    _password.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_form.currentState!.validate()) return;
    Navigator.pop(context, (
      url: _url.text.trim(),
      username: _user.text.trim(),
      password: _password.text,
    ));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Connect podcasts & audiobooks'),
    content: SingleChildScrollView(
      child: Form(
        key: _form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Connect once. Music keeps using your current account.'),
            TextFormField(
              controller: _url,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'Spoken audio server',
              ),
              validator: (value) {
                final uri = Uri.tryParse(value?.trim() ?? '');
                return uri != null &&
                        ['http', 'https'].contains(uri.scheme) &&
                        uri.host.isNotEmpty
                    ? null
                    : 'Enter the full http:// or https:// server address.';
              },
            ),
            TextFormField(
              controller: _user,
              autocorrect: false,
              decoration: const InputDecoration(labelText: 'Username'),
              validator: (value) => value == null || value.trim().isEmpty
                  ? 'Enter your spoken-audio username.'
                  : null,
            ),
            TextFormField(
              controller: _password,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(labelText: 'Password'),
              validator: (value) => value == null || value.isEmpty
                  ? 'Enter your password.'
                  : null,
              onFieldSubmitted: (_) => _submit(),
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: _submit, child: const Text('Connect')),
    ],
  );
}
