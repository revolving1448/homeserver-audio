param(
  [Parameter(Mandatory=$true)][string]$FlutterSdk,
  [string]$CargoHome,
  [string]$RustupHome,
  [string]$JavaHome,
  [ValidateSet('debug','release')][string]$Mode = 'debug'
)
$ErrorActionPreference = 'Stop'
$musicProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$musicFlutter = Join-Path $FlutterSdk 'bin/flutter.bat'
if (-not (Test-Path -LiteralPath $musicFlutter)) { throw 'Flutter SDK missing' }
if ($CargoHome) { $env:CARGO_HOME = $CargoHome; $env:PATH = "$CargoHome/bin;$env:PATH" }
if ($RustupHome) { $env:RUSTUP_HOME = $RustupHome }
if ($JavaHome) { $env:JAVA_HOME = $JavaHome; $env:PATH = "$JavaHome/bin;$env:PATH" }
$musicConfigSlot = if ($env:GIT_CONFIG_COUNT) { [int]$env:GIT_CONFIG_COUNT } else { 0 }
[Environment]::SetEnvironmentVariable("GIT_CONFIG_KEY_$musicConfigSlot", 'core.longpaths', 'Process')
[Environment]::SetEnvironmentVariable("GIT_CONFIG_VALUE_$musicConfigSlot", 'true', 'Process')
$env:GIT_CONFIG_COUNT = [string]($musicConfigSlot + 1)
Push-Location $musicProjectRoot
try {
  $musicPubOutput = & $musicFlutter pub get 2>&1
  $musicPubExit = $LASTEXITCODE
  if ($musicPubExit -ne 0 -and ($musicPubOutput -join "`n") -notmatch 'Building with plugins requires symlink support') {
    throw ($musicPubOutput -join "`n")
  }
  # Directory junctions work without enabling system-wide Developer Mode.
  # All links are generated inside this checkout; no existing target is removed.
  $musicPlugins = Get-Content '.flutter-plugins-dependencies' -Raw | ConvertFrom-Json
  foreach ($musicPlatform in @('windows','linux')) {
    $musicLinkRoot = [IO.Path]::GetFullPath((Join-Path $musicProjectRoot "$musicPlatform/flutter/ephemeral/.plugin_symlinks"))
    if (-not $musicLinkRoot.StartsWith($musicProjectRoot + [IO.Path]::DirectorySeparatorChar)) { throw 'Unexpected link directory' }
    New-Item -ItemType Directory -Path $musicLinkRoot -Force | Out-Null
    foreach ($musicPlugin in $musicPlugins.plugins.$musicPlatform) {
      if ($musicPlugin.name -notmatch '^[A-Za-z0-9_]+$') { throw 'Invalid plugin name' }
      $musicLink = Join-Path $musicLinkRoot $musicPlugin.name
      if (-not (Test-Path -LiteralPath $musicLink)) {
        New-Item -ItemType Junction -Path $musicLink -Target $musicPlugin.path | Out-Null
      }
    }
  }
  & $musicFlutter build windows "--$Mode" --no-pub --dart-define=JELLYBOX_SIDELOAD=true --dart-define=HOMESERVER_PERSONAL=true
  if ($LASTEXITCODE -ne 0) { throw 'Windows build failed; see compiler output' }
} finally { Pop-Location }
