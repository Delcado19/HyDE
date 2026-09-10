# Install notes — CachyOS (Hyprland+Noctalia edition) + HyDE, 2026-09-10

Notes from a clean CachyOS install (Hyprland selected as WM during the CachyOS
installer) followed by `./install.sh` from this repo. Kept here as a record of
what went wrong and what was done about it.

**Root cause, in hindsight:** this repo's own `README.md` already says so —

> Line 71: "The installation script is designed for a minimal Arch Linux
> install, but **may** work on some Arch-based distros."
>
> Line 87: "[...] especially when HyDE is being installed alongside an
> existing desktop environment [...]" (recommends a Timeshift snapshot first)

CachyOS's "Hyprland + Noctalia" installer option is not a minimal Arch
install — it ships a fully configured desktop environment (Noctalia shell,
its own Hyprland Lua config, greetd) out of the box. `install.sh` is not
designed to be layered on top of that, and nearly everything below (§1–§5)
traces back to this one mismatch. Neither "CachyOS" nor "Noctalia" is named
explicitly in the README, but the general warning already covers this exact
scenario. Takeaway for next time: either pick a minimal/no-DE CachyOS
profile before running `install.sh`, or budget time for exactly this kind of
cleanup.

**Confirmed, 2026-09-10:** installing this fork's `main` branch on a CachyOS
system installed *without* a window manager preselected (i.e. no
Hyprland+Noctalia preset, no pre-existing desktop environment) went through
cleanly, with none of the issues in §1–§5 below. This matches the root-cause
theory above — the problems trace back to `install.sh` being layered on top
of an already-configured DE, not to `install.sh` itself.

## 1. `install.sh` hangs indefinitely during theme apply

**Symptom:** `install.sh` (via `theme.switch.sh -q`) hangs forever, seemingly
stuck after the `linking :: Wallbash-Gtk to ~/.themes` log line. No further
output, no error, no progress. Reproduced on **two separate runs**.

**Cause:** `~/.local/lib/hyde/wallpaper.awww.sh` starts the wallpaper daemon
like this:

```sh
awww-daemon --format xrgb &
```

without redirecting its stdio. This call happens inside a command
substitution in `theme.switch.sh`:

```sh
wallpaper_output="$("$LIB_DIR/hyde/wallpaper.sh" -s "$theme_wallpaper" --global 2>&1)"
```

`awww-daemon` is a long-running process that inherits the pipe's write end
and never closes it, so the `$(...)` capture never sees EOF and blocks
forever, even though the actual wallpaper-setting work is long done.

