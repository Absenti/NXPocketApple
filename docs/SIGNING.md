# Why a game's code is signed on the device

## The question

A game's framework arrives from the Mac as a file. It has to end up in `Documents/games/<title ID>/`, outside the
app bundle, and iOS has to let the app `dlopen` it. Can it?

## What the probe showed

`probe/` is a small app that asks exactly that. It was run on an iPhone 15 Pro on iOS 27.0.1, installed with
SideStore and a free Apple ID certificate.

**Outside LiveContainer — refused.**

| Test | Result |
|---|---|
| A framework inside the bundle loads, and its `__TEXT,__dmx0` page remaps and runs | pass |
| **A byte-identical copy of that framework in `Documents`** | **refused** — `code signature invalid`, `errno 1` |
| A hard link in `Documents` to the bundle's own file | impossible (`EPERM`) |
| An ad-hoc signed file | refused, as it should be |

So a copy of a correctly signed file is refused purely because of where it lives.

**Inside LiveContainer — accepted.**

| Test | Result |
|---|---|
| The same copy in `Documents` loads, and its remapped code runs | pass |
| The hard link loads too | pass |
| An ad-hoc signed file | still refused: the signature check is active, this is not a disabled check |

The difference is in the `[sig]` lines the probe prints. LiveContainer re-signs **every** binary on the device with
the user's certificate, and gives all of them **the app's own signature identifier** (`com.kdt.livecontainer.<TEAM>`).
SideStore gives each nested framework its own identifier (`dev.nxpocket.probe.Probe`).

## The conclusion this project is built on, measured on the device

Phase 0c had the app sign frameworks itself, in `Documents`, with the certificate SideStore installed it with. Same
iPhone 15 Pro, iOS 27.0.1, free Apple ID, 2026-11-10, first run of a fresh process:

| Test | Signature the app wrote | Result |
|---|---|---|
| 5A | the app's identifier, the profile's team, **no entitlements** | refused — `code signature invalid` |
| 5B | the framework's own identifier, no entitlements | refused — `code signature invalid` |
| **5C** | **the app's identifier and a copy of the app's entitlements, from its profile** | **loads, and its remapped `__dmx0` page runs** |

So outside the bundle, iOS accepts code that was signed **on this device** with **the signature identifier of the app
that loads it** and **the app's own entitlements**. The identifier alone is not enough: 5A has it and is refused,
and so is test 2's copy, which SideStore signed with the framework's own identifier and no entitlements. That is
what iPorterNX does:

- the framework is signed at import, and again whenever the certificate changes;
- the identifier used is read from the running app's own CodeDirectory (`AppSignature.currentIdentifier`), so it
  matches whatever installed the app — SideStore's bundle ID, or LiveContainer's host identifier;
- the entitlements are the profile's (`DeviceSigner.Entitlements.appProfile`, the default). They grant the game
  nothing: a process's rights are those of its main executable, so the game still runs with exactly the app's;
- nothing else is signed: the app itself belongs to SideStore.

Two things had to change in the signer before 5C could say anything, and neither showed up on the Mac:

- **Stock zsign never writes entitlements into a dylib.** `BuildCodeSignature` gives anything but an `MH_EXECUTE` an
  empty dict and leaves the DER entitlements slot out of its CodeDirectory, whatever it was handed; the first 5C run
  was 5A again, `entitlements 181 bytes (none)` on both. `patches/zsign/0001-dylib-entitlements.patch` adds a flag,
  off by default, that the shim turns on when it is given no entitlements file. Switching on the blobs alone was not
  enough: `codesign` answered `invalid entitlements blob` until slot -7 was hashed into the CodeDirectory too.
- **A framework signed in place kills the app that loads it.** zsign signs through a `MAP_SHARED`, `PROT_WRITE`
  mapping of the file. The result is valid on disk — the very file, copied back to a Mac, satisfies its designated
  requirement — but its pages stay in the buffer cache marked as written through a mapping. With the entitlements
  in, `dlopen` accepted the signature and the kernel then killed the process in dyld's fixups: `SIGKILL`,
  namespace `CODESIGNING`, `Invalid Page`, on `__LINKEDIT`. The shim now rewrites the signed binary into a fresh file
  with `write(2)` and renames it over the original; with that, 5C loads and runs.

A caution for reading the probe: dyld never unloads an image and hands back the one it has for a path. A second run
in the same process showed 5A "passing" at the address 5C had loaded. The probe now gives 5C its own framework and
reports a test whose path is already loaded as `SKIP`, with `RESULT: RESIGN INCONCLUSIVE`; only a fresh launch counts.

`DeviceSigner` in `app/Sources/NXShellHost/Signing.swift` is the signer. It calls zsign (MIT,
github.com/zhlynn/zsign) through `tools/zsign_shim.cpp`; `tools/build_zsign.sh` fetches it at a pinned revision,
refuses it if its LICENSE is not MIT, and builds the library. A build without it still imports and verifies games,
and refuses to sign rather than leaving behind a framework iOS would reject.

