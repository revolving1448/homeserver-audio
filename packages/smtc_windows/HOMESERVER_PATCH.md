# Local build patch

Vendored from the version resolved in pubspec.lock. Upstream licence retained.
`cargokit/cmake/resolve_symlinks.ps1` uses `Get-Item -LiteralPath ... -Force`
so paths inside hidden Windows AppData and paths containing wildcard characters
resolve correctly. No media-control or playback behavior was changed.
