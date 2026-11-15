# How NXPocketApple is put together

```
core/            NXPocketKit — the format and the checks, shared by both apps
mac/             NXPocketApple — the macOS launcher (SwiftPM executable, SwiftUI)
app/             NXShell (NXShellUI, NXShellHost) + the XcodeGen project that builds NXPocketApple.app
tools/           bootstrap, patches, builds
patches/         our changes to the engine, one file each, listed in patches/series
probe/           the prototype that decided the architecture (docs/SIGNING.md)
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

`tools/build_mac.sh --app` wraps the executable in `NXPocketApple.app` (bundle ID `dev.nxpocket.launcher`), signed ad hoc.
It is not notarized, which needs a paid Developer ID: Gatekeeper blocks the copy downloaded from a release until the
quarantine attribute is removed (`xattr -dr com.apple.quarantine /Applications/NXPocketApple.app`) or the user picks
**Open Anyway** in System Settings → Privacy & Security. `LauncherUpdate` downloads with URLSession, which sets no
quarantine, so an update replaces the app without asking again.

- `LauncherLog` — what the window's log shows, kept in `~/Library/Logs/NXPocketApple/launcher.log` (the last 2 MB), so a
  build that failed an hour ago can still be read. The window keeps 800 lines and forgets them at quit.
- `ProcessRunner`, `ProcessTree` — streams a tool's output a line at a time, and pauses it: `pause` stops the process and
  every process below it (the engine starts Xcode, the Metal compiler and a pool of workers, and `Process` leaves them in
  the launcher's own process group, so the tree is walked), `resume` wakes them, and `cancel` wakes them first (a stopped
  process ignores SIGTERM) and then stops the whole tree (SIGTERM, SIGKILL after 3 s, `waitUntilTreeGone`): it used to stop only
  the Python process, and the compilers it had started carried on writing. A process is told apart from another that took its
  id by its start time, and the ids 0 and 1 are never part of a tree (the "children" of 0 are every process of the Mac). Tested on real process trees and, by hand, on a real `xcodebuild` paused mid-compile.
- `BuildFootprint` — what a cancelled build made in its work folder (`<title ID>_build`), and only that. The folder is looked at
  before the build writes anything: one that did not exist goes whole, one that did keeps everything it held (the shader
  caches of an earlier build took hours) and loses only the files and folders absent from the first look. A link is removed as
  a link and never followed, and a folder that is not a plain `*_build` folder is never touched. A file rewritten in place
  cannot be given back.
- `DecompressedCopies` — the `.nsp` / `.xci` the engine makes out of a `.nsz` / `.xcz` into `<title ID>_build/nsp/` and keeps "for
  the next build" (as large as the game). Removed once the package is built, if the setting is on (it is by default). Only regular
  `.nsp` / `.xci` files directly in `nsp/`; never a build input (the user's dump, links resolved), never a link, never anything outside
  `nsp/`. The extraction is not touched: the build's `romfs.img` is an APFS clone of it, so deleting it would free nearly nothing.
- `EngineIdentity` — which engine is on the disk (its sync stamp, else its script's date), read when a build starts and again if it
  fails: an engine replaced during a build (the NX2Apple app updating it, `engine.py sync`) makes the next stage look for shaders
  under the new engine's "chain" name, so the failure says that instead of "no iOS shader libraries".
- `Toolchain` — finds Xcode, a Python new enough for the engine, and the engine tree.
- `EngineBuilder` — the argument list, the JSON event stream, and what the engine left behind. The engine's `say` puts
  the time before every message (`[21:05:47] game files: …`): lines are read without it (`withoutClock`), or the
  `game files:` line that names the RomFS image and the `[RED]` reasons are never found.
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
- `SigningChoice` — which entitlements a game's signature copies (the profile's, or the ones in the app's own
  signature), the choice that worked on this installation, and `SigningDiagnosis`: why iOS may have refused a game.
- `FrameworkEngineHost` — starts a game through the host its framework carries (§ The engine, below).

The app opens no network port. A game arrives one of three ways, and the first needs nothing from the network
settings: the Mac pushes it with `devicectl device copy to` (over the cable or, once the iPhone trusts the Mac, over Wi-Fi
on the same network; measured 33 MB/s either way); or, once the player turned *network sources* on, the phone itself
connects out and downloads it from their own Mac (`NetworkSources`, `PinnedHTTPSSource`) or from an SFTP server they
added (`SFTPSource`, the one place the app links an SSH library). Both end as a folder in `.incoming/<uuid>/` with `.complete` written last, so the importer cannot
tell them apart. The phone only ever connects out; the launcher listens only while its Sharing switch is on.
`docs/SHARING.md` has the threat model, the protocol, and what each party can and cannot do.

The sharing code is split so each half is tested against the other: `core/…/Sharing/` has the plan, the downloader,
the HTTPS client, and `core/…/NXPocketSFTP/` the SFTP client; `mac/…/NXPMacKit/Sharing/` has the server; the Mac's
`swift test` runs the real client against the real server over TLS on the loopback, and `core`'s runs the SFTP client
against the machine's own OpenSSH `sshd`.

## Two rules that shaped the code

**A game folder is never half written.** Everything lands in `.incoming/<uuid>/` and only a `rename` puts it in the
library. A sender writes `.complete` last, and only a folder carrying it is imported.

**Nothing about the user's key or certificate leaks.** `prod.keys` is a path handed to the engine and is never
copied, logged or packed. The certificate lives in the keychain, is written to a temporary file only while zsign
signs, and is deleted immediately after.

## Tests

```bash
swift test --package-path core
swift test --package-path mac
tools/test_app.sh                                    # the iPhone app, in the simulator
```

`tools/test_app.sh` builds the signing engine first when it is missing (the app's tests link it: without
`app/Signing/OpenSSL.xcframework` nothing builds), makes the Xcode project from `app/project.yml`, and runs the one
scheme with a test action, `NXPocket`. The `NXShellHost` and `NXShellUI` schemes XcodeGen makes by itself have none,
and the project lists its files when it is made: a test file added since is not run until it is made again.

`tools/verify_signing.sh` is the other check, with Apple's own `codesign` as the judge: it signs a framework with each of
the three choices of entitlements and reads back what the signature carries.

No fixture is a binary in the repository: the Mach-O files the tests parse are built in the test, either
byte by byte or with `clang`, and no game data is used anywhere.

## The engine

The engine is nxnative, through NX2Apple. It is a separate project with its own licence and its own release cycle;
NXPocketApple drives it and never modifies it in place.

### On the Mac: it builds each game

The launcher runs `engine/scripts/build_ipa_from_nsp.py` as a subprocess:

```
build_ipa_from_nsp.py <game folder> -k <prod.keys> --shell-framework <staging> --romfs separate --progress json
```

- `--shell-framework` builds **only** the game's framework: the rewritten code, its tables, its profile, its icon,
  and the engine's host (see below). The game's data stays out of it, so the part that gets signed on the phone
  stays small.
- `--romfs separate` keeps the game's files as an image next to the framework instead of inside it.
- `--progress json` gives one JSON object per line, which the launcher turns into a stage name, a fraction and a
  detail line. The protocol is `EngineEventParser`; the events are `stage`, `progress`, `stage_end` and `say`.

The launcher then reads what the engine left (`EngineBuilder.outputs`), packs it with `PackageWriter`, and that is
the package the phone receives. `tools/bootstrap.sh` fetches and syncs the engine tree.

### On the iPhone: the engine comes with each game

The app links nothing of the engine. A game's `DmGame<title ID>.framework` links its own host (`dm/host`), its
`front_ios.m` game view and its shaders: the engine's "Route C" (engine `dm/ios/framework/ShellGlue.m`), so an
engine update never invalidates the games already on the phone. The framework exports four entry points
(engine `dm/ios/Shell/ShellGlue.h`), checked on the first real game:

| Symbol                 | What it does                                                                         |
|------------------------|--------------------------------------------------------------------------------------|
| `dm_glue_version`      | `DM_GLUE_VERSION`, 1: a framework built for another version is refused               |
| `dm_glue_start_game`   | sets the game image for the loader and starts the host's early loading with `argv`   |
| `dm_glue_present_game` | makes the game's view the root of a window and asks for landscape; the view starts it |
| `dm_glue_focus_event`  | the scene's changes: 0 resigns active, 1 background, 2 foreground, 3 active           |

What the engine's own shell does around them (`dm_shell_start_game` and `dm_shell_present_game` in engine
`dm/ios/Shell/ShellMain.m`) is `FrameworkEngineHost`, in the same order: stderr to `Documents/log.txt` (the previous
run's kept as `log.prev.txt`), the environment, the working folder, `dlopen`, the marker symbol and its image base,
the glue version, `dm_glue_start_game`, then a window for `dm_glue_present_game` and the scene's focus events. The
game's view is shown in a window of its own above the library's, so SwiftUI's window is never taken from it. One
game per process: going back to the library is a new launch of the app.

`EngineLaunchPlan` builds the environment and the arguments. It mirrors `boot_env()` in the engine's
`dm/ios/Sources/main.m`: the profile, the RomFS image, the save and temp folders, the shader libraries, the pipeline
archive, the add-on content, the cheats and the shared fonts, with the game's own copies in
`Documents/games/<title ID>/` taking precedence over the framework's, so updating a shader library does not mean
re-signing the framework. The arguments are `dmhost <framework>/dm <module>...`; the host also accepts them without
the modules, and then takes them from the profile.

The Metal HUD: Metal reads `MTL_HUD_ENABLED` when the process makes its first device, long before a game starts, so
the app sets it (with `DM_HUD_PER_LAYER`) when it launches, as the engine's shell does before `UIApplicationMain`,
and each game's own setting decides at Play.

#### What the app bundles from the engine

Only the shared-font stand-ins, in the app's `dm/font` (`DM_FONT_DIR`): `standard.ttf` is macOS's Arial Unicode and
`nintendo_ext.ttf` comes out of the engine's `dm/tools/make_ext_font.py`. They are build products, never committed:
`tools/build_app.sh` copies them from the engine's build of a game (`engine/dm/ios/Gen/dm/font`), or makes them as
the engine does.

The Info.plist keys the engine's shell declares for a game are in `app/project.yml` too: controllers
(`GCSupportedGameControllers`), the display's full refresh rate (`CADisableMinimumFrameDurationOnPhone`), Game Mode,
one scene. The entitlement is the same, `com.apple.developer.kernel.increased-memory-limit`.
