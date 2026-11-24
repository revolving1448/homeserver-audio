$ErrorActionPreference = 'Stop'
Push-Location (Join-Path $PSScriptRoot '..')
try {
    if (!(Test-Path 'android/key.properties')) {
        throw 'Configure your private Android release key in android/key.properties before distributing this build. Never commit the key or passwords.'
    }
    flutter pub get
    if ($LASTEXITCODE -ne 0) { throw 'Dependency resolution failed' }
    flutter build apk --release --target-platform android-arm64,android-x64 --split-per-abi `
        --build-number 272 --dart-define=HOMESERVER_PERSONAL=true --dart-define=JELLYBOX_SIDELOAD=true
    if ($LASTEXITCODE -ne 0) { throw 'Android build failed' }
    Write-Output 'Pixel/GrapheneOS: use build/app/outputs/flutter-apk/app-arm64-v8a-release.apk. Device playback still requires verification.'
} finally { Pop-Location }
