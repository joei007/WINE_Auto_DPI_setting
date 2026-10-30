#!/usr/bin/env bash
#
# wine-auto-dpi.sh — v1.0
# Copyright (c) Adul Tanthuvanit
#
# WHAT THIS DOES
# ---------------
# Sets the Wine DPI registry value (HKCU\Control Panel\Desktop\LogPixels)
# to match the current Cinnamon display scale, so that Wine/Windows
# applications render UI elements at the correct physical size instead
# of the Wine default (96 DPI / 100%) regardless of what the Linux
# desktop is actually scaled to.
#
# WHY THE RAW "CEILING" DPI VALUE IS USED
# ----------------------------------------
# Cinnamon publishes an X11 resource called "Xft.dpi" that is computed as:
#     Xft.dpi = 96 * ceil(display_scale)
# e.g. at 150% scaling, Xft.dpi = 96 * ceil(1.5) = 96 * 2 = 192, NOT 144.
# It would seem natural to instead compute the "true" fractional DPI
# (96 * 1.5 = 144), but that was tested and confirmed WRONG by side-by-side
# screenshot comparison against native Cinnamon apps: using the raw
# ceiling value (192) renders Wine apps at the correct size, because
# Cinnamon's own framebuffer scaling (render at the ceiling resolution,
# then scale the whole screen back down for display) already accounts
# for the difference. Using the "true" fractional value under-scales
# Wine apps relative to the rest of the desktop.
# This script therefore reads Xft.dpi as-is and uses it directly — no
# fractional-scale math is performed.
#
# SANDBOX-ONLY DESIGN (no host access needed)
# ---------------------------------------------
# This script is fully self-contained inside the Bottles Flatpak sandbox.
# It does NOT call flatpak-spawn --host and does NOT require granting
# Bottles any extra Flatpak permission (such as --talk-name=
# org.freedesktop.Flatpak). Everything it does — reading Xft.dpi via
# libX11, reading the bottle's own config file, sending a desktop
# notification via the Flatpak portal — works with the sandbox's default,
# unmodified permission set.
#
# LIMITATIONS / KNOWN SCOPE
# ---------------------------
# - Tested and confirmed correct only under a Cinnamon **X11** session
#   (Linux Mint's current default). If the desktop session is switched to
#   Cinnamon on Wayland, or if the underlying Wine runner switches to its
#   native Wayland driver (winewayland.drv) instead of winex11.drv, the
#   detection logic and/or the "use the ceiling value" assumption may no
#   longer hold and should be re-verified (see README.md).
# - Only reads/sets DPI for the CURRENT USER's registry hive (HKCU).
#
# USAGE
# -----
#   In Bottles: open the bottle -> the program's "..." menu -> Advanced
#   Options -> Pre-run script -> point it at this file's path. Repeat for
#   every program in every bottle where you want DPI corrected before the
#   program starts. See README.md for full setup instructions.
#
#   Optional debug mode: run/launch with the environment variable
#   VERBOSE=1 set. This does NOT print anything to the terminal (there is
#   no terminal to see it in when Bottles launches a program normally);
#   instead it collects every diagnostic message produced during the run
#   and sends them as a single desktop notification once the script
#   finishes, so you can see exactly what was detected and why, directly
#   on the Cinnamon desktop.

set -uo pipefail

# --- configuration ---

# Read from the environment; "0" (verbose off) unless the caller sets
# VERBOSE=1 before invoking this script (e.g. via Bottles' pre-run script
# mechanism, or by hand in a terminal for testing).
VERBOSE="${VERBOSE:-0}"

# DPI value used whenever detection fails completely. 96 DPI corresponds
# to Windows' traditional 100% scaling baseline, and is the safest
# assumption when we genuinely don't know the real display scale — it
# keeps Wine apps at their normal, unscaled size rather than guessing
# and potentially rendering them far too large or too small.
DEFAULT_DPI=96

