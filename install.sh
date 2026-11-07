#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# All-in-one installer for the BTD6 Apple Silicon MelonLoader toolchain.
#
# Run it with:
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/Igorchk/MelonLoader-AppleSilicon/main/install.sh)"
#
# What it does (see README.md "Installation & Setup" for the manual, step-by-step
# version of all of this):
#   1. Finds your BloonsTD6 Steam folder (or asks you to pick it).
#   2. Clones/updates this repo's toolchain into the path the launcher expects,
#      and builds ModPatcher (needs the .NET SDK once).
#   3. Thins GameAssembly.dylib to arm64 and ad-hoc re-signs the app bundle.
#   4. Downloads the latest MelonLoader/Il2CppInterop release zip and extracts it.
#   5. Clears the com.apple.quarantine flag Gatekeeper sets on downloaded files.
#   6. Swaps BloonsTD6.app's real binary for a small wrapper that patches mods,
#      injects MelonLoader and then runs the original binary - so no Steam
#      Launch Option needs to be set by hand.
#
# All status is also shown as native macOS dialogs, since this is meant to be run
# by people who aren't comfortable reading a terminal.

set -uo pipefail

REPO_SLUG="Igorchk/MelonLoader-AppleSilicon"
TOOLCHAIN_DIR="$HOME/Documents/Coding/BTD6-Mods/MelonLoader-AppleSilicon"
DEFAULT_GAME_DIR="$HOME/Library/Application Support/Steam/steamapps/common/BloonsTD6"

tmp_zip=""
cleanup() { [ -n "$tmp_zip" ] && rm -f "$tmp_zip"; }
trap cleanup EXIT

# ---- native dialogs -------------------------------------------------------

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

# Welcome/confirm dialog with Cancel; returns 1 (and does not die) if cancelled.
gui_confirm() {
    local title message
    title="$(as_escape "$1")"
    message="$(as_escape "$2")"
    osascript <<APPLESCRIPT >/dev/null 2>&1
display dialog "$message" with title "$title" buttons {"Cancel", "Continue"} default button "Continue" cancel button "Cancel" with icon note
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
    gui_error "BTD6 Mac Mod Installer" "$1"
    exit 1
}

# ---- sanity checks ---------------------------------------------------------

