# BTD6 Mods on Apple Silicon

Tools for running Bloons TD 6 mods natively on Apple Silicon Macs with the macOS arm64 port of MelonLoader.

The loader itself lives in two other repositories:

- **MelonLoader**, branch `macos-arm64-support` (based on LavaGang/MelonLoader v0.7.4). Install steps, the known issues and how the port works are in its `README-macOS.md`.
- **Il2CppInterop**, branch `macos-arm64-abi-fixes` (based on BepInEx/Il2CppInterop `f03c8f4`). It fixes how structs passed by value are handled on arm64. The release zips ship its `Il2CppInterop.Runtime.dll` and `Il2CppInterop.HarmonySupport.dll`.

## patch_mac_mods.sh

The .NET runtime on arm64 refuses mods built for x64 only (`FileLoadException`). Most BTD6 mods are, including BTD6 Mod Helper and many in its mod browser. This script rewrites each x64-only mod in `BloonsTD6/Mods` as AnyCPU, which changes only the PE header:

```bash
./patch_mac_mods.sh            # the Steam BloonsTD6/Mods folder
./patch_mac_mods.sh path/to/mods
```

Run it after installing or updating mods, with the game closed. It backs up each original to `BloonsTD6/ModPatcher-backups/<timestamp>/` and skips mods that already load.

It runs the patcher in `ModPatcher/` on the .NET runtime that MelonLoader downloads into the game folder, so no SDK is needed at run time. The patcher has to be built once with the .NET SDK:

```bash
cd ModPatcher && dotnet build -c Release -o bin
```

The `macos-arm64-support` branch of the MelonLoader fork runs this script automatically from `melonloader-launch.sh` before every launch.

## InGameModDeleter

A MelonLoader mod that adds a delete button for **loaded** mods to BTD6 Mod Helper's Mods menu. Mod Helper's own delete button only appears for mods that are disabled and weren't loaded this session.

- The red ✕ sits one slot left of the Settings gear in the selected mod's button row. It's hidden for Mod Helper itself.
- After you confirm, it deletes the mod's file and Mod Helper's cached info for it. The mod keeps running until the game restarts.
- It relies on Mod Helper 3.6.10 internals (`ModsMenu.SetSelectedMod`, `ModHelperData`). If a later version renames them, it logs which one is missing and the button doesn't appear.

Build it with `dotnet build -c Release` in `InGameModDeleter/`, which references the game folder's MelonLoader, `Il2CppAssemblies` and `Mods/Btd6ModHelper.dll`. Then copy `bin/Release/net6.0/InGameModDeleter.dll` into `Mods/`.

## tools/

- `MacArm64TestMod/` is a test mod that exercises the port:
  - lifecycle callbacks and Harmony patches on game methods;
  - `StreamingContext` structs passed by value (it checks that a non-default context arrives intact);
  - a probe that hooks the 12-byte `Btd6Player.Save` and calls `Btd6Player.Sync`. Without MelonLoader's short-function guard, Sync crashes with `SIGILL`.

  It builds against the game folder's MelonLoader and `Il2CppAssemblies` (set `GameDir` to override the location). Copy `bin/Release/net6.0/MacArm64TestMod.dll` into `Mods/` for a test run, and remove it again before playing.
- `run_test_unattended.sh [timeout] [output_dir]` launches the game through `melonloader-launch.sh` without a terminal window. It waits until the mods have loaded, or the launch fails, then stops the game and saves `Latest.log`.
  - `ML_DEBUG=1` turns on MelonLoader's debug logging.
  - `ML_SETTLE=<seconds>` keeps the game running for longer after the mods load.
  - The Steam client must be running.
  - Unattended runs don't get past the title screen without a click.

## License

The code in this repository is licensed under the [Apache License 2.0](LICENSE), the same license as MelonLoader.

It builds on these projects, none of which are included here:

- [MelonLoader](https://github.com/LavaGang/MelonLoader) (Apache-2.0). Everything here runs on it, and the port's own changes are in the MelonLoader fork.
- [Il2CppInterop](https://github.com/BepInEx/Il2CppInterop) (LGPL-3.0). The port's struct ABI fix is in the Il2CppInterop fork.
- [BTD6 Mod Helper](https://github.com/gurrenm3/BTD-Mod-Helper) (GPL-3.0). InGameModDeleter compiles against it and patches it at run time, but includes none of its code. The Free Software Foundation considers Apache-2.0 compatible with GPL-3.0.
- [Mono.Cecil](https://github.com/jbevain/cecil) (MIT). ModPatcher gets it from NuGet when it's built.

No Bloons TD 6 files are in this repository. The test mod and InGameModDeleter compile against the game assemblies MelonLoader generates in your own game folder. This project isn't affiliated with Ninja Kiwi, LavaGang or the BTD6 Mod Helper authors.
