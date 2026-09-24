# wine-auto-dpi-setting

A Bash pre-run script for [Bottles](https://usebottles.com/) (Flatpak) that
automatically sets the correct Wine DPI for every program launch, so Windows
applications running under Wine render at the right size on a scaled Linux
Mint (Cinnamon) desktop — instead of always defaulting to 96 DPI (100%)
regardless of what the actual display scale is set to.

## The problem this solves

By default, Wine renders every application's UI at 96 DPI (Windows' 100%
scaling baseline), no matter what scale the Linux desktop itself is set to.
On a Cinnamon desktop scaled to, say, 150%, this means Windows apps run
through Wine/Bottles look noticeably **too small** compared to every native
Linux application on the same screen — tiny text, tiny buttons, tiny icons.

Wine *can* be told to use a different DPI via a registry value
(`HKCU\Control Panel\Desktop\LogPixels`, the same value `winecfg`'s Graphics
tab controls), but:

- It has to be set **per Wine prefix** (per Bottles "bottle"), and Bottles
  offers no built-in way to keep it automatically in sync with your current
  Cinnamon display scale.
- If you use a portable Linux Mint install across multiple machines with
  different screens/scaling settings (as this was originally built for),
  a value that's correct on one machine will be wrong on another.
- The "obvious" value to compute isn't actually the correct one — see
  [How DPI detection works](#how-dpi-detection-works) below.

This script solves all of that: point it at every program in Bottles as a
**pre-run script**, and it detects the correct DPI and writes it to the
registry automatically, every time, before the program starts — no manual
`winecfg` fiddling, and it stays correct even if you move the machine or
change the display scale later.

## Benefits at a glance

- **Fully automatic** — set it once per program in Bottles; never touch
  `winecfg`'s DPI slider by hand again.
- **Runs on every launch**, so it always reflects your *current* display
  scale, even if you change it between sessions.
- **No manual registry editing** required.
- **Self-contained inside the Bottles Flatpak sandbox** — does not require
  granting Bottles any extra permissions (no `flatpak-spawn --host`, no
  `flatpak override`, nothing to configure via Flatseal).
- **Fixes a separate, unrelated Wine bug along the way**: it also resolves
  and calls the *exact* wine binary your bottle's runner uses (see
  [Bonus fix](#bonus-fix-wineserver-version-mismatch) below), rather than
  whatever `wine` happens to resolve to on `$PATH` — which can otherwise be
  a different Wine version than the one already running for that prefix
  and cause a `wine client error: version mismatch` failure.
- **Optional built-in debug mode** (`VERBOSE=1`) that reports exactly what
  it detected, and why, as a desktop notification — no terminal needed.

## Requirements

- Linux Mint (or any Linux Mint-based/Cinnamon distribution) running a
  **Cinnamon X11 session** (the current default). See
  [Limitations](#limitations--wayland) for what happens on Wayland.
- [Bottles](https://usebottles.com/) installed via Flatpak.
- `python3` and `libX11.so.6` available inside the Bottles Flatpak sandbox.
  These do not need to be installed separately — `python3` is present
  because Bottles itself is written in Python, and `libX11.so.6` is present
  because Wine itself links against it.

No other packages are required. In particular, this script does **not**
need the `xrdb` command-line tool to be installed (it reads the same
underlying X11 data directly via Python, for exactly this reason), although
it will use `xrdb` as a fallback if it happens to be present.

## Installation / usage

1. Save `wine-auto-dpi-setting.sh` somewhere permanent on disk (e.g.
   `~/Scripts/wine-auto-dpi-setting.sh`).
2. Make it executable:
   ```bash
   chmod +x ~/Scripts/wine-auto-dpi-setting.sh
   ```
3. In Bottles, for **each program** you want this applied to: open the
   bottle → find the program under **Programs** → click its **⋮** menu →
   **Advanced Options** (or the equivalent gear/settings icon) → set
   **Pre-run script** to the full path of `wine-auto-dpi-setting.sh`.
4. Repeat step 3 for every program, in every bottle, where you want correct
   DPI scaling. That's it — no further configuration needed.

### Optional: debug mode

Set the environment variable `VERBOSE=1` before the script runs (for
example, by testing it manually from a terminal) to get a single desktop
notification at the end of the run, summarizing:

- Which detection method succeeded (or why each one failed, in order).
- The raw DPI value detected and its equivalent display-scale percentage.
- The final DPI value applied, and which exact wine binary / prefix it was
  applied to.

Nothing is printed to the terminal in verbose mode — everything goes
through the desktop notification, since Bottles normally launches programs
with no visible terminal attached anyway.

## How DPI detection works

The script tries the following methods, in order, stopping at the first
one that succeeds:

1. **`libX11` via Python `ctypes`** (primary method) — reads the `Xft.dpi`
   X11 resource directly from the running X server by calling the same
   underlying C functions `xrdb -query` itself uses
   (`XOpenDisplay`/`XResourceManagerString`), without needing the `xrdb`
   binary to be installed.
2. **`xrdb -query`** (fallback) — used only if the method above fails, and
   only works if `xrdb` happens to be installed inside the sandbox.
3. **Hard-coded default of 96 DPI (100%)** — used only if both of the
   above fail, so the script always produces *some* safe value rather than
   erroring out or leaving the registry untouched.

### Why the raw value is used, not a "corrected" fractional value

Cinnamon publishes `Xft.dpi` as `96 × ceil(display_scale)` — e.g. at 150%
scaling, `Xft.dpi` is `96 × ceil(1.5) = 192` (equivalent to 200%), **not**
`96 × 1.5 = 144`. It's tempting to assume this "ceiling" value is wrong and
that Wine should be given the true fractional value (144) instead — this
was in fact tried and initially seemed to make sense in theory.

However, it was tested directly by comparing side-by-side screenshots of a
Wine application against native Cinnamon applications at the same real
scale setting, and confirmed that using the **raw, un-corrected `Xft.dpi`
value** (192, in the 150% example) renders Wine applications at the
*correct* size relative to the rest of the desktop. This is because
Cinnamon's own screen scaling already accounts for the difference at a
lower level (it renders the whole desktop at the ceiling resolution and
scales the result back down for display), so re-correcting for it a second
time inside Wine actually produces the wrong (too small) result.

**In short: use `Xft.dpi` exactly as Cinnamon reports it. Don't try to be
clever and "fix" it into a fractional value — that was tried and confirmed
wrong.**

## Bonus fix: wineserver version mismatch

Independently of DPI detection, this script also resolves the *exact* wine
binary belonging to the bottle's configured runner (by reading the
`Runner:` field out of the bottle's own `bottle.yml` config file) and
always calls that exact binary, rather than whatever plain `wine` resolves
to via `$PATH`.

This matters because, inside the Bottles Flatpak sandbox, `$PATH` can
resolve `wine` to Bottles' own bundled base Wine runtime
(`/app/bin/wine`) — which is typically a **different version** than the
runner the bottle is actually configured to use (e.g. `soda-11.0-10`). If
the wine binary used to write the registry value is a different version
than the `wineserver` daemon already running for that prefix, Wine refuses
the connection with:

```
wine client error:0: version mismatch 930/931.
Your wineserver binary was not upgraded correctly, ...
```

and the registry write silently fails. Resolving the runner-specific
binary directly avoids this failure mode entirely.

## Limitations / Wayland

This script has only been tested and confirmed correct under a **Cinnamon
X11 session** — Linux Mint's current default desktop session. If, in the
future, you switch to a Cinnamon **Wayland** session (available as an
alternative option from the login screen since Cinnamon 6.0, and planned
to reach full, non-experimental support in Linux Mint 23 / Cinnamon 6.8),
or if the Wine runner in use switches to its native Wayland driver
(`winewayland.drv`) instead of the X11 driver (`winex11.drv`):

- The detection methods in this script (both of which talk to an X11
  display) may fail entirely, causing the script to fall back to the
  default 96 DPI regardless of the actual scale.
- Even if an X11 display is still reachable (e.g. via XWayland
  compatibility), the underlying scaling mechanism that makes the "use the
  raw ceiling `Xft.dpi` value" approach correct (see above) is specific to
  how Cinnamon's X11 session scales its framebuffer, and has **not** been
  verified to hold under Wayland/XWayland.

**If you do switch to a Wayland session, re-verify DPI correctness the
same way it was originally confirmed here** — by comparing a screenshot of
a Wine application side-by-side with a native Cinnamon application at the
same scale setting — before trusting this script's output. As of writing,
Linux Mint's default session is still X11 and there is no announced
timeline for changing that default, so this is expected to remain correct
for the foreseeable future on a standard Mint installation.

## Version

- **v1.0** — Initial release.

## Author

Adul Tanthuvanit