# --- verbose logging setup ---
#
# Log messages are collected in a temporary FILE, not a plain shell
# variable. This matters because several functions below (get_dpi_from_x11,
# get_dpi_from_xrdb, detect_dpi, resolve_wine_binary) are invoked through
# "$(...)" command substitution, and bash runs command substitutions in a
# forked SUBSHELL. Any variable a subshell modifies (e.g. appending to a
# "VERBOSE_LOG" string) only exists inside that subshell's own memory —
# once the subshell exits and control returns to the parent script, those
# changes are gone. A real file, on the other hand, is a filesystem-level
# change and is therefore visible from every subshell and from the parent
# script alike, so it survives all of this script's internal command
# substitutions.
LOG_FILE=""
if [ "$VERBOSE" = "1" ]; then
    # mktemp is preferred (handles uniqueness/race conditions properly);
    # fall back to a PID-suffixed path in the unlikely case mktemp itself
    # is unavailable, so verbose mode still degrades gracefully instead
    # of failing outright.
    LOG_FILE=$(mktemp -t wine-auto-dpi.XXXXXX 2>/dev/null || echo "/tmp/wine-auto-dpi.$$")
    # Always clean up the temp file when the script exits, however it exits
    # (normal completion, early "exit 0" on a guard clause, etc.).
    trap 'rm -f "$LOG_FILE"' EXIT
fi

# log MESSAGE
# Appends MESSAGE as a new line in $LOG_FILE, but only when VERBOSE=1.
# Does nothing (cheaply) when verbose mode is off, so normal/non-debug
# runs pay no overhead for logging. Messages are never printed directly
# to stdout/stderr — see the "notify" function below for how they
# eventually reach the user, as a single desktop notification.
log() {
    if [ "$VERBOSE" = "1" ] && [ -n "$LOG_FILE" ]; then
        echo "$*" >> "$LOG_FILE"
    fi
}

# round_int NUMBER
# Rounds NUMBER (which may be an integer or a decimal, e.g. "192" or
# "191.7") to the nearest whole number and prints it. Returns failure
# (exit 1, prints nothing) if NUMBER is empty/unset, so callers can use
# it safely inside "&&" chains without risking a stray empty argument
# being passed to printf (which previously caused a crash before this
# guard was added).
round_int() {
    local n="${1:-}"
    if [ -z "$n" ]; then
        return 1
    fi
    awk -v n="$n" 'BEGIN { printf "%.0f", n }'
}

# notify TITLE MESSAGE
# Sends a desktop notification with the given TITLE and MESSAGE body via
# the Flatpak Notification portal (org.freedesktop.portal.Notification).
# Portal calls are always allowed for every Flatpak sandbox by design —
# unlike most D-Bus names, no extra --talk-name permission needs to be
# granted to Bottles for this to work, which is why this script can stay
# fully self-contained (see the header comment above).
# Silently does nothing if the "gdbus" tool isn't available, so a missing
# gdbus never breaks the actual DPI-setting logic — notifications are a
# nice-to-have for debugging, not a requirement for correct operation.
notify() {
    local title="$1"
    local message="$2"
    command -v gdbus >/dev/null 2>&1 || return 0
    # Escape any single quotes in the message so they can't break out of
    # the single-quoted GVariant string literal built below.
    message="${message//\'/\\\'}"
    gdbus call --session \
        --dest org.freedesktop.portal.Desktop \
        --object-path /org/freedesktop/portal/desktop \
        --method org.freedesktop.portal.Notification.AddNotification \
        "wine-auto-dpi" \
        "{'title': <'$title'>, 'body': <'$message'>}" >/dev/null 2>&1
}

