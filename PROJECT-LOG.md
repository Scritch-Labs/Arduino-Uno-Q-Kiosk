# Project Log — Uno Q Web Kiosk

Development history and context for this project, kept separate from `README.md`
(which is the operator-facing "how to use this" doc). Written so this project can be
picked back up after a gap without having to re-derive any of this from scratch.

**Status as of 2026-09-13: functionally complete on the software side, live-verified
on one physical board.** Everything below is done unless marked otherwise.

## How this started

Goal: a "deploy and forget" web kiosk — a monitor showing a client's web page, where
the client can change the URL themselves (mouse + keyboard, no SSH/terminal), built
to be replicated across many boards for multiple client sites.

**Hardware chosen:** Arduino UNO Q (4GB RAM / 32GB eMMC variant — the 2GB variant
works but leaves little headroom once Chromium + Debian + the settings server are
all running) plus an Anker 543 USB-C hub (6-in-1: HDMI, Gigabit Ethernet, 2x USB-A,
power passthrough — the Uno Q's single USB-C port supports DisplayPort Alt Mode +
Power Delivery, so one cable handles display, network, and power). Considered a
Raspberry Pi 4/5 as a simpler alternative if the STM32 microcontroller side is ever
dropped as a requirement — native HDMI, no hub trickery needed, larger community —
but went with the Uno Q since the dual-brain (Linux + microcontroller) design was the
actual reason for choosing this board originally.

## Architecture decisions and why (in the order we hit them)

1. **Iframe approach tried first, abandoned.** Original plan was a local page that
   iframed the client's site with a small settings gear overlay. Failed immediately
   in testing — most real sites send `X-Frame-Options`/CSP headers blocking iframe
   embedding (confirmed via screenshot: weather.com showed Chromium's "This page
   couldn't load"). **Fix:** Chromium navigates top-level directly to the client's
   URL (`--app=<url>`, no iframe) — works on any site. Settings are reached via a
   **Ctrl+Alt+S** keyboard hotkey instead of an on-screen icon, since there's no
   overlay UI possible once you're not iframing.

2. **Power-cut resilience via `overlayroot`.** The client controls power via a
   breaker panel — no graceful shutdown, ever. Root filesystem (`/`) is mounted
   through Debian's `overlayroot` package as a RAM-backed (`tmpfs`) overlay, so no
   write to `/` after boot ever touches real disk — a hard power cut can't corrupt
   it. Critical config detail: `overlayroot="tmpfs:recurse=0"` — the default
   `recurse=1` would also ephemeralize `/home/arduino` (a genuinely separate eMMC
   partition), silently breaking persistence of the client's saved URL. Verified
   after reboot: `/` shows as `type overlay`, `/home/arduino` shows as plain
   `type ext4`.

3. **The recurring "overlayroot gotcha."** Any write made to `/` from a normal SSH
   session *after* overlayroot is already active only lands in the RAM layer and
   vanishes on next reboot — this bit us repeatedly (once on the `overlayroot.conf`
   fix itself, once on `unclutter-xfixes`). Real fix: remount the underlying disk
   directly (`mount -o remount,rw /media/root-ro`, edit/install there, remount ro
   again) — package installs additionally need `/dev /proc /sys /run` and
   `/etc/resolv.conf` bind-mounted into a chroot (the real disk's own `resolv.conf`
   is a stale empty stub; live nameservers only ever get written to the ephemeral
   copy). Full procedure is in `README.md` under "Maintaining an already-provisioned
   board." **The fleet-provisioning script sidesteps this entirely** by enabling
   overlayroot as its *last* step, on a board where root has never been overlaid —
   so every step before it is a normal, persisting disk write.

4. **Cursor hiding:** `unclutter-xfixes`, hides after 1s idle, instant on movement.

5. **Wi-Fi network changing:** added as a second capability alongside the URL field,
   reachable the same way. Scans and lists nearby networks (signal strength, lock
   icon for secured ones) rather than requiring the SSID typed from memory — the
   user confirmed the actual end client, not just installers, may need this. The
   real `nmcli` connect call is delegated to a narrowly-scoped root-owned helper
   (`/usr/local/sbin/kiosk-wifi-connect.sh`, authorized via a single-command
   `NOPASSWD` sudoers rule) since the settings server itself stays unprivileged —
   deliberately placed outside `/home/arduino` so the unprivileged kiosk user can't
   overwrite it and escalate. Designed via a Plan-mode session with a dedicated Plan
   subagent before implementing. All SSID/user-supplied values are `html.escape()`'d
   (SSIDs are attacker-controllable, broadcast by anything in radio range).

6. **Fleet deployment — why not just clone the eMMC:** investigated and ruled out.
   Arduino's own `arduino-flasher-cli` only flashes their stock factory image (no
   "capture current board state" mode); raw `dd` whole-disk clones between two Uno Q
   boards cause kernel panics on boot; the partition table has board-unique
   `bdaddr`/`wlanaddr` partitions (actual Bluetooth/Wi-Fi MAC addresses) that would
   collide across boards if copied. **Solution:** `provision-kiosk.sh`, a single
   script that reproduces the entire setup on a freshly-flashed board in one run.

