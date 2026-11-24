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
No public repository or remote build existed when this source package was prepared.

Free-account sideloading has renewal limits; see the installer documentation.
Native iPhone compilation and device playback remain unverified until the remote
build and real-device test pass. Windows casting currently supports DLNA/UPnP;
Google Cast is implemented on iOS/Android, with device verification still needed.

Original project documentation and credits: docs/UPSTREAM_README.md and LICENSE.
