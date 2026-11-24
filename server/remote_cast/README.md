# Remote Cast playback gateway

A Cast receiver downloads media itself. This optional gateway lets a native app
using a private Tailscale Subsonic URL hand an ordinary receiver an expiring
HTTPS capability URL. Local LAN casting retains its direct path.

The stdlib Python service has two separate listeners. Private port4042 exposes
POST `/v1/cast`, accepts the existing token-authenticated Subsonic stream URL
in its JSON body, and verifies it against the configured local music/spoken
server. Public port4043 binds only to loopback and exposes GET/HEAD `/play` and
`/cover` with unpredictable per-item tokens. Never publish port4042.

Configure allowed exact server aliases and ports, the HTTPS public base, state
directory, and private bind addresses in a protected server configuration.
Only `/rest/stream.view` and `/rest/getCoverArt.view` are supported. The upstream
is always rewritten to loopback, redirects are rejected, and unrelated routes
are never proxied. Upstream authentication stays in private mode0600 SQLite
state; the speaker only gets a random token. Tokens expire after six hours,
are scoped to one media/artwork URL, and have an owner quota. Expired tokens
are pruned during minting. No request bodies or token-bearing URLs are logged.
The service preserves byte ranges, HEAD, content length, media type and CORS.
Thread count and upstream timeouts are bounded. Run as an unprivileged service
with write access only to its own state. This is playback capability access,
not a public library, user-login proxy, admin endpoint, or general URL proxy.

Tailscale Funnel can provide a public HTTPS endpoint without router changes.
Choose an unused Funnel-supported port; publishing an existing private Serve
port would expose its other routes too. Preserve existing Serve/Funnel state
and verify that only the new dedicated endpoint is public. Funnel has external
bandwidth limits; verify actual public transfer and receiver playback rather
than treating API200 as success. Do not use a private MagicDNS resolution for
an alleged public-path test. Check the service and a valid expiring URL through
public DNS, verify downloaded bytes/decode, seeking and denied routes.

The phone and speaker must still be on the same Wi-Fi for Cast discovery;
guest/client isolation can prevent it. The phone still needs Tailscale to
browse/authenticate/mint. The speaker does not need Tailscale. Six-hour links
may need renewing for a very long queue or later seek. Physical receiver
playback must be tested with the updated app; unit tests alone cannot prove it.