7. **App Lab autostart bug (found late, easy to miss):** the stock Arduino image
   ships a *system-wide* `/etc/xdg/autostart/ArduinoAppLab.desktop` that launches
   the App Lab desktop app — with a "Welcome to Arduino App Lab" dialog — on every
   XFCE login, for every user. This popped up on top of the kiosk after a routine
   reboot, which would be a real problem in front of a client. Fixed with a
   per-user XDG override (`~/.config/autostart/ArduinoAppLab.desktop` containing
   just `Hidden=true`) — a plain write under `/home/arduino`, no special procedure
   needed. Added to the provisioning script so every future board gets this
   automatically.

## Known limitations / deliberately deferred

- **Login-required target pages:** Chromium runs `--incognito` (avoids "restore
  session" prompts after a hard power cut) — but that means no login session ever
  persists. Fine for a public/anonymous page; flagged during testing against a
  Grafana login page, user said not a concern for the actual target site.
- **Config-partition `fsck` on boot:** not configured. `/home/arduino` is the one
  place still taking real writes, so it's the one spot a hard power cut could still
  cause small-scale corruption. Explicitly deprioritized by the user — low
  likelihood, easy to add later if it ever becomes real.
- **Network flakiness during development:** this session's connection to the board
  (crossing inter-VLAN routing, not same-subnet) was unreliable on both the original
  Wi-Fi IP and a later Ethernet IP — bursty outages, high packet loss specifically
  on sustained TCP/SSH. Root-caused to the network path itself, not the board or any
  of our changes. Not urgent, but relevant if remote SSH management of these boards
  is part of the ongoing plan.
- **`provision-kiosk.sh` has only been run on the one board this whole project was
  developed against.** Worth a dry run against a genuinely fresh second board before
  trusting it for an unattended fleet rollout — the *steps* are all individually
  verified, but the full script hasn't been exercised start-to-finish on new
  hardware.

## Repo contents

- `provision-kiosk.sh` — run once per new board (see `README.md` for usage).
- `README.md` — operator-facing docs: hardware, one-time App Lab setup, running the
  script, full architecture explanation, and the maintenance procedure for patching
  an already-provisioned board.
- `screenshots/` — client-demo images, **not committed to git** (`.gitignore`'d) —
  some show internal details (an internal Grafana URL/version, a real nearby Wi-Fi
  network name). Review before sending anything external.
- This file.

## Git history

- `c87441d` — initial commit: `provision-kiosk.sh` + `README.md`.
- `84d6fc4` — Wi-Fi network changing feature.
- `5ab18fa` — App Lab autostart fix.

Not pushed to any remote as of this writing.

## If you're picking this back up

The system is done and working. The two realistic next steps are:

1. **Physical deployment:** move off the computer's USB tether onto the Anker hub
   (monitor + wall power + Ethernet) at the real install location, if not already
   done.
2. **Fleet rollout:** run `provision-kiosk.sh` against each new board. Do the first
   one as a deliberate dry run and actually click through the whole client-facing
   flow (URL change, Wi-Fi change) before trusting the rest of the fleet to it
   unattended — see the limitation above.

Nothing about the *design* needs revisiting unless a new requirement shows up
(the Pi-vs-Uno-Q choice, the iframe-vs-top-level-navigation decision, the
overlayroot/`recurse=0` config, and the Wi-Fi feature's scan-and-list/privilege
design are all settled and verified — don't re-litigate them without a new reason).