Three things that only showed up once the real API was read, and that the earlier draft of this document got wrong:

- **LiveContainer's `ZSign/` directory is AGPL-3.0**, not a source iPorterNX may take code from. It implements the
  same API, but this project is MIT and PLAN.md forbids AGPL outright. The shim calls zsign's own C++ API instead.
- **zsign takes the team ID and the entitlements from the provisioning profile, not from the certificate.** Signing
  with a `.p12` alone fails with `Can't find TeamId!`. The app must therefore pass its own `embedded.mobileprovision`,
  which it has in its bundle. This also means the team check is structural rather than a courtesy: what ends up in the
  CodeDirectory is the profile's team.
- **`ZBundle::SignFolder` cannot sign a framework.** It looks for a `.app` or an `.appex` and stops at
  `Can't find app folder!`; a framework is only ever signed as a bundle nested in an app. The shim therefore signs the
  Mach-O directly, the way zsign's own `SignNode` does for a nested framework: one `ZMachO`, one identifier, the
  framework's `Info.plist` hashed into the signature's info slot.

## The signer, checked against Apple's own verifier

`tools/verify_signing.sh` signs a real framework — one with an icon, tables, a localisation and a `.DS_Store`, so the
seal is never trivially empty — using a certificate chain it generates, then hands the result to `codesign` rather
than to our own reader, which would only be agreeing with itself. It found four defects that no amount of compiling
would have caught:

- **`bSHA256Only` must be on.** Left off, zsign writes the SHA-1 CodeDirectory in slot 0 and the SHA-256 one as the
  alternate — the 32-bit layout. `codesign` computes the SHA-256 directory hash for an arm64 image, does not find it
  where it expects it, and rejects the result with `invalid signature (code or signature have been modified)`, a
  message that names neither SHA-1 nor slot 0. With the flag on, slot 0 is the SHA-256 directory and that verdict
  disappears. `tools/verify_signing.sh` now asserts the slot, so the flag cannot quietly go back.
- **The `.p12` must carry its issuer.** `GenerateCMS` prefers a CA chain found inside the p12 and otherwise insists
  on an Apple WWDR intermediate whose name hash matches the leaf's issuer; a bare leaf fails with
  `Unknown issuer hash`. Sandboxed exports from SideStore and AltStore carry the WWDR intermediate for exactly this
  reason, so this is a constraint on the certificate the user imports, not on the code.
- **What the entitlements are is a choice the signer makes explicitly.** zsign takes them from the provisioning
  profile unless a file overrides them. The first design passed an empty dict, following PLAN.md's "a framework
  carries none"; the device proved that rule wrong (5A against 5C above), and the default is now the profile's.
  The empty dict stays available as `.none`, for the tests.
- **A framework needs its resource seal.** `codesign` refuses a bundle whose signature carries a resources slot but
  which has no `_CodeSignature/CodeResources` on disk, and every framework Apple signs has one. zsign only produces
  one for an app (`GenerateCodeResources` is private), so the shim writes it: every file hashed, the main executable
  and the seal itself excluded, and zsign's own rule tables. Two traps sat inside that, both found by giving the test
  framework real content: the rule tables must be written with `<real>` weights and keep their `optional`/`omit`
  flags — flattened values earn `invalid resource specification rule(s)` — and a digest is a plist `<data>`, not a
  `<string>` starting with `data:`, which earns `the sealed resource directory is invalid`.

What the check establishes, on the produced framework: `codesign` reports **valid on disk**. Its identifier is the one
the app asked for, its team is the profile's, slot 0 is the SHA-256 CodeDirectory, and the resource seal validates
against real files. The one complaint left is `does not satisfy its designated Requirement`, which is the Requirement
demanding a certificate anchored to Apple — exactly what a real Apple certificate supplies and a generated one cannot.

**What the iPhone has since checked.** Signing with a real Apple certificate on the device, and `dlopen` of the
result outside the bundle with its remapped code page running: both pass with the probe's 64 KB test framework (5C
above). **Not checked yet:** a real game's framework, which is far larger and runs the engine — that needs the engine
port. The probe measured 7 to 20 MB/s for signing, so a 200 MB framework takes about 10 to 30 seconds.

## The seven-day certificate

With a free Apple ID the certificate expires after seven days and SideStore refreshes the app weekly. iPorterNX
records the SHA-256 of the certificate that signed each game in `Documents/games/<title ID>/.signing.json` together
with its expiry, and re-signs a game when

- the keychain certificate is not the one that signed it, or
- that certificate expires in less than 24 hours.

An expired certificate, or one from another team than the app's installer, marks the game *Needs signing again*: it
does not start, and the fix is to export a fresh `.p12` from SideStore and import it.

Signing happens once, at import or at a renewal. It costs nothing while a game runs.
