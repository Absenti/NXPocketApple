<div align="center">

# NXPocket

**Your Switch games, on your iPhone, without reinstalling the app.**

A macOS launcher and an iPhone shell. The launcher turns one of your own game dumps into a `.nxgame` package; the
shell verifies it, signs its code on the device with your own certificate, and adds it to its library.

</div>

---

## What it is

Two apps and one shared format.

| | |
|---|---|
| **`mac/`** | The launcher. A SwiftUI app that drives the nxnative engine: it unpacks your dump, rewrites the game's code, translates its shaders, packs a `.nxgame` package and copies it to your iPhone over USB. |
| **`app/`** | The shell. An iPhone app with a library, a certificate it holds in the keychain, an import pipeline that verifies and re-signs what it receives, and the start of a game through the engine host its framework carries. |
| **`core/`** | `NXPocketKit`: the package format, the Mach-O reader and its security policy, the RomFS identity. Shared by both apps, tested on its own. |

The point of the format is that **the app is never reinstalled to add a game**. A game's code arrives as a framework,
is signed on the device with the certificate the app itself was installed with, and is loaded from `Documents`.

## What it is not

- **Not an emulator.** The game's own code runs natively; Metal draws it.
- **It ships no key, no firmware, no game.** You build from your own dumps, on your own Mac. `prod.keys` never
  leaves your machine: the launcher passes its path to the engine and never copies it into a package or a log.
- **It is not affiliated with Nintendo.**

## Requirements

- An Apple silicon Mac, macOS 13 or later, and Xcode with the iOS SDK (the full Xcode: the Command Line Tools alone
  lack the Metal compiler and the iOS SDK).
- An iPhone on iOS 26 or later, with NXPocket installed by SideStore, and the certificate SideStore installed it
  with, exported as a `.p12`.

## Install

From the [latest release](https://github.com/Absenti/NXPocket/releases/latest):

1. **Mac:** download `NXPocket-Launcher.zip`, unzip it and move `NXPocket.app` to Applications. It is signed ad hoc:
   the first time, open it with a right-click → Open. Its **Setup** screen installs what the engine needs (Python,
   XcodeGen, the engine itself), each download pinned and checked, without a terminal, Homebrew or an admin password.
2. **iPhone:** in SideStore, add the source
   `https://github.com/Absenti/NXPocket/releases/latest/download/source.json` and install NXPocket from it. Never
   open the IPA from Files: iOS would install a second copy that does not start.
3. In SideStore, export the certificate it installed NXPocket with as a `.p12`; in NXPocket, **Settings →
   Certificate → Import a .p12**.
4. In the launcher, point the game folder at your own dumps and your own `prod.keys`, build, and send to the iPhone.

## Updates

- **The launcher** checks the latest GitHub release at most once a day (a setting turns it off), shows its notes,
  and on your OK downloads it, checks its SHA-256, moves the old app to the Trash and relaunches.
- **The iPhone app** is updated by SideStore from the source above. NXPocket's Settings show the installed version
  and can check the source for a newer one.
- Saves live on the iPhone. The launcher copies them to the Mac whenever the iPhone is connected and they changed.

## Building from source

```bash
tools/bootstrap.sh                     # fetch and sync the engine, apply our patches, create the output folder
tools/build_mac.sh --app               # the launcher  -> mac/.build/NXPocket.app
tools/build_app.sh --sim               # the iPhone app, for the simulator
tools/build_zsign.sh                   # once: the on-device signer (zsign and OpenSSL, pinned)
tools/build_app.sh --device-unsigned   # an unsigned IPA for SideStore
```

`VERSION` holds the version of both apps. CI (`.github/workflows/ci.yml`) runs the core, launcher and iPhone tests on
every push; pushing a tag `v<VERSION>` runs `.github/workflows/release.yml`, which builds both apps and publishes the
release with the SideStore source and the checksums.

## The certificate, and the seven days

A free Apple ID certificate lasts seven days. SideStore refreshes the app every week, and the certificate can change
when it does. NXPocket keeps the fingerprint of the certificate that signed each game and re-signs a game when the
certificate changes or is within a day of running out, so a game does not silently stop loading. If the certificate
has expired, the game is marked *Needs signing again* and refuses to start until you import a fresh `.p12`.

## Documentation

- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — how the two apps and the core fit together.
- [`docs/PACKAGE.md`](docs/PACKAGE.md) — the `.nxgame` format and every check the shell makes.
- [`docs/SIGNING.md`](docs/SIGNING.md) — why a game's code is signed on the device, and the probe that showed it.
- [`docs/ENGINE.md`](docs/ENGINE.md) — the seam to the engine, and what a build without it can still do.
- [`PLAN.md`](PLAN.md) — the original plan, kept for the record.

## Licence

MIT. See [`LICENSE`](LICENSE) and [`NOTICE`](NOTICE); NXPocket is built on nxnative and NX2Apple, and reuses a
small number of their designs, all credited there.
