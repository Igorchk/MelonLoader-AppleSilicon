#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# Rewrites x64-only MelonLoader mods in BloonsTD6/Mods as AnyCPU, so the .NET runtime
# on Apple Silicon will load them.
#
# CoreCLR on arm64 refuses assemblies built with PlatformTarget=x64 (FileLoadException
# 0x80131621), even when they contain only IL, which most BTD6 mods do. Patching only
# changes the PE header's target; the code is untouched.
#
# Usage: patch_mac_mods.sh [mods_dir]
#   mods_dir defaults to the Steam BloonsTD6 Mods folder (or $BTD6_DIR/Mods).
#
# Each patched file's original is copied to BloonsTD6/ModPatcher-backups/<timestamp>/
# first. Run it again after installing or updating mods; files that are already AnyCPU
# are skipped.
#
# Paths in the output show the home folder as ~, so logs, screenshots and recordings
# don't reveal the macOS account name.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCHER="$SCRIPT_DIR/ModPatcher/bin/cecilpatch.dll"

GAME_DIR="${BTD6_DIR:-$HOME/Library/Application Support/Steam/steamapps/common/BloonsTD6}"
MODS_DIR="${1:-$GAME_DIR/Mods}"
ML_DIR="$GAME_DIR/MelonLoader"

# A path for display, with a leading home folder shown as ~
show_path() {
    if [[ "$1" == "$HOME"/* || "$1" == "$HOME" ]]; then
        printf '~%s' "${1#"$HOME"}"
    else
        printf '%s' "$1"
    fi
}

# The same for free text, such as the patcher's error output
HOME_PATTERN="$(printf '%s' "$HOME" | sed 's/[][\.*^$|/]/\\&/g')"
hide_home() { sed "s/$HOME_PATTERN/~/g"; }

die() { echo "error: $*" | hide_home >&2; exit 1; }

[ -d "$MODS_DIR" ] || die "mods folder not found: $MODS_DIR"
[ -f "$PATCHER" ] || die "patcher not built: $PATCHER (build ModPatcher with: dotnet build -c Release -o bin)"

if pgrep -f "BloonsTD6.app/Contents/MacOS/BloonsTD6" >/dev/null; then
    die "BloonsTD6 is running; quit the game first"
fi

# Run the patcher on MelonLoader's own .NET runtime, so no SDK needs to be installed
DOTNET="$ML_DIR/Dependencies/dotnet/dotnet"
if [ ! -x "$DOTNET" ]; then
    DOTNET="$(command -v dotnet || true)"
    [ -n "$DOTNET" ] || die "no .NET runtime found (expected $ML_DIR/Dependencies/dotnet/dotnet; launch the game with MelonLoader once to download it)"
fi

# Cecil resolves referenced assemblies while writing, e.g. to encode enum-typed default
# parameter values, so give it everything a mod can reference
REF_DIRS=("$MODS_DIR" "$GAME_DIR/UserLibs" "$GAME_DIR/Plugins" "$ML_DIR/net6" "$ML_DIR/Il2CppAssemblies")
# shellcheck disable=SC2012 # version-sorting directory names needs ls -d; find has no equivalent here
FRAMEWORK_DIR="$(ls -d "$ML_DIR"/Dependencies/dotnet/shared/Microsoft.NETCore.App/*/ 2>/dev/null | sort -V | tail -1)"
[ -n "$FRAMEWORK_DIR" ] && REF_DIRS+=("${FRAMEWORK_DIR%/}")
EXISTING_REF_DIRS=()
for d in "${REF_DIRS[@]}"; do
    [ -d "$d" ] && EXISTING_REF_DIRS+=("$d")
done

BACKUP_DIR="$GAME_DIR/ModPatcher-backups/$(date +%Y%m%d-%H%M%S)"

patched=0; skipped=0; failed=0

shopt -s nullglob
for dll in "$MODS_DIR"/*.dll; do
    name="$(basename "$dll")"
    kind="$(file -b "$dll")"

    if [[ "$kind" != *"Mono/.Net assembly"* ]]; then
        echo "skip   $name (not a .NET assembly)"
        skipped=$((skipped + 1))
        continue
    fi
    if [[ "$kind" != *"x86-64"* ]]; then
        echo "ok     $name (already loads on arm64)"
        skipped=$((skipped + 1))
        continue
    fi

    mkdir -p "$BACKUP_DIR" || die "can't create $BACKUP_DIR"
    cp -p "$dll" "$BACKUP_DIR/$name" || { echo "FAIL   $name (backup failed, left untouched)"; failed=$((failed + 1)); continue; }

    tmp="$BACKUP_DIR/$name.patched.tmp"
    output="$("$DOTNET" "$PATCHER" "$dll" "$tmp" "${EXISTING_REF_DIRS[@]}" 2>&1)"
    rc=$?

    if [ $rc -eq 0 ] && [[ "$(file -b "$tmp")" == *"Intel 80386 Mono/.Net assembly"* ]]; then
        mv -f "$tmp" "$dll"
        echo "PATCH  $name (x64 -> AnyCPU)"
        patched=$((patched + 1))
    elif [ $rc -eq 2 ]; then
        rm -f "$tmp" "$BACKUP_DIR/$name"
        echo "ok     $name (already AnyCPU)"
        skipped=$((skipped + 1))
    else
        rm -f "$tmp"
        echo "FAIL   $name (left untouched)"
        echo "$output" | hide_home | sed 's/^/         /'
        failed=$((failed + 1))
    fi
done

rmdir "$BACKUP_DIR" "$GAME_DIR/ModPatcher-backups" 2>/dev/null
echo
echo "$patched patched, $skipped skipped, $failed failed"
if [ $patched -gt 0 ]; then
    echo "Originals backed up to $(show_path "$BACKUP_DIR")"
fi
[ $failed -eq 0 ]
