#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# Toggles BTD6 between modded and vanilla. Online modes (Co-Op, events) can
# flag an account for running a modded client, so this lets you switch to a
# clean, unmodified launch before playing online, and back again afterward,
# without hand-editing anything.
#
# Run it by double-clicking it in Finder, or from a terminal:
#   ~/Documents/Coding/BTD6-Mods/MelonLoader-AppleSilicon/toggle_mods.sh

set -uo pipefail

# Mask the home folder as ~ in everything this script prints, same reason
# install.sh does it: a terminal transcript pasted into a bug report shouldn't
# carry the macOS account name.
HOME_PATTERN="$(printf '%s' "$HOME" | sed 's/[][\.*^$|/]/\\&/g')"
exec > >(sed "s/$HOME_PATTERN/~/g") 2>&1

DEFAULT_GAME_DIR="$HOME/Library/Application Support/Steam/steamapps/common/BloonsTD6"

as_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

gui_note() {
    local title message
    title="$(as_escape "$1")"
    message="$(as_escape "$2")"
    osascript <<APPLESCRIPT >/dev/null 2>&1
display dialog "$message" with title "$title" buttons {"OK"} default button "OK" with icon note
APPLESCRIPT
}

gui_error() {
    local title message
    title="$(as_escape "$1")"
    message="$(as_escape "$2")"
    osascript <<APPLESCRIPT >/dev/null 2>&1
display dialog "$message" with title "$title" buttons {"OK"} default button "OK" with icon stop
APPLESCRIPT
}

# Prints the chosen POSIX path, or nothing if the user cancelled.
gui_choose_folder() {
    local prompt
    prompt="$(as_escape "$1")"
    osascript <<APPLESCRIPT 2>/dev/null
try
    set chosenFolder to choose folder with prompt "$prompt"
    return POSIX path of chosenFolder
on error
    return ""
end try
APPLESCRIPT
}

die() {
    echo "error: $1" >&2
    gui_error "BTD6 Mod Toggle" "$1"
    exit 1
}

command -v osascript >/dev/null 2>&1 || { echo "error: osascript not found; this needs a macOS desktop session" >&2; exit 1; }

# ---- locate the game --------------------------------------------------------

GAME_DIR="$DEFAULT_GAME_DIR"
if [ ! -d "$GAME_DIR/BloonsTD6.app" ]; then
    attempts=0
    while [ ! -d "$GAME_DIR/BloonsTD6.app" ] && [ $attempts -lt 3 ]; do
        attempts=$((attempts + 1))
        chosen="$(gui_choose_folder "Couldn't find BloonsTD6 at the default Steam location. Locate your BloonsTD6 folder (the one containing BloonsTD6.app):")"
        [ -n "$chosen" ] || die "Cancelled: no BloonsTD6 folder was selected."
        GAME_DIR="${chosen%/}"
    done
    [ -d "$GAME_DIR/BloonsTD6.app" ] || die "That folder doesn't contain BloonsTD6.app."
fi

# ---- toggle -------------------------------------------------------------

MARKER="$GAME_DIR/.vanilla_mode"

if [ -f "$MARKER" ]; then
    if osascript <<'APPLESCRIPT' >/dev/null 2>&1
display dialog "Current Status: VANILLA. Would you like to enable Mods?" with title "BTD6 Mod Toggle" buttons {"Cancel", "Enable"} default button "Enable" cancel button "Cancel" with icon note
APPLESCRIPT
    then
        rm -f "$MARKER" || die "Couldn't remove $MARKER."
        echo "Mods enabled."
        gui_note "BTD6 Mod Toggle" "Mods enabled. The next launch will run modded."
    else
        echo "Cancelled, nothing changed."
    fi
else
    if osascript <<'APPLESCRIPT' >/dev/null 2>&1
display dialog "Current Status: MODDED. Would you like to disable Mods for safe online play?" with title "BTD6 Mod Toggle" buttons {"Cancel", "Disable"} default button "Disable" cancel button "Cancel" with icon note
APPLESCRIPT
    then
        touch "$MARKER" || die "Couldn't create $MARKER."
        echo "Mods disabled."
        gui_note "BTD6 Mod Toggle" "Mods disabled. The next launch will run vanilla - safe for Co-Op and online events."
    else
        echo "Cancelled, nothing changed."
    fi
fi
