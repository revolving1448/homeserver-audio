# HomeServer Audio

A personal Flutter audio player based on [JellyBox](https://github.com/avdept/JellyBoxPlayer), licensed under AGPLv3.
Original credits and documentation: [LICENSE](LICENSE) and [upstream README](docs/UPSTREAM_README.md).

Music has artwork-led listening shortcuts, favourites, search, queue editing,
seed radio and a temporary upcoming-track cache. History-based shelves use real
listening history; they do not fabricate or import a YouTube recommendation model.

Podcasts and Audiobooks have dedicated sidebar entries; phones use a Spoken tab.
Link the spoken-audio Subsonic server once. Music keeps its account and player.
Spoken tracks use separate identifiers, saved positions and chapter ordering.

Discover searches the podcast directory and adds subscriptions. Select individual
episodes to download; unfinished feed entries are not queued as playable files.
Book discovery uses LibriVox/its Internet Archive collection and the household's
configured Prowlarr audiobook indexers. Requests go through a private bridge to
qBittorrent, then verified complete audio is imported into the spoken library.
Availability depends on the actual providers and peers; not every title is available.
See [bridge deployment and security contract](server/spoken_discovery/README.md).

Server addresses, runtime credentials, signing keys and private maintenance notes
are excluded from this repository. Enter your own addresses and logins in the app.
Never commit `android/key.properties`, keystores, bridge configuration or state.

## Android / GrapheneOS

Application ID: `local.homeserver.audio`, separate from upstream JellyBox. Configure
a persistent private Android signing key, then use `tool/build_homeserver_android.ps1`.
The Pixel APK is `build/app/outputs/flutter-apk/app-arm64-v8a-release.apk`.
Phone playback does not require Play services. Google Cast is optional and disabled
when they are unavailable. Android 16 AOSP native decoding/advance/seek tests passed;
physical GrapheneOS hardware playback still needs owner verification. Keep the app
and VPN in the same Android user profile and allow their network access.

## iPhone preview

The manual `Build unsigned iPhone preview` workflow uses a free standard Mac runner,
Flutter 3.47.9 and Xcode 26.2. No Apple credentials are used in CI. The unsigned IPA
must be signed privately for the owner's phone, for example with AltStore Classic.
Free-account signing requires periodic renewal. There is no App Store/TestFlight
publication, widget extension or dedicated CarPlay entitlement in the personal target.
Unsigned compilation has passed; actual iPhone playback remains unverified.

## Development

Build one platform at a time per checkout. After native integration tests, regenerate
plugin registration with a normal release build rather than using `--no-pub` against
the test's generated plugin files. Focused unit/widget and native audio tests cover
queue changes, lyrics transitions, spoken routing, authentication and import boundaries.
The bridge has independent stdlib tests. Verify real playback before claiming a
platform complete. Windows supports DLNA/UPnP; Google Cast is mobile-only. The personal
Windows preview disables Flutter semantics around the routed surface to work around
an upstream native accessibility crash; mobile accessibility is unaffected.
