# The `.nxgame` package

One game, one folder, written by the launcher and read by the shell. There is no archive: a RomFS image is several
gigabytes, and a folder can be copied entry by entry and resumed, where a zip cannot.

```
0100111000200000.nxgame/
  package.json                          the manifest, verified before anything is signed or moved
  DmGame0100111000200000.framework/     the engine's output, unchanged
    game.manifest.json                  the engine's own manifest: the package is checked against it
    DmGame                              the executable, signed on the device at import
    ...
  romfs.img                             the complete RomFS image
  aoc/                                  optional: add-on content
```

On the phone it becomes:

```
Documents/games/0100111000200000/
  package.json
  DmGame0100111000200000.framework/
  romfs.img
  aoc/
  .signing.json                         which certificate signed it, and when it runs out
  save/                                 the engine's saves, kept across an update
  temp/                                 scratch, kept out of the backup
```

## `package.json`, schema 1

```json
{
  "schema": 1,
  "title_id": "0100111000200000",
  "name": "…",
  "version": "1.2.1",
  "package_version": "65536",
  "framework": "DmGame0100111000200000.framework",
  "chain": "b-3f9a2c",
  "min_os": "26.0",
  "romfs_id": "DMROMFSID1 title=… size=17179869184 index=9f3c…",
  "romfs_size": 17179869184,
  "aoc_size": 0,
  "files": [{ "path": "DmGame", "size": 8123456, "sha256": "…" }],
  "created_by": "nxpocket-desktop 0.1"
}
```

`files` lists **every** file of the framework with its SHA-256: the framework is small, and it is the part that will
run with the app's privileges, so it is the part that is checked byte by byte. The game's data is only size-checked
plus the RomFS identity, because a 15 GB image is never read whole on a phone.

`name`, `version`, `chain`, `min_os` and `title_id` are copied from the framework's own `game.manifest.json`, never
recomputed. A package whose values disagree with that file is refused.

## What the shell checks, in order

Cheap checks first, so a bad package is refused before any hashing.

1. `package.json` exists, is at most 4 MB, is valid JSON, and has `schema == 1`. Every metadata file the shell reads
   (`package.json`, `game.manifest.json`, `Info.plist`, `.signing.json`) has that bound (`BoundedRead`): `Documents`
   is open to Files and the Finder, and the library is read at launch.
2. `title_id` is 16 hex digits with the `0100` application prefix.
3. `framework` is a plain `.framework` name, and that folder exists.
4. The framework's `game.manifest.json` decodes, and its `title_id`, `name`, `chain` and `min_os` equal the
   package's. Its `framework_executable`, `profile`, `shader_map` and `icon` are relative paths with no `..`; this
   is checked wherever the manifest is read, the launch included. There is no shader chain to compare with the
   shell's: the engine comes with each game's framework (docs/ENGINE.md).
5. `min_os` is not newer than the device.
6. Every path in `files` is relative, has no `..`, no absolute form and no NUL; no path is listed twice.
7. Every listed file exists, with exactly the listed size. The executable the manifest names is the one the
   framework's `Info.plist` names: zsign signs the second and the launch loads the first.
8. Every listed file hashes to the listed SHA-256.
9. Every file in the framework folder is listed: an extra file is a refusal, not a warning. The Finder's own files
   (`.DS_Store`, `._<name>`) are the one exception: a Mac app never lists them, and the shell deletes them from the
   whole transfer before step 1, so they are neither refused nor signed. Folders are read with `readdir`, because
   Foundation's listing hides every `._` file; a Mach-O under one of these names is still a hidden Mach-O (step 11).
10. The executable is a thin arm64 `MH_DYLIB`, with an `LC_BUILD_VERSION` for iOS and a minimum OS this device
    satisfies; every dynamic dependency is under `/usr/lib`, `/System/Library`, `/System/iOSSupport`, or a
    `@rpath`/`@loader_path`/`@executable_path` reference that stays inside the framework.
11. No other file in the framework starts with a Mach-O magic, and there is no symbolic link anywhere.
12. `romfs.img` has the listed size and the identity the engine stamped (`RomfsIdentity`, FNV-1a 64 over the header
    and the index only).
13. `aoc/` holds exactly `aoc_size` bytes, and nothing when `aoc_size` is 0. Add-on content is not listed file by file.

Only then is the framework signed, and only after a successful signature is the folder moved into `games/`.

## Transfers

A transfer lands in `Documents/.incoming/<uuid>/`. The sender writes a `.complete` marker **last**; the shell only
imports a folder that carries it, and keeps it until the user imports it, however old. An unfinished transfer is
deleted so that it never accumulates:

- when a copy fails, the Mac app copies a `.abandoned` marker into the folder, and the shell deletes a folder marked
  so as soon as it looks. devicectl cannot delete a file. **Never** use `copy to --remove-existing-content true` to
  empty a folder: it empties the app's whole data container (Documents, saves, Library), not the destination. It was
  used here for a day and wiped the phone's games on every failed send (measured with a witness file, 2026-11-11); a
  test in `mac/` now forbids the flag;
- when the sender went away without a word (a cable pulled, the Mac app quit), the shell deletes the folder once
  nothing in it has changed for ten minutes (`GameLayout.incomingIdleLimit`). Activity is the latest change time of
  anything in the folder, not its modification time: devicectl gives a copied file the modification time it had on
  the Mac.

The shell looks at start, whenever it comes back to the foreground, and after every action. A transfer refused at
import because of the package itself (a wrong hash, a damaged framework) is deleted too, since importing it again
would fail the same way; one refused for the certificate or the free space is kept for a retry.

The free space an import asks for is what it writes beyond the transfer, which is already on the volume: a fresh copy
of the signed executable and 1 GB of headroom. The move into `games/` and the carrying over of saves are renames and
cost nothing. An expired certificate is refused before signing.

The move into `games/<title ID>` is a `rename`, so a game folder is never half written. Replacing an existing game
moves the old folder aside as `games/.replaced-<uuid>`, installs the new one, and moves its `save*` entries into it,
one rename each. The old folder is deleted only once it holds no save: if one cannot be moved, the folder stays,
and the next launch moves what is left into the game (`GameImporter.recoverReplacedSaves`). Saves are never lost to
an update.

A game folder that lost its framework, its executable or its `romfs.img` after the import (a copy through Files cut
short, a file deleted by hand) is listed as damaged, with the missing file named, rather than as a playable game.
