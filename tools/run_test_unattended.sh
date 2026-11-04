#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Unattended MelonLoader test run for Bloons TD 6 on macOS.
#
# Launches the game through melonloader-launch.sh with no terminal and no stdin, watches
# MelonLoader/Latest.log until assembly generation fails, mods finish loading (which only
# happens after the first scene change), the game exits, or the timeout passes. Then it
# terminates the game and any Cpp2IL child and prints a summary.
#
# Usage: run_test_unattended.sh [timeout_seconds=90] [output_dir=./unattended-run]
# Set ML_DEBUG=1 to pass --melonloader.debug (logs exceptions MelonLoader otherwise hides).
# Set ML_SETTLE=<seconds> to keep the game running that long after mods load (default 5).

set -u

GAME_DIR="${BTD6_DIR:-$HOME/Library/Application Support/Steam/steamapps/common/BloonsTD6}"
TIMEOUT="${1:-90}"
OUT_DIR="${2:-./unattended-run}"
ML_DIR="$GAME_DIR/MelonLoader"
LOG="$ML_DIR/Latest.log"

# Match the game binary and Cpp2IL by path, not just "BloonsTD6", so the kill doesn't hit
# unrelated processes whose arguments happen to mention the game folder
GAME_PATTERN="BloonsTD6.app/Contents/MacOS/BloonsTD6"
CPP2IL_PATTERN="Il2CppAssemblyGenerator/Cpp2IL/Cpp2IL"

FAIL_REGEX='LibCpp2ILInitializationException|Stream does not support writing|\[Fail\]|Failed to Load Il2CppAssemblyGenerator|Il2CppAssemblyGenerator was Not Found|Error Generating Interop Assemblies|No Support Module Loaded|Failed to Initialize Interface|Failed to load Melon Assembly'
DONE_REGEX='[0-9]+ Mods? loaded\.'
# The support module is set up right after mods load, so keep watching briefly for its failure
SETTLE_SECONDS="${ML_SETTLE:-5}"

strip_log() { sed 's/\x1b\[[0-9;]*m//g' "$LOG" 2>/dev/null | grep -vE '\] [0-9]+%$'; }

if pgrep -f "$GAME_PATTERN" >/dev/null; then
    echo "BTD6 is already running; refusing to start a second copy." >&2
    exit 2
fi

mkdir -p "$OUT_DIR"
STDOUT_LOG="$OUT_DIR/game-stdout.log"
START=$(date +%s)
echo "start: $(date '+%Y-%m-%d %H:%M:%S')  timeout: ${TIMEOUT}s"

cd "$GAME_DIR" || exit 1
GAME_ARGS=()
[ "${ML_DEBUG:-0}" = "1" ] && GAME_ARGS+=(--melonloader.debug)
MELONLOADER_NO_TERMINAL=1 ./melonloader-launch.sh "$GAME_DIR/BloonsTD6.app" ${GAME_ARGS[@]+"${GAME_ARGS[@]}"} < /dev/null > "$STDOUT_LOG" 2>&1 &
GAME_PID=$!
echo "pid: $GAME_PID${GAME_ARGS[*]:+  args: ${GAME_ARGS[*]}}"

RESULT="timeout"
DONE_AT=0
t=0
while (( t < TIMEOUT )); do
    sleep 1
    t=$((t + 1))

    if ! kill -0 "$GAME_PID" 2>/dev/null; then
        wait "$GAME_PID"
        RESULT="game exited on its own (rc=$?)"
        break
    fi

    # MelonLoader rotates the previous run's Latest.log into Logs/, so ignore it until it's rewritten
    [ -f "$LOG" ] && (( $(stat -f %m "$LOG") >= START )) || continue
    TEXT=$(strip_log)

    if grep -qE "$FAIL_REGEX" <<<"$TEXT"; then
        RESULT="failed: $(grep -oE "$FAIL_REGEX" <<<"$TEXT" | head -1)"
        break
    fi
    if (( DONE_AT == 0 )) && grep -qE "$DONE_REGEX" <<<"$TEXT"; then
        DONE_AT=$t
    fi
    if (( DONE_AT > 0 && t - DONE_AT >= SETTLE_SECONDS )); then
        RESULT="mods loaded and support module set up (engine past first scene change)"
        break
    fi

    if (( t % 15 == 0 )); then
        CPP2IL_PID=$(pgrep -f "$CPP2IL_PATTERN" | head -1)
        echo "t=${t}s cpp2il=${CPP2IL_PID:-none} | $(tail -1 <<<"$TEXT" | cut -c1-150)"
    fi
done
echo "result: $RESULT after ${t}s"

# Clean shutdown first, then force
pkill -TERM -f "$GAME_PATTERN" || kill -TERM "$GAME_PID" 2>/dev/null
pkill -TERM -f "$CPP2IL_PATTERN" 2>/dev/null
sleep 2
pkill -9 -f "$GAME_PATTERN" 2>/dev/null || true
pkill -9 -f "$CPP2IL_PATTERN" 2>/dev/null || true

cp "$LOG" "$OUT_DIR/Latest.log" 2>/dev/null
TEXT=$(strip_log)

echo
echo "=== summary"
echo "Stream does not support writing: $(grep -c 'Stream does not support writing' <<<"$TEXT")"
echo "Assembly Generation Successful:  $(grep -c 'Assembly Generation Successful' <<<"$TEXT")"
echo "HarmonyException lines:          $(grep -c 'HarmonyLib.HarmonyException' <<<"$TEXT")"
echo "ILHook frames:                   $(grep -c 'MonoMod.RuntimeDetour.ILHook' <<<"$TEXT")"
for d in "$ML_DIR/Dependencies/Il2CppAssemblyGenerator/cpp2il_out" "$ML_DIR/Il2CppAssemblies"; do
    if [ -d "$d" ]; then
        echo "${d#"$ML_DIR"/}: $(find "$d" -name '*.dll' | wc -l | tr -d ' ') dll(s)"
    else
        echo "${d#"$ML_DIR"/}: missing"
    fi
done
echo "still running: $(pgrep -f "$GAME_PATTERN" || echo none)"
echo "logs saved to: $OUT_DIR"
