# How NXPocket is put together

```
core/            NXPocketKit — the format and the checks, shared by both apps
mac/             NXPocket — the macOS launcher (SwiftPM executable, SwiftUI)
app/             NXShell (NXShellUI, NXShellHost) + the XcodeGen project that builds NXPocket.app
tools/           bootstrap, patches, builds
patches/         our changes to the engine, one file each, listed in patches/series
probe/           the app that decided the architecture (docs/SIGNING.md)
```

## `core/` — `NXPocketKit`

Pure Foundation, no UI, no platform assumptions. Both apps link it, so the two sides of a package cannot drift.

| | |
|---|---|
| `Package/GamePackage` | `package.json` schema 1, its coding keys and its decoding errors |
| `Package/GameManifest` | `game.manifest.json` schema 1, as the engine writes it |
| `Package/PackageVerifier` | the whole check list of `docs/PACKAGE.md`, with a progress callback |
| `Package/PackageScanner` | walks a folder without following a symbolic link, and finds nested Mach-O files |
| `Package/RomfsIdentity` | the identity of a RomFS image, over its header and index only |
| `Package/SafePath` | relative-path and containment rules, applied before any file system call |
| `Binary/MachOFile` | a minimal Mach-O reader: headers, load commands, segments, sections, rpaths |
| `Binary/MachOInspector` | the policy a framework must satisfy before it is signed |
| `Binary/CodeSignature` | the CodeDirectory of a signature: identifier, team, flags, whether a certificate signs it |
| `Crypto/FileDigest` | streaming SHA-256 |
| `Crypto/X509` | the few certificate fields iOS does not expose: subject, team, validity |
| `Import/GameImporter` | verify → sign → `rename` into the library, keeping saves |
| `Model/GameLibrary` | what is installed, and why a folder could not be read |
| `Host/LaunchMarker`, `Host/ImportLog` | the crash marker and the rotating import log |

## `mac/` — the launcher

`NXPMacKit` (no SwiftUI) then `NXPMacModel` (the stores) then the `NXPocket` executable (the views). Each layer may
only use the one above it.

- `Toolchain` — finds Xcode, a Python new enough for the engine, and the engine tree.
- `EngineBuilder` — the argument list, the JSON event stream, and what the engine left behind.
- `PackageWriter` — the framework, its RomFS image, its add-on content and the `package.json`.
- `DeviceInventory`, `DeviceTransfer` — `xcrun devicectl`, one call per top-level entry, `.complete` written last.
- `LocalLibrary` — the `.nxgame` folders already built.

## `app/` — the shell

`NXShellUI` is presentational (style, strings, rows); `NXShellHost` owns everything with a side effect and the
views that drive it. `NXShellUI` never imports `NXShellHost`.

- `ShellHostModel` — the library, the certificate, the importer, the launch, and the strings.
- `CertificateStore` — `SecPKCS12Import`, then the keychain with
  `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. The `.p12` and its password are never written to a file.
- `Signing` — `DeviceSigner` (zsign, linked by `tools/build_zsign.sh`) behind the `FrameworkSigner` protocol, so
  everything else can be tested without a certificate.
- `FrameworkLoader` — `dlopen`, the marker check, and the `__TEXT,__dmx0` code-page remap.
- `EngineLaunchPlan` — the environment and arguments a game's engine expects.
- `ImportService` — import everything finished, or re-sign what a new certificate invalidated.
- `FrameworkEngineHost` — starts a game through the host its framework carries (docs/ENGINE.md).

The app opens no network port. A game arrives the one way the Mac sends it, `devicectl device copy to`, which goes
over the cable or, once the iPhone trusts the Mac, over Wi-Fi on the same network (measured: 33 MB/s either way).

## Two rules that shaped the code

**A game folder is never half written.** Everything lands in `.incoming/<uuid>/` and only a `rename` puts it in the
library. A sender writes `.complete` last, and only a folder carrying it is imported.

**Nothing about the user's key or certificate leaks.** `prod.keys` is a path handed to the engine and is never
copied, logged or packed. The certificate lives in the keychain, is written to a temporary file only while zsign
signs, and is deleted immediately after.

## Tests

```bash
swift test --package-path core                       # 94 tests
swift test --package-path mac                        # 85 tests
xcodebuild test -project app/NXPocket.xcodeproj -scheme NXShellHost \
  -destination 'platform=iOS Simulator,name=iPhone 17'
xcodebuild test -project app/NXPocket.xcodeproj -scheme NXShellUI \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

No fixture is a binary in the repository: the Mach-O files the tests parse are built in the test, either
byte by byte or with `clang`, and no game data is used anywhere.
