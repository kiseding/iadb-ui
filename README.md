# iADB

Native iOS app for Android wireless debugging. Discover a device on the local network, pair with a code, then inspect it, manage packages and files, run a shell, stream logcat, and keep screenshots.

## Features

- Bonjour discovery, manual host/port connect, pairing codes, and saved devices
- Device properties, battery, and reboot (system, recovery, bootloader)
- Package list, launch, force-stop, clear data, uninstall, and APK install
- Remote files: browse, upload, download, rename, move, mkdir, and create a text file
- Streaming `shell,v2` with local command history
- Streaming logcat with level and text filters
- Screenshot capture and an on-device gallery

## Build and test

```sh
xcodegen generate
xcodebuild \
  -project iADB.xcodeproj \
  -scheme iADB \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  test \
  CODE_SIGNING_ALLOWED=NO \
  -skipMacroValidation \
  -skipPackagePluginValidation
```

An unsigned device IPA (install after you sign it):

```sh
xcodegen generate
BUILD_NUMBER=1 scripts/build-unsigned-ipa.sh
```

## Continuous integration

Every branch push and version tag runs [Unsigned IPA](.github/workflows/unsigned.yml), the only workflow that builds an IPA. The run uploads `iADB-<version>-<build>-unsigned.ipa`. A `vMAJOR.MINOR.PATCH` tag also attaches that IPA to the GitHub release. Pull requests still run unit tests and a generic iOS build. Signed TestFlight uploads stay on the manual `TestFlight` workflow and on version tags, and do not build a second IPA.

The IPA is unsigned. GitHub Actions does not have an Apple distribution certificate unless the TestFlight secrets in [docs/RELEASE.md](docs/RELEASE.md) are configured.
