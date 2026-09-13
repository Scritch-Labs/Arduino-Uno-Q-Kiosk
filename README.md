# Uno Q Web Kiosk

A "deploy and forget" web kiosk: a monitor displaying a client's web page, where the
client can change the URL themselves with a keyboard shortcut, mouse, and keyboard —
no SSH, no terminal, no browser chrome exposed.

Built on the Arduino UNO Q (Qualcomm QRB2210, Debian 13 "trixie" on the Linux side)
plus an Anker 543 USB-C hub (HDMI + Ethernet + USB-A + power passthrough) driving a
monitor at the install site.

## Hardware

- **Arduino UNO Q, 4GB RAM / 32GB eMMC variant.** The 2GB variant works but leaves
  little headroom once Chromium, Debian, and the settings server are all running —
  4GB is the safer default for a board that won't be physically visited often.
- **Anker 543 USB-C hub (6-in-1).** Plugs into the Uno Q's single USB-C port (which
  supports DisplayPort Alt Mode + Power Delivery passthrough). Gives you HDMI out,
  2x USB-A for keyboard/mouse, Gigabit Ethernet, and power-in from a wall charger —
  all through the one cable to the board.
- A monitor, keyboard, and mouse at the install site (keyboard/mouse only need to be
  connected when the client wants to change the URL — not required for normal display).

## One-time setup per board (manual, via Arduino App Lab)

This part can't be scripted — it needs Arduino App Lab's interactive wizard and a
direct USB-C connection from a computer to the board.

