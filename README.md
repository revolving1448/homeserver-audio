# HomeServer Audio

A personal Flutter audio-player fork of [JellyBox](https://github.com/avdept/JellyBoxPlayer), licensed under AGPLv3.

Features under development: artwork-led listening shortcuts, seed radio,
queue handling, temporary upcoming-track cache, and separately linked spoken
audio categories. Enter your own music/spoken server addresses and credentials
privately in the app. No server addresses, account credentials or maintenance
notes are included here.

## iPhone preview build

The manual `Build unsigned iPhone preview` workflow uses a standard macOS runner
and Flutter3.47.9. It does not use Apple credentials, sign an app, or upload to
TestFlight/App Store. Its unsigned IPA must be re-signed for the owner's device.
This repository's first unsigned iOS compilation succeeded using Xcode 26.2.

Free-account sideloading has renewal limits; see the installer documentation.
Signing, installation and actual iPhone playback remain unverified. Windows casting currently supports DLNA/UPnP;
Google Cast is implemented on iOS/Android, with device verification still needed.

Original project documentation and credits: docs/UPSTREAM_README.md and LICENSE.

## Android / GrapheneOS preview

The Android application ID is `local.homeserver.audio`, separate from upstream
JellyBox. Configure a persistent private signing key in `android/key.properties`
using the Android/Flutter release-signing documentation; keep that file and the
keystore outside version control. `tool/build_homeserver_android.ps1` builds
ARM64 (Pixel) and x86_64 (emulator) release APKs. The Pixel APK is
`build/app/outputs/flutter-apk/app-arm64-v8a-release.apk`.

Phone playback uses Android's media service and does not require a Google account
or Google Play services. Google Cast is optional and disabled when Play services
are unavailable. On GrapheneOS, allow the app network access and configure your
private VPN if the server requires it. Do not disable OS exploit protections.

Podcasts and Audiobooks are separate sidebar entries. Phones have a Spoken tab
with both categories. Link the spoken-audio Subsonic server once in its connection
settings. Music keeps its existing account and player. Podcasts currently list
server subscriptions and downloaded playable episodes; audiobook browsing requires
an audiobook folder configured on that server. This is not an unrestricted remote
audiobook catalogue. Bookmarks retain spoken progress; music radio is not applied
to spoken queues. Real GrapheneOS hardware playback still needs owner verification.
