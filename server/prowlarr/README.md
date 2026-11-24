# Optional specialist audiobook indexer

Place the custom Cardigann YAML in Prowlarr's `Definitions/Custom` directory,
reload Prowlarr, and add AudioBookBay (HomeServer). Test normal HTTPS access
before enabling it. Do not disable TLS verification or change global indexer
settings. Website layout/domain changes can require future maintenance.

Configure the discovery bridge's `preferred_audiobook_indexer_ids` with this
instance's ID and `fallback_audiobook_indexer_ids` with chosen working general
sources. IDs belong to each installation; discover them locally. Specialist
results return first. Other sources are searched only for an empty/failed
specialist response, bounded to 18 seconds per source group. This prevents a
failing unrelated challenge solver from discarding working audiobook results.

The site supplies no live seeder counts; zero in these releases means unknown,
not a verified dead swarm. Metadata/magnet resolution does not prove torrent
completion or playable file content. Existing per-request limits, role checks,
file validation and import isolation still apply. This is audiobook metadata;
EPUB files are not audio and do not belong in the audiobook player.