1. Install [Arduino App Lab](https://www.arduino.cc/en/software/#arduino-app-lab) on a
   computer (Windows/Mac/Linux).
2. Connect the Uno Q to that computer via USB-C ("desktop mode").
3. In App Lab, flash the board with the latest stock Arduino Linux image
   (Settings → reset/reflash, or use `arduino-flasher-cli flash latest` directly if
   the board is already discoverable). This gives every board a known-clean starting
   point — default login is `arduino` / `arduino` before first setup.
4. Run through App Lab's first-boot wizard:
   - Join the board to Wi-Fi (or connect Ethernet — either works, see network note below).
   - Set a real password for the `arduino` user (don't leave it on the default).
   - App Lab auto-enables SSH + Network Mode once Wi-Fi is joined.
   - Optionally give the board a distinct hostname.
5. Confirm you can `ssh arduino@<board-ip-or-hostname>` from your computer before
   moving on.

**Password hygiene:** store each board's password in a password manager, not in this
repo. The provisioning script never touches or stores the SSH password — it just
needs to already work before you run the script.

## Provisioning (scripted, one command per board)

`provision-kiosk.sh` reproduces the entire kiosk setup in one run: packages, kiosk
files, autostart entries, the settings hotkey, autologin, the systemd service, and
the power-cut-resilient read-only root — then reboots into a working kiosk.

```
scp provision-kiosk.sh arduino@<board-ip-or-hostname>:~/
ssh arduino@<board-ip-or-hostname>
chmod +x provision-kiosk.sh
./provision-kiosk.sh "https://the-client-url-goes-here"
```

The script prompts for `sudo` interactively where needed (lightdm config, the
systemd unit, package installs) — that's expected, just enter the board's password
when asked.

When it reboots, the board comes up already logged in, already showing the target
URL fullscreen, with the cursor hidden and root filesystem protected against
power-loss corruption. No further manual steps.

### Why not just clone the eMMC instead?

Investigated and ruled out. Arduino's own `arduino-flasher-cli` only flashes their
stock factory image — it has no "capture this board's current state" mode. Users who
have tried raw `dd` whole-disk clones between two Uno Q boards report kernel panics on
boot. The partition table also contains board-unique data (`bdaddr` and `wlanaddr` —
the Bluetooth and Wi-Fi MAC addresses) that would collide if copied onto other
hardware. The provisioning script is the supported path for fleet deployment.

## How the kiosk works

- **Display:** Chromium runs in `--kiosk --incognito` mode, navigating **directly** to
  the client's URL (top-level navigation, not an iframe). An iframe-based design was
  tried first and abandoned — most real sites send `X-Frame-Options`/CSP headers that
  block being embedded, so wrapping the client's site in our own page doesn't work in
  general.
- **Changing the URL:** press **Ctrl+Alt+S** on a keyboard connected to the board. This
  is bound as an XFCE custom shortcut to `~/kiosk/toggle-settings.sh`, which flips a
  state file and kills Chromium. The restart-loop wrapper
  (`~/kiosk/kiosk-chromium.sh`) re-reads that state file on every relaunch, so it comes
  back up showing a local settings form (URL field + Save button) instead of the site.
  Edit the URL with the mouse/keyboard and click **Save** — it writes the new URL,
  flips the state back, and Chromium restarts pointed at the new site automatically.
  No second hotkey press needed, no address bar or browser chrome ever exposed.
- **Local settings server:** `~/kiosk/server.py`, a dependency-free Python
  `http.server` bound to `127.0.0.1:8080` only (not reachable from the network) —
  runs as the `kiosk-server.service` systemd unit.
- **Boot behavior:** lightdm autologin straight into the `arduino` user's XFCE
  session — no login prompt after a power cycle.
- **Cursor:** `unclutter-xfixes` hides the mouse pointer after 1 second of
  inactivity and brings it back instantly on movement — invisible during normal
  display, usable the moment someone needs to click Save.
- **Arduino App Lab's own autostart is disabled.** The stock image ships a
  system-wide `/etc/xdg/autostart/ArduinoAppLab.desktop` that launches the App Lab
  desktop app (with a "Welcome to Arduino App Lab" dialog) on every XFCE login —
  discovered when it popped up on top of the kiosk after a routine reboot. Fixed with
  a standard XDG per-user override: `~/.config/autostart/ArduinoAppLab.desktop`
  containing just `Hidden=true`. This is a normal write under `/home/arduino`, so it
  needs no `/etc` edit and no overlayroot workaround even on an already-provisioned
  board.
- **Changing the Wi-Fi network:** from the same settings page (Ctrl+Alt+S → Settings),
  click "Change Wi-Fi Network" to reach `/wifi`, which scans and lists nearby networks
  by signal strength. Pick one — a password field only appears if it's secured — or use
  the "connect to a different or hidden network" form for anything not in the scan
  list. The current SSID is always shown for context. On success, the display
  auto-returns to the site after a few seconds (or immediately via a "Continue Now"
  button); on failure, it shows nmcli's own error text and offers "Try Again" without
  navigating anywhere — never a dead end, never a silent failure. `server.py` still
  runs unprivileged as `arduino`; the actual `nmcli` connect call is delegated to a
  narrowly-scoped root-owned helper, `/usr/local/sbin/kiosk-wifi-connect.sh`, invoked
  via a single-command `NOPASSWD` sudoers rule (`/etc/sudoers.d/kiosk-wifi`). The
  helper lives outside `/home/arduino` specifically so the unprivileged `arduino` user
  can't overwrite it and turn that grant into arbitrary root access — confirmed on
  hardware: `arduino` gets "Permission denied" trying to touch, edit, or delete it.
  Scanning itself needs no elevated privilege. (Live-tested end-to-end: real scan
  results, a safe failure case via a nonexistent SSID showing a clean error message
  with the current connection left untouched, and the return-to-site route correctly
  flipping back to the site and relaunching Chromium.)
- **Power-cut resilience:** the root filesystem (`/`) is mounted through `overlayroot`
  as a RAM-backed (`tmpfs`) overlay — nothing on it can be corrupted by a hard power
  cut, because no write to `/` ever touches the real disk after boot. The one thing
  that must survive a reboot — the client's chosen URL — lives on `/home/arduino`,
  which is a **separate real eMMC partition**, deliberately left out of the overlay
  (`overlayroot="tmpfs:recurse=0"` — the default `recurse=1` would ephemeralize
  `/home/arduino` too, silently breaking URL persistence).

## Maintaining an already-provisioned board

**This is the part that trips people up.** Once overlayroot is active, `/` is
ephemeral — any change made the normal way (`apt-get install ...`, editing a file
under `/etc`, etc.) only lands in a RAM layer and vanishes on the next reboot. Only
writes under `/home/arduino` survive normally.

To make a **real, persistent** change to anything under `/` on a board that's already
provisioned:

```bash
sudo mount -o remount,rw /media/root-ro

# for file edits: just edit the file directly under /media/root-ro, e.g.
sudo nano /media/root-ro/etc/overlayroot.conf

# for package installs, chroot in first (also needs DNS bind-mounted in —
# the real disk's own /etc/resolv.conf is a stale empty stub; the live
# nameserver config only ever gets written to the ephemeral overlay copy):
sudo mount --bind /dev  /media/root-ro/dev
sudo mount --bind /proc /media/root-ro/proc
sudo mount --bind /sys  /media/root-ro/sys
sudo mount --bind /run  /media/root-ro/run
sudo mount --bind /etc/resolv.conf /media/root-ro/etc/resolv.conf
sudo chroot /media/root-ro apt-get update
sudo chroot /media/root-ro apt-get install -y <package>
sudo umount -l /media/root-ro/dev /media/root-ro/proc /media/root-ro/sys \
               /media/root-ro/run /media/root-ro/etc/resolv.conf

# always finish with:
sudo mount -o remount,ro /media/root-ro
sudo reboot   # to verify the change actually persisted
```

Always reboot and re-verify after a change like this — it's easy to think an edit
worked because the *live* (overlaid) view shows it, when it actually only exists in
RAM and will be gone on the next boot.

**One exception worth knowing:** a *brand-new* path that doesn't already exist
anywhere under `/` becomes visible in the live overlay immediately after you write it
to `/media/root-ro`, with no reboot required — overlayfs falls through to the lower
(real-disk) layer for anything not already shadowed in the RAM upper layer. This is
how `/usr/local/sbin/kiosk-wifi-connect.sh` and `/etc/sudoers.d/kiosk-wifi` were added
and verified on the live board without a reboot. It only works for genuinely new
paths, though — overwriting or removing something that already exists still needs the
reboot to confirm the change actually stuck (the live view would otherwise be showing
whatever's in the RAM layer, if anything had already touched that path this boot).

Both `/usr/local/sbin/kiosk-wifi-connect.sh` and `/etc/sudoers.d/kiosk-wifi` are, like
`/etc/lightdm/...` and the systemd unit, under the overlaid `/` — patching either on an
already-provisioned board needs this same procedure, not a plain edit. (`sudoers.d`
edits specifically should always be validated with `sudo visudo -c -f <tmpfile>`
before installing — a malformed sudoers file can break `sudo` system-wide.)

## Known limitations / open items

- **Login-required target pages:** Chromium runs with `--incognito` (chosen so a
  crashed/power-cut session doesn't show a "restore pages?" prompt on next launch).
  This means no login session ever persists — if the client's page requires
  authentication, every Chromium restart (URL change, crash, or reboot) lands back on
  the login screen. Fine for a public/anonymous page; if the real target needs a
  login, either configure anonymous/public access on that service, or drop
  `--incognito` in `kiosk-chromium.sh` and accept the restore-prompt tradeoff (the
  Chromium profile lives under `/home/arduino`, which is persistent, so a login would
  survive reboots if incognito were removed).
- **Config-partition fsck:** `/home/arduino` still takes real writes (the URL config),
  so it's the one place a hard power cut could still cause small-scale corruption
  (unlikely, but possible on a partially-written file). Not currently configured to
  force an `fsck` every boot — low priority, add if it ever becomes a real issue.
- **`provision-kiosk.sh` has only been run on one board so far** (the one this repo's
  setup was developed against). Worth a dry run against a second physical board before
  trusting it for an unattended fleet rollout.
- **Network:** either Wi-Fi or Ethernet works for normal operation. If you're
  managing these boards remotely across VLANs, be aware that inter-VLAN routing
  quality varies by network — this isn't a board issue, just worth testing your own
  network path before assuming remote SSH access will be reliable.
- **Wi-Fi settings page — still open after live testing:** scanning, the
  network-not-found failure case, and the return-to-site route were all verified
  working on real hardware. Still untested: (a) actually clicking the "Change Wi-Fi
  Network" link *from inside the kiosk's own Chromium `--app` window* (verified so far
  only via direct HTTP requests to the server, not through the real kiosk UI) — expected
  to work since `--app` mode allows normal in-page navigation, but not yet confirmed;
  (b) the wrong-password-on-a-real-network case (only tested against a nonexistent
  SSID, to avoid touching anyone's actual Wi-Fi credentials/connection during
  development); (c) whether nmcli ever echoes a plaintext password back in its own
  error output (the failure page would display it verbatim if so).

## File layout

```
provision-kiosk.sh              # run once per new board
README.md                       # this file

# Deployed onto the board by provision-kiosk.sh, for reference:
/home/arduino/kiosk/
  server.py                     # local settings HTTP server (127.0.0.1:8080 only)
                                 # serves /settings, /wifi, /wifi/connect, /wifi/return-to-site
  kiosk-chromium.sh             # restart-loop wrapper that launches Chromium
  toggle-settings.sh            # bound to Ctrl+Alt+S, flips to settings mode
  config.json                   # {"url": "..."} — the client's current target
  mode                          # "site" or "settings"
/home/arduino/.config/autostart/
  kiosk-chromium.desktop
  unclutter.desktop
  ArduinoAppLab.desktop         # Hidden=true -- overrides/disables the stock
                                 # system-wide App Lab autostart entry
/home/arduino/.config/xfce4/xfconf/xfce-perchannel-xml/
  xfce4-keyboard-shortcuts.xml  # Ctrl+Alt+S -> toggle-settings.sh
/etc/lightdm/lightdm.conf.d/50-autologin.conf
/etc/systemd/system/kiosk-server.service
/etc/overlayroot.conf           # overlayroot="tmpfs:recurse=0"
/usr/local/sbin/kiosk-wifi-connect.sh   # root-owned; only callable via sudoers rule below
/etc/sudoers.d/kiosk-wifi                # NOPASSWD rule scoped to the script above
```
