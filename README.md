# NXPocket

Play your own Switch games on your iPhone. A Mac launcher builds them from your dumps; an iPhone app signs and runs
them, without reinstalling the app for each game.

> No keys, no firmware, no games included. Not an emulator: the game's code runs natively and Metal draws it.
> Not affiliated with Nintendo.

## How it works

| | |
|---|---|
| **Launcher** (`mac/`) | Turns a dump (NSP, XCI, folder) into a `.nxgame` package with the [nxnative](https://github.com/seedds/nxnative) engine and sends it to the iPhone over USB or Wi-Fi. Backs up your saves. |
| **iPhone app** (`app/`) | Verifies each package, signs its code on the device with your own certificate, and plays it. |
| **Core** (`core/`) | The package format, the Mach-O security policy and the RomFS identity, shared and tested on their own. |

## Requirements

- Apple silicon Mac, macOS 13+, full Xcode (the Command Line Tools are not enough).
- iPhone on iOS 26+, with [SideStore](https://sidestore.io).
- Your own dumps and your own `prod.keys`.

## Install

1. **Mac:** download `NXPocket-Launcher.zip` from the [latest release](https://github.com/Absenti/NXPocket/releases/latest),
   move `NXPocket.app` to Applications, and open it with right-click → Open the first time. Its **Setup** screen
   installs the rest (Python, XcodeGen, the engine), every download pinned and checked. No Homebrew, no admin password.
2. **iPhone:** in SideStore, add this source and install NXPocket from it:
   `https://github.com/Absenti/NXPocket/releases/latest/download/source.json`
3. Export the certificate from SideStore as a `.p12`, then import it in NXPocket: **Settings → Certificate**.
4. In the launcher, pick your games folder and `prod.keys`, build, and send.

Never install the IPA by opening it from Files: iOS installs a second copy that will not start.

## Updates

The launcher updates itself from GitHub releases. SideStore updates the iPhone app from the source above.

## Build from source

```bash
tools/bootstrap.sh                     # engine and patches
tools/build_mac.sh --app               # launcher -> mac/.build/NXPocket.app
tools/build_zsign.sh                   # on-device signer (zsign + OpenSSL, pinned)
tools/build_app.sh --device-unsigned   # IPA for SideStore
```

Tests: `swift test --package-path core`, `swift test --package-path mac`, and `xcodebuild test` on `app/` (see
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)). Releases: bump `VERSION`, push tag `v<VERSION>`; CI builds and
publishes everything.

## Docs

[Architecture](docs/ARCHITECTURE.md) · [Package format](docs/PACKAGE.md) · [Signing](docs/SIGNING.md) · [Engine](docs/ENGINE.md)

## License

MIT. Built on nxnative and NX2Apple (MIT); credits and third-party notices in [`NOTICE`](NOTICE).