# resolve_wine_binary
# Finds the wine binary that belongs to THIS bottle's configured runner.
# Prints exactly one line: "OK:<absolute path>" on success, or
# "FAIL:<reason>" on failure (same convention as the DPI detection
# functions below, so the caller can report the exact reason).
#
# Two kinds of runner are handled:
#   1. Downloaded runners (e.g. "soda-11.0-10", "ge-proton11-11"): their
#      wine lives in a folder under <bottles_data_dir>/runners/ and is
#      looked up there.
#   2. The built-in Wine ("sys-wine-*", shown as "Built-in Wine" in the
#      Bottles UI): it has NO folder under runners/. It is the Wine that
#      ships inside the Bottles Flatpak itself (/app/bin/wine), so for
#      this runner type -- and only this one -- the wine on $PATH IS the
#      bottle's own wine, not a substitute.
#
# For downloaded runners there is deliberately NO fallback to whatever
# "wine" resolves to on $PATH. If the runner's own binary cannot be
# located, something is abnormal (the bottle config is unreadable, the
# runner is not installed, or it uses a directory layout this script does
# not know about), and silently substituting a different wine is exactly
# what causes trouble: the built-in /app/bin/wine is usually a DIFFERENT
# version than a downloaded runner (e.g. "soda-11.0-10"). Calling a
# mismatched wine against the prefix's running wineserver fails with a
# "version mismatch" client error, and can leave the program unable to
# start. Reporting a clear error is safer than guessing.
#
# bottle.yml lives directly inside $WINEPREFIX itself (alongside the
# drive_c folder), so this needs no access outside the sandbox or outside
# $WINEPREFIX — it is pure local file reading.
resolve_wine_binary() {
    local bottle_yml="$WINEPREFIX/bottle.yml"
    if [ ! -f "$bottle_yml" ]; then
        echo "FAIL:bottle.yml not found at $bottle_yml"
        return 1
    fi

    # Extract the value of the top-level "Runner:" key. Strips optional
    # surrounding quotes and whitespace, since YAML values may or may
    # not be quoted (e.g. "Runner: soda-11.0-10" vs "Runner: 'soda-11.0-10'").
    local runner
    runner=$(grep -m1 '^Runner:' "$bottle_yml" | sed -E "s/^Runner:[[:space:]]*['\"]?//; s/['\"][[:space:]]*\$//")
    if [ -z "$runner" ]; then
        echo "FAIL:no 'Runner:' entry found in $bottle_yml"
        return 1
    fi

    # Built-in Wine: the runner name starts with "sys-" (e.g. "sys-wine-11.0")
    # and there is no runner folder to look in. Use the wine on $PATH,
    # which inside the Bottles Flatpak is the built-in /app/bin/wine -- the
    # same binary (and therefore the same version as the wineserver) that
    # Bottles itself uses for this bottle.
    if [[ "$runner" == sys-* ]]; then
        local system_wine
        system_wine=$(command -v wine)
        if [ -z "$system_wine" ]; then
            echo "FAIL:runner '$runner' uses the built-in Wine, but no wine was found on \$PATH"
            return 1
        fi
        echo "OK:$system_wine"
        return 0
    fi

    # Bottles' data layout is:
    #   <bottles_data_dir>/bottles/<BottleName>/       <- $WINEPREFIX
    #   <bottles_data_dir>/runners/<runner-name>/...   <- the runner
    # so walking up two directories from $WINEPREFIX gets us to
    # <bottles_data_dir>, from which the runner's folder can be located.
    local bottles_data_dir runner_dir
    bottles_data_dir="$(dirname "$(dirname "$WINEPREFIX")")"
    runner_dir="$bottles_data_dir/runners/$runner"

    # Where the wine binary sits inside the runner folder depends on the
    # runner type:
    #   <runner>/bin/wine          Wine-based runners (e.g. soda-*, caffe-*)
    #   <runner>/files/bin/wine    Proton-based runners (e.g. ge-proton*),
    #                              which keep the Wine build under "files/"
    # Both known layouts are checked, in this order. Anything else is
    # treated as an error (see the comment at the top of this function).
    local candidate
    for candidate in "$runner_dir/bin/wine" "$runner_dir/files/bin/wine"; do
        if [ -x "$candidate" ]; then
            echo "OK:$candidate"
            return 0
        fi
    done

    echo "FAIL:wine binary of runner '$runner' not found/executable at $runner_dir/bin/wine or $runner_dir/files/bin/wine"
    return 1
}