command -v osascript >/dev/null 2>&1 || { echo "error: osascript not found; this installer needs a macOS desktop session" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || die "This installer only works on macOS."
[ "$(sysctl -n hw.optional.arm64 2>/dev/null)" = "1" ] || die "This installer is for Apple Silicon Macs (M1/M2/M3/M4) only."

if ! gui_confirm "BTD6 Mac Mod Installer" "Welcome to the BTD6 Mac Mod Installer.

This will locate your Bloons TD 6 install, download MelonLoader + the Apple Silicon toolchain, and set it up so the game launches modded straight from Steam - no manual Steam configuration needed."; then
    exit 0
fi

command -v git >/dev/null 2>&1 || die "git is required (install the Xcode Command Line Tools: xcode-select --install) and try again."
command -v dotnet >/dev/null 2>&1 || die "The .NET SDK is required to build the mod patcher. Install it from https://dotnet.microsoft.com/download and try again."

# ---- locate the game --------------------------------------------------------

GAME_DIR="$DEFAULT_GAME_DIR"
if [ ! -d "$GAME_DIR/BloonsTD6.app" ]; then
    attempts=0
    while [ ! -d "$GAME_DIR/BloonsTD6.app" ] && [ $attempts -lt 3 ]; do
        attempts=$((attempts + 1))
        chosen="$(gui_choose_folder "Couldn't find BloonsTD6 at the default Steam location. Locate your BloonsTD6 folder (the one containing BloonsTD6.app):")"
        [ -n "$chosen" ] || die "Installation cancelled: no BloonsTD6 folder was selected."
        GAME_DIR="${chosen%/}"
    done
    [ -d "$GAME_DIR/BloonsTD6.app" ] || die "That folder doesn't contain BloonsTD6.app. Re-run the installer and pick the correct folder."
fi

echo "Using game folder: $GAME_DIR"
mkdir -p "$GAME_DIR/Mods"

# ---- toolchain (patch_mac_mods.sh + ModPatcher) -----------------------------

if [ ! -e "$TOOLCHAIN_DIR" ]; then
    echo "Cloning toolchain into $TOOLCHAIN_DIR..."
    mkdir -p "$(dirname "$TOOLCHAIN_DIR")"
    git clone "https://github.com/$REPO_SLUG.git" "$TOOLCHAIN_DIR" || die "Couldn't clone the toolchain repository. Check your internet connection and try again."
elif [ -d "$TOOLCHAIN_DIR/.git" ]; then
    echo "Updating toolchain in $TOOLCHAIN_DIR..."
    git -C "$TOOLCHAIN_DIR" pull --ff-only || echo "warning: couldn't update the existing toolchain checkout, continuing with what's there" >&2
else
    echo "warning: $TOOLCHAIN_DIR already exists but isn't a git checkout; leaving it as-is" >&2
fi

if [ ! -f "$TOOLCHAIN_DIR/ModPatcher/bin/cecilpatch.dll" ]; then
    echo "Building ModPatcher (one-time)..."
    (cd "$TOOLCHAIN_DIR/ModPatcher" && dotnet build -c Release -o bin) || die "Building ModPatcher failed. Check that the .NET SDK is installed correctly."
fi
chmod +x "$TOOLCHAIN_DIR/patch_mac_mods.sh"

# ---- prepare the game bundle ------------------------------------------------

if [ ! -e "$HOME/BloonsTD6.app.orig" ]; then
    echo "Backing up the original app to ~/BloonsTD6.app.orig..."
    ditto "$GAME_DIR/BloonsTD6.app" "$HOME/BloonsTD6.app.orig" || die "Couldn't back up BloonsTD6.app."
fi

GAME_ASSEMBLY="$GAME_DIR/BloonsTD6.app/Contents/Frameworks/GameAssembly.dylib"
if [ -f "$GAME_ASSEMBLY" ] && ! lipo -info "$GAME_ASSEMBLY" 2>/dev/null | grep -q '^Non-fat'; then
    echo "Thinning GameAssembly.dylib to arm64..."
    thin_tmp="$(mktemp "${TMPDIR:-/tmp}/GameAssembly.XXXXXX")"
    lipo -thin arm64 "$GAME_ASSEMBLY" -output "$thin_tmp" || die "Couldn't thin GameAssembly.dylib to arm64."
    mv "$thin_tmp" "$GAME_ASSEMBLY"
fi

# ---- fetch and extract the latest MelonLoader release -----------------------

echo "Checking the latest release..."
auth_header=()
[ -n "${GITHUB_TOKEN:-}" ] && auth_header=(-H "Authorization: Bearer $GITHUB_TOKEN")
api_response="$(curl -sS -w '\n%{http_code}' -H "Accept: application/vnd.github+json" "${auth_header[@]}" "https://api.github.com/repos/$REPO_SLUG/releases/latest")"
http_code="${api_response##*$'\n'}"
release_json="${api_response%$'\n'*}"
if [ "$http_code" != "200" ]; then
    if printf '%s' "$release_json" | grep -qi "rate limit"; then
        die "GitHub is rate-limiting requests from this network right now (unauthenticated requests are capped at 60/hour). Wait a few minutes and run the installer again, or set a GITHUB_TOKEN environment variable to raise the limit."
    fi
    die "Couldn't reach GitHub to check the latest release (HTTP $http_code). Check your internet connection and try again."
fi

zip_url="$(printf '%s\n' "$release_json" \
    | grep -o '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]*MelonLoader-macOS-arm64-v[^"]*\.zip"' \
    | head -1 \
    | sed -E 's/.*"(https:[^"]+)"/\1/')"
[ -n "$zip_url" ] || die "No macOS arm64 release asset was found on GitHub."

echo "Downloading $zip_url..."
tmp_zip="$(mktemp "${TMPDIR:-/tmp}/melonloader-release.XXXXXX")"
curl -fsSL -o "$tmp_zip" "$zip_url" || die "Downloading the release zip failed."

echo "Extracting into $GAME_DIR..."
unzip -o -q "$tmp_zip" -d "$GAME_DIR" || die "Couldn't extract the release zip."
rm -f "$tmp_zip"
tmp_zip=""

chmod +x "$GAME_DIR/melonloader-launch.sh" 2>/dev/null || true

echo "Clearing the quarantine flag..."
xattr -cr "$GAME_DIR" || true

# ---- executable swap (no Steam Launch Option needed) ------------------------

MACOS_DIR="$GAME_DIR/BloonsTD6.app/Contents/MacOS"
BINARY_NAME="$(/usr/libexec/PlistBuddy -c "Print CFBundleExecutable" "$GAME_DIR/BloonsTD6.app/Contents/Info.plist" 2>/dev/null || echo BloonsTD6)"

if [ ! -f "$MACOS_DIR/${BINARY_NAME}_original" ]; then
    echo "Swapping $BINARY_NAME for the MelonLoader wrapper..."
    mv "$MACOS_DIR/$BINARY_NAME" "$MACOS_DIR/${BINARY_NAME}_original" || die "Couldn't rename the game binary."
fi

wrapper_tmp="$(mktemp "${TMPDIR:-/tmp}/btd6-wrapper.XXXXXX")"
cat > "$wrapper_tmp" <<WRAPPER
#!/bin/bash
# Generated by install.sh - runs the mod patcher, injects MelonLoader, then
# hands off to the real game binary. Re-run install.sh to refresh this file.
set -u

DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
GAME_DIR="\$(cd "\$DIR/../../.." && pwd)"
BOOTSTRAP="\$GAME_DIR/MelonLoader.Bootstrap.dylib"

export BTD6_DIR="\$GAME_DIR"
"$TOOLCHAIN_DIR/patch_mac_mods.sh" >>"\$GAME_DIR/MelonLoader/AutoPatch.log" 2>&1 || true

if [ -f "\$BOOTSTRAP" ]; then
    export DYLD_LIBRARY_PATH="\$GAME_DIR"
    if [ -n "\${STEAM_DYLD_INSERT_LIBRARIES:-}" ]; then
        export DYLD_INSERT_LIBRARIES="\$BOOTSTRAP:\$STEAM_DYLD_INSERT_LIBRARIES"
    else
        export DYLD_INSERT_LIBRARIES="\$BOOTSTRAP"
    fi
    export DOTNET_TieredCompilation=0
    # /usr/bin/arch is SIP-protected and strips DYLD_* from its own env, so pass
    # them with -e; Steam runs this from an x86_64/Rosetta process tree, and a
    # plain exec would otherwise pick the game binary's x86_64 slice.
    exec /usr/bin/arch -arm64 \\
        -e "DYLD_INSERT_LIBRARIES=\$DYLD_INSERT_LIBRARIES" \\
        -e "DYLD_LIBRARY_PATH=\$DYLD_LIBRARY_PATH" \\
        "\$DIR/${BINARY_NAME}_original" "\$@"
fi

exec "\$DIR/${BINARY_NAME}_original" "\$@"
WRAPPER
chmod +x "$wrapper_tmp"
mv "$wrapper_tmp" "$MACOS_DIR/$BINARY_NAME"

# Signed last, now that the wrapper is the bundle's main executable: codesign
# resolves Contents/MacOS/$BINARY_NAME from Info.plist, so signing any earlier
# (while it was still the real, Mach-O game binary) gets thrown away the moment
# that file is renamed out from under it - the bundle would seal a path that no
# longer holds a signable binary. --deep still signs BloonsTD6_original (now a
# nested executable) with its own ad-hoc signature, which is what actually
# matters for .NET's allow-jit requirement once the wrapper execs it.
echo "Re-signing the app bundle..."
codesign --force --deep --sign - "$GAME_DIR/BloonsTD6.app" || die "Couldn't re-sign BloonsTD6.app."

gui_note "BTD6 Mac Mod Installer" "Installation Complete! You can now launch BTD6 directly from Steam."
echo "Done."
