#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 tool/prepare_personal_ios.py
flutter pub get
flutter build ios --release --no-codesign \
  --dart-define=HOMESERVER_PERSONAL=true \
  --dart-define=JELLYBOX_SIDELOAD=true
printf '%s\n' 'Unsigned iOS build produced. Apple signing is required before installation.'
