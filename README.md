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
