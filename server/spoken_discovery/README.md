# Spoken-audio discovery bridge

Python stdlib HTTP service for the personal player. The native app connects to
port 4041 on the same host as its linked Subsonic spoken-audio server. POST calls
use that account's existing salted token in the request body. Arr keys and admin
recovery credentials stay on the server; no credentials are bundled with the app.

External podcast search uses Apple's podcast directory. Book catalogue search
uses LibriVox, falling back to its `librivoxaudio` collection on Internet Archive.
Subscriptions use Airsonic's supported API; users select individual episodes or
chapters to download. Feed-only entries are never represented as playable files.
The bridge's generated book feeds contain public catalogue metadata and use
persistent unguessable URLs so Airsonic can retrieve them without private tokens.

Indexer book search uses Prowlarr category 3030. Download requests require the
account's download/admin permission and an owner-bound cached result ID. They
never accept arbitrary client download URLs. The dedicated qBittorrent category
is `homeserver-audiobooks`, with a per-download background limit of 1 MiB/s and
at most three active requests. Existing client configuration is retained.

Completed downloads are checked for contained regular audio paths and verified
with native `ffprobe`. A book is assembled outside the watched library, then
published by an atomic directory rename. Hard links preserve seeding where
possible; cross-mount imports use hash-verified copies. Original downloads are
retained. Never scan the staging folder as part of the audiobook library.

## Deployment contract

Set `HOMESERVER_DISCOVERY_CONFIG` to a private deployment JSON file with these keys:
`state`, `staging`, `library`, `airsonic`, `prowlarr`, `qbittorrent`,
`prowlarr_config`, `subsonic_credentials`, `bind`, `port`, and `feed_base`.

Use a dedicated, restricted system service and root-owned source. Bind only
loopback and the desired private LAN/VPN addresses. `prowlarr_config` is an XML
configuration containing `ApiKey`; `subsonic_credentials` is the existing private
spoken account JSON with `username` and `password`. Systemd `LoadCredential` can
provide both without granting access to their original directories. qBittorrent
must be reachable through the deployment's existing authenticated/local API route.
Do not disable client authentication to make this bridge work.

Keep import staging and the published library under one dedicated writable parent
and on one filesystem. With systemd's filesystem protections, separate writable
bind mounts can still prevent atomic rename even when `st_dev` matches. Airsonic
must watch only the published `library` child, not that common parent.

Back up the entire `state` directory (SQLite job/feed records and `feed-secret`).
Do not regenerate the secret during upgrades; existing feed URLs depend on it.
Use SQLite backup or stop the bridge briefly for a consistent state snapshot.

Run `python -m unittest discover -s server/spoken_discovery -p test_service.py`.
Health is `GET /health`; all `/v1/*` operations require valid Subsonic credentials.
No AI worker is called. A local 30-second poll checks active download jobs only.
Failed imports remain inspectable and can be retried explicitly through the app.

Test actual download, import, audio decoding, seeking and real-device playback.
Metadata results, a healthy process or an accepted download request are not proof
of playable audio. Availability depends on the configured upstream services.