**Workaround used:** `kill` the stray `awww-daemon` process manually once the
hang is identified (`ps` shows the `theme.switch.sh` process blocked in
`anon_pipe_read`, with `awww-daemon` holding the pipe's other end). This
unblocks the script immediately.

**Suggested real fix:** redirect the daemon's stdio when backgrounding it,
e.g. `awww-daemon --format xrgb &>/dev/null &` (or `disown` it), so it can't
hold open a pipe it has no business writing to.

## 2. `sddm` can't be enabled — conflicts with `greetd`

**Symptom:**
```
[exec] Service sddm (root): enable
Failed to enable unit: File '/etc/systemd/system/display-manager.service' already exists and is a symlink to /usr/lib/systemd/system/greetd.service
```

**Cause:** CachyOS's Hyprland+Noctalia edition ships with `greetd` as the
active display manager. `install.sh`'s `restore_svc.sh` step tries
`sudo systemctl enable sddm` but never touches the existing
`display-manager.service` symlink, so the `systemctl enable` call fails
(non-fatally — the script continues and finishes normally either way).

**Workaround used:**
```sh
sudo systemctl disable greetd
sudo systemctl enable sddm
```
then reboot. Login via SDDM (with a HyDE theme, e.g. Candy/Corners) then
works fine.

**Suggested real fix:** `restore_svc.sh` (or an earlier install step) should
detect a conflicting display-manager symlink and either ask the user or
force-switch it, instead of silently leaving the system on the old DM.

## 3. CachyOS's Noctalia/Hyprland config coexists with HyDE's own config —
duplicate autostart, duplicate/conflicting keybinds

**Symptom:** After a successful install + reboot, both HyDE's own stack
(Waybar, hyprlock, hypridle, rofi, swaync/dunst, ...) *and* CachyOS's
`Noctalia` shell were running simultaneously. Also: Noctalia's accent colors
were bleeding into kitty, GTK3, Qt5/Qt6, btop, and alacritty instead of
HyDE's Wallbash/Catppuccin Mocha theming.

**Cause:** `install.sh` deploys `~/.config/hypr/hyprland.lua` as a *merge*
of two layers, both active at once:

```lua
-- top of the file: HyDE's own config, loaded via dofile()
if not hyde then
    ...
    dofile(entry)  -- ~/.local/share/hypr/hyde.lua — HyDE's full config
end

-- bottom of the file: kept verbatim from the CachyOS/Noctalia skeleton
require("config.animations")
require("config.autostart")   -- launches `noctalia`
require("config.colors")
require("config.decorations")
require("config.variables")
require("config.environment")
require("config.inputs")
require("config.binds")       -- binds SUPER+L, SUPER+V, Print, XF86Audio*, etc.
                               -- to `noctalia msg ...`
require("config.misc")
require("config.monitors")
require("config.windowrules") -- has a Noctalia-specific window rule
require("config.workspaces")
```

The `config/*.lua` files originate from `/etc/skel/.config/hypr/config/`
(package `cachyos-hypr-noctalia`), copied into the home directory when the
user account was created — *before* HyDE was ever installed. `install.sh`'s
dotfile deployer reported `hyprland.lua` as **"1 adopted"** during install,
meaning it kept/merged with the pre-existing file instead of fully replacing
it, which is how both layers ended up wired together.

Because Hyprland-lua's `hl.on("hyprland.start", ...)` and `hl.bind(...)`
calls are additive/last-write-wins per (modmask, key), this caused:
- `noctalia` launching alongside Waybar on every login
- Duplicate/overridden keybinds for lock (SUPER+L), clipboard (SUPER+V),
  screenshot (Print), volume/brightness/media keys, launcher, etc.
- Several apps (kitty, GTK3, Qt5/Qt6ct, btop, alacritty, KDE globals)
  pointing at Noctalia-generated theme files instead of HyDE's
  Wallbash-generated ones (some of which, e.g. `qt5ct.conf`, *were* already
  correctly pointed at `wallbash.conf` — but `qt6ct.conf` wasn't, showing the
  inconsistency isn't systematic)

**Workaround used:** Manually removed all Noctalia references:
- `~/.config/hypr/config/autostart.lua`: removed the `noctalia` exec
- `~/.config/hypr/config/binds.lua`: removed the `noctCall` var and every
  bind using it (HyDE's own `key_binds.lua` already covers all the same
  actions via rofi/hyprlock/cliphist/pamixer/playerctl/grim)
- `~/.config/hypr/config/windowrules.lua`: removed the Noctalia window rule
- `~/.config/kitty/kitty.conf`, `~/.config/alacritty/alacritty.toml`,
  `~/.config/gtk-3.0/gtk.css`: removed Noctalia theme imports
- `~/.config/btop/btop.conf`: `color_theme` → `"Default"`
- `~/.config/qt6ct/qt6ct.conf`: `color_scheme_path` → the existing
  `wallbash.conf` (matching what `qt5ct.conf` already did)
- `~/.config/kdeglobals`: removed the Noctalia `ColorScheme`/`Name` entries
- Deleted leftover files/dirs: `~/.config/noctalia/`,
  `~/.local/state/noctalia/`, and the various `themes/noctalia.*` files
- Killed the running `noctalia` process, `hyprctl reload`
- Still to do: `sudo pacman -Rns noctalia noctalia-greeter cachyos-hypr-noctalia`
  (needs an interactive sudo prompt, not run yet)

**Suggested real fix:** `install.sh`'s dotfile deployer should not "adopt"
`hyprland.lua` when a pre-existing CachyOS/Noctalia config is detected — it
should either fully replace it (backing up the old one, as it already does
for other files) or explicitly warn the user that two compositor configs are
now active.

## 4. Waybar workspace clicks don't switch workspaces

**Symptom:** Clicking a workspace pill in Waybar's `hyprland/workspaces`
module does nothing.

**Likely cause:** This CachyOS build of Hyprland is `0.56.2`, a fork with
native Lua config support. `hyprctl dispatch` on this build requires Lua
expression syntax now:

```sh
# fails:
hyprctl dispatch 'workspace, 2'
# error: [string "return hl.dispatch(workspace, 2)"]:1: ...

# works:
hyprctl dispatch 'hl.dsp.focus({workspace=2})'
```

Waybar's `hyprland/workspaces` module talks to the Hyprland IPC socket
directly using the classic `dispatch workspace <id>` command string, which
this Hyprland fork apparently no longer accepts. Not yet confirmed whether
this is purely a Waybar/Hyprland-fork protocol mismatch or something
specific to this install — **not fully root-caused yet**, flagged here for
follow-up.

## 5. Some keybinds not working after the noctalia cleanup (§3)

After removing Noctalia's keybinds, user reported `SUPER+1` (and other
workspace-number binds) not working, while *some* other keybinds did work.
`hyprctl binds` shows the bind registered correctly, and manually invoking
the equivalent dispatcher (`hyprctl dispatch 'hl.dsp.focus({workspace=N})'`)
works fine — so the dispatcher itself isn't broken. Root cause **not found
yet** (investigation was stopped mid-way at the user's request). Worth
checking: whether HyDE's own `key_binds.lua` binds the same combo to
something that silently no-ops and wins the last-write-wins race, and/or
whether the multi-interface ROCCAT Vulcan keyboard (six separate HID
keyboard sub-devices reported by `hyprctl devices`) is involved.

## Sudo timeout during install

Also worth noting: `install.sh`'s first `yay` package install
(`hyprquery`, `wlogout`) failed once with `sudo: Zeitüberschreitung beim
Lesen des Passworts` (password prompt timed out — default sudo timeout,
terminal wasn't attended). Non-fatal: the script's own verify step retried
the same install a moment later and it succeeded. No action needed beyond
being at the terminal when it prompts.
