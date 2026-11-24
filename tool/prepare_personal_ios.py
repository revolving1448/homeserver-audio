"""Prepare this fork's phone/Bluetooth target, preserving upstream source/credits.

Does not sign, publish, enrol an Apple account, or claim an iOS build was tested.
Run on an isolated checkout; idempotent.
"""
import pathlib, plistlib, re

root = pathlib.Path(__file__).resolve().parents[1]
info = root / 'ios/Runner/Info.plist'
data = plistlib.loads(info.read_bytes())
data['CFBundleDisplayName'] = 'HomeServer Audio'
data['CFBundleName'] = 'HomeServer Audio'
data['UIBackgroundModes'] = [mode for mode in data.get('UIBackgroundModes', []) if mode != 'remote-notification']
scenes = data.get('UIApplicationSceneManifest', {}).get('UISceneConfigurations', {})
scenes.pop('CPTemplateApplicationSceneSessionRoleApplication', None)
info.write_bytes(plistlib.dumps(data, sort_keys=False))
entitlements = root / 'ios/Runner/Runner.entitlements'
entitlements.write_bytes(plistlib.dumps({}, sort_keys=False))
project = root / 'ios/Runner.xcodeproj/project.pbxproj'
source = project.read_text()
source = source.replace('com.prodigytech.jellybox', 'local.homeserver.audio')
source = source.replace('INFOPLIST_KEY_CFBundleDisplayName = JellyBox;', 'INFOPLIST_KEY_CFBundleDisplayName = "HomeServer Audio";')
source = re.sub(r'DEVELOPMENT_TEAM = [^;]*;', 'DEVELOPMENT_TEAM = "";', source)
source = re.sub(r'("DEVELOPMENT_TEAM\[sdk=iphoneos\*\]" =) [^;]*;', r'\1 "";', source)
# Runner does not embed or build the optional widget extension. Its upstream
# source/target remains available for a later, separately provisioned feature.
source = re.sub(r'^\s*FA29600E306C0C3600985A7C /\* Embed Foundation Extensions \*/,\n', '', source, flags=re.M)
source = re.sub(r'^\s*FA29600C306C0C3600985A7C /\* PBXTargetDependency \*/,\n', '', source, flags=re.M)
project.write_text(source)
assert 'com.apple.developer.carplay-audio' not in entitlements.read_text()
assert plistlib.loads(info.read_bytes())['CFBundleDisplayName'] == 'HomeServer Audio'
assert 'PRODUCT_BUNDLE_IDENTIFIER = local.homeserver.audio;' in source
print('Personal phone/Bluetooth target prepared. Mac build/signing/device tests are still required.')
