# The engine

The engine is nxnative, through NX2Apple. It is a separate project with its own licence and its own release cycle;
NXPocketApple drives it and never modifies it in place.

## On the Mac: it builds each game

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

## On the iPhone: the engine comes with each game

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

### What the app bundles from the engine

Only the shared-font stand-ins, in the app's `dm/font` (`DM_FONT_DIR`): `standard.ttf` is macOS's Arial Unicode and
`nintendo_ext.ttf` comes out of the engine's `dm/tools/make_ext_font.py`. They are build products, never committed:
`tools/build_app.sh` copies them from the engine's build of a game (`engine/dm/ios/Gen/dm/font`), or makes them as
the engine does.

The Info.plist keys the engine's shell declares for a game are in `app/project.yml` too: controllers
(`GCSupportedGameControllers`), the display's full refresh rate (`CADisableMinimumFrameDurationOnPhone`), Game Mode,
one scene. The entitlement is the same, `com.apple.developer.kernel.increased-memory-limit`.

## What is verified

On the iPhone 15 Pro (iOS 27.0.1), with the first real game: the framework is signed on the phone, loads from
`Documents` in 170 ms, carries its marker and the three 16K-aligned sections of each module the loader maps, and
exports the four entry points. A start through `FrameworkEngineHost` on the phone is the next test.