# get_dpi_from_x11
# PRIMARY detection method. Reads the "Xft.dpi" X11 resource directly
# from the running X server, by loading libX11 with Python's ctypes
# module (Python's C foreign-function-interface bridge) and calling the
# same underlying C functions the "xrdb -query" command itself uses
# internally (XOpenDisplay, then XResourceManagerString).
#
# This avoids depending on the "xrdb" command-line tool being installed
# at all — it is NOT present by default inside the Bottles sandbox on
# every system, whereas python3 (Bottles itself is written in Python) and
# libX11.so.6 (Wine itself links against it) are both effectively
# guaranteed to already be present, with no extra packages required.
# Only the X11 socket is needed, which the sandbox already has full,
# unrestricted access to.
#
# NOTE ON ctypes ARGTYPES: XOpenDisplay's and XResourceManagerString's
# .argtypes are explicitly declared below. Without this, ctypes defaults
# to assuming C `int` (32-bit) arguments; the X11 Display* pointer
# returned by XOpenDisplay is a full 64-bit value, and passing it into
# XResourceManagerString without an explicit c_void_p argtype caused it
# to be silently truncated, which reliably segfaulted the Python
# interpreter. This was diagnosed and fixed during development — do not
# remove these two .argtypes lines.
#
# OUTPUT CONVENTION: always prints exactly one line, either "OK:<value>"
# on success or "FAIL:<reason>" on failure — never prints nothing and
# never prints multiple lines. This lets detect_dpi() (below) log the
# *specific* reason a method failed, instead of only knowing that it did.
get_dpi_from_x11() {
    if ! command -v python3 >/dev/null 2>&1; then
        echo "FAIL:python3 not found in \$PATH"
        return 1
    fi

    local result rc
    result=$(python3 -c '
import ctypes, sys
try:
    x11 = ctypes.CDLL("libX11.so.6")
except OSError as e:
    print("FAIL:could not load libX11.so.6 (" + str(e) + ")")
    sys.exit(0)
# Explicit argtypes are required here — see the "NOTE ON ctypes ARGTYPES"
# comment above this function in the bash source. Omitting these caused a
# segfault (ctypes defaults to 32-bit int arguments, which truncates the
# 64-bit Display* pointer passed into XResourceManagerString).
x11.XOpenDisplay.argtypes = [ctypes.c_char_p]
x11.XOpenDisplay.restype = ctypes.c_void_p
x11.XResourceManagerString.argtypes = [ctypes.c_void_p]
x11.XResourceManagerString.restype = ctypes.c_char_p
try:
    # None -> NULL -> "use the $DISPLAY environment variable", exactly
    # like calling xrdb/xprop with no explicit -display argument.
    display = x11.XOpenDisplay(None)
except Exception as e:
    print("FAIL:XOpenDisplay raised (" + str(e) + ")")
    sys.exit(0)
if not display:
    print("FAIL:XOpenDisplay returned NULL (no X11 display / $DISPLAY not set)")
    sys.exit(0)
res = x11.XResourceManagerString(display)
if not res:
    print("FAIL:XResourceManagerString returned NULL (RESOURCE_MANAGER property empty)")
    sys.exit(0)
# The RESOURCE_MANAGER string is a newline-separated list of
# "ResourceName:\tValue" pairs (the same format xrdb -query prints).
# Xft.dpi is the one line we actually care about.
text = res.decode("utf-8", "ignore")
for line in text.splitlines():
    if line.startswith("Xft.dpi:"):
        print("OK:" + line.split(":", 1)[1].strip())
        sys.exit(0)
print("FAIL:RESOURCE_MANAGER has no Xft.dpi entry")
' 2>&1)
    rc=$?

    # An entirely empty result (no "OK:"/"FAIL:" line at all) means the
    # python3 process was killed outright rather than exiting normally —
    # most likely a crash such as a segfault. When a process dies from a
    # signal, the shell itself prints a message like "Segmentation fault
    # (core dumped)" to its OWN stderr, which is NOT the same file
    # descriptor this function's "2>&1" captured (that only redirects the
    # python3 process's own stdout/stderr into $result) — so a crash like
    # this produces a genuinely empty $result rather than a helpful error
    # message. Surface the raw exit code so this case is still
    # diagnosable instead of silently looking identical to "no output".
    if [ -z "$result" ]; then
        echo "FAIL:python3 produced no output at all, exit code $rc (likely crashed/killed by a signal — 139 = segfault; run 'python3 -c ...' manually to see the real error)"
        return 1
    fi

    echo "$result"
    [[ "$result" == OK:* ]]
}

# get_dpi_from_xrdb
# FALLBACK detection method, used only if get_dpi_from_x11 above fails.
# Simply shells out to the "xrdb" command-line tool, in case it happens
# to be installed on this particular system (it is not part of the
# Bottles Flatpak sandbox by default, but nothing stops a user from
# installing x11-xserver-utils on the host and this method benefiting
# from it automatically). Same "OK:<value>" / "FAIL:<reason>" output
# convention as get_dpi_from_x11, for consistent logging in detect_dpi().
get_dpi_from_xrdb() {
    if ! command -v xrdb >/dev/null 2>&1; then
        echo "FAIL:xrdb command not found in \$PATH"
        return 1
    fi

    local xft_dpi
    xft_dpi=$(xrdb -query 2>/dev/null | awk -F: '/^Xft\.dpi/ {gsub(/[[:space:]]/, "", $2); print $2}')
    if [ -n "${xft_dpi:-}" ]; then
        echo "OK:$xft_dpi"
        return 0
    fi
    echo "FAIL:xrdb ran but output had no Xft.dpi line"
    return 1
}

# detect_dpi
# Orchestrates the detection methods above in priority order (libX11
# first, then xrdb, then a hard-coded default), logging a clear,
# human-readable explanation of what was tried and what the outcome was
# at every step. Always prints exactly one integer DPI value on success
# — this function never fails; if every real detection method fails, it
# deliberately falls back to DEFAULT_DPI so the calling program still
# gets a sane, safe value instead of the script aborting.
detect_dpi() {
    local result value dpi percent

    # --- Tier 1: libX11 via ctypes (see get_dpi_from_x11 for why this is
    # tried first) ---
    result=$(get_dpi_from_x11)
    if [[ "$result" == OK:* ]]; then
        value="${result#OK:}"
        dpi=$(round_int "$value")
        if [ -n "$dpi" ]; then
            # Purely for readability in the debug notification — shows
            # the equivalent display-scale percentage alongside the raw
            # DPI number, since "192 DPI" alone isn't obviously "200%"
            # to someone reading the log.
            percent=$(awk -v d="$dpi" 'BEGIN { printf "%.0f", (d/96)*100 }')
            log "Detect scale: libX11 Xft.dpi=$value -> $dpi DPI (~${percent}% scale)"
            log "Set WineDPI (LogPixels) = $dpi"
            echo "$dpi"
            return 0
        fi
        log "libX11 method returned '$value' but it wasn't a usable number"
    else
        log "libX11 method failed: ${result#FAIL:}"
    fi

    # --- Tier 2: xrdb binary, if installed ---
    result=$(get_dpi_from_xrdb)
    if [[ "$result" == OK:* ]]; then
        value="${result#OK:}"
        dpi=$(round_int "$value")
        percent=$(awk -v d="$dpi" 'BEGIN { printf "%.0f", (d/96)*100 }')
        log "Detect scale: xrdb Xft.dpi=$value -> $dpi DPI (~${percent}% scale)"
        log "Set WineDPI (LogPixels) = $dpi"
        echo "$dpi"
        return 0
    else
        log "xrdb fallback failed: ${result#FAIL:}"
    fi

    # --- Tier 3: give up, use the safe default ---
    log "All detection methods failed — using fallback DPI = $DEFAULT_DPI (100% scale)"
    log "Set WineDPI (LogPixels) = $DEFAULT_DPI (fallback)"
    echo "$DEFAULT_DPI"
    return 0
}

# =====================================================================
# --- main ---
# =====================================================================
# Everything above this point only defines functions/configuration and
# has no side effects yet. Execution of the actual program logic starts
# here, top to bottom.

# $WINEPREFIX is set automatically by Bottles when it runs this script as
# a program's pre-run script, pointing at that specific bottle's prefix
# directory. If it's missing, this script isn't running in the context
# it expects (e.g. it was run directly without setting the variable), so
# there's nothing safe to do — exit quietly rather than guessing which
# bottle to modify.
if [ -z "${WINEPREFIX:-}" ]; then
    log "WINEPREFIX not set — skipping DPI setup"
    exit 0
fi

# Figure out exactly which wine binary belongs to this bottle (see
# resolve_wine_binary's own comment block for why this can't just be a
# plain "wine" call, and why there is no $PATH fallback).
WINE_RESULT=$(resolve_wine_binary)
if [[ "$WINE_RESULT" != OK:* ]]; then
    # Not being able to find the runner's own wine binary is abnormal, so
    # it is reported as an error notification ALWAYS — not only in
    # VERBOSE mode — and the DPI setup is skipped entirely instead of
    # guessing with a different wine. Exits with 0 on purpose: this
    # script only adjusts the DPI, and a failure here must not stop
    # Bottles from launching the program itself. The registry is left
    # exactly as it was.
    ERROR_REASON="${WINE_RESULT#FAIL:}"
    log "ERROR: $ERROR_REASON — DPI setup skipped"
    notify "Wine DPI Sync (error)" "Cannot find the wine binary for this bottle's runner, so the DPI was NOT changed. ${ERROR_REASON}"
    exit 0
fi
WINE_BIN="${WINE_RESULT#OK:}"
log "Resolved wine binary from bottle.yml: $WINE_BIN"

# Figure out what DPI value to apply.
DPI=$(detect_dpi)

# Sanity-check the final value before writing it to the registry. 48 DPI
# (50%) and 480 DPI (500%) are far outside any real-world display scaling
# range; a value outside this range almost certainly indicates a bug
# somewhere in detection (e.g. a stray non-numeric string slipping
# through) rather than a genuine display configuration, so fall back to
# the safe default instead of writing something nonsensical to the
# registry.
if ! [[ "$DPI" =~ ^[0-9]+$ ]] || [ "$DPI" -lt 48 ] || [ "$DPI" -gt 480 ]; then
    log "Detected DPI ($DPI) is out of the sane range (48-480), overriding with fallback $DEFAULT_DPI"
    DPI=$DEFAULT_DPI
fi

log "Applying to bottle: WineDPI (LogPixels) = $DPI, wine=$WINE_BIN, WINEPREFIX=$WINEPREFIX"

# The actual registry write. Uses the exact runner-specific wine binary
# resolved above (never a bare "wine" that would search $PATH) to avoid
# the wineserver version-mismatch problem described in resolve_wine_binary.
# HKCU\Control Panel\Desktop\LogPixels is the same registry value winecfg's
# own Graphics tab reads/writes for its DPI slider.
"$WINE_BIN" reg add "HKCU\Control Panel\Desktop" /v LogPixels /t REG_DWORD /d "$DPI" /f >/dev/null 2>&1

# If verbose logging collected anything, send it as a single desktop
# notification now. Deliberately batched into ONE notification (rather
# than one notification per log() call) to avoid spamming multiple
# notification popups for a single program launch.
if [ "$VERBOSE" = "1" ] && [ -n "$LOG_FILE" ] && [ -s "$LOG_FILE" ]; then
    notify "Wine DPI Sync (debug)" "$(cat "$LOG_FILE")"
fi

exit 0
