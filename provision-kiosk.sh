#!/bin/bash
# Uno Q kiosk provisioning script.
#
# Prerequisites (must be done once per board, manually, via Arduino App Lab):
#   1. Flash the board with the stock Arduino Linux image.
#   2. Run through App Lab's first-boot wizard: join Wi-Fi, set a password,
#      let it enable SSH + Network Mode.
#   3. Confirm you can `ssh arduino@<board>` from this machine.
#
# Usage (run ON the board itself, over SSH, as the `arduino` user):
#   scp provision-kiosk.sh arduino@<board-ip-or-hostname>:~/
#   ssh arduino@<board-ip-or-hostname>
#   chmod +x provision-kiosk.sh
#   ./provision-kiosk.sh "https://example.com/your-dashboard"
#
# The script ends by rebooting the board. Everything (kiosk display,
# Ctrl+Alt+S settings hotkey, autologin, power-cut-resilient read-only
# root, hidden cursor) is active from that reboot onward.
#
# IMPORTANT: overlayroot is enabled as the LAST step, before the plain
# root filesystem is ever turned read-only/ephemeral. Do not re-run
# apt-get or edit anything under `/` (outside /home/arduino) on an
# already-provisioned board without remounting /media/root-ro read-write
# first — see the "gotcha" notes in project memory for why.

set -euo pipefail

TARGET_URL="${1:?Usage: $0 <client-url>}"

if [[ "$TARGET_URL" != http://* && "$TARGET_URL" != https://* ]]; then
  echo "Error: URL must start with http:// or https://" >&2
  exit 1
fi

echo "==> Refreshing apt (working around occasional stale/corrupt cache)"
sudo rm -rf /var/lib/apt/lists/*
sudo apt-get update

echo "==> Installing packages"
sudo apt-get install -y chromium overlayroot unclutter-xfixes

echo "==> Writing kiosk files to /home/arduino/kiosk/"
mkdir -p /home/arduino/kiosk
mkdir -p /home/arduino/.config/autostart
mkdir -p /home/arduino/.config/xfce4/xfconf/xfce-perchannel-xml

cat <<'PYEOF' > /home/arduino/kiosk/server.py
#!/usr/bin/env python3
import html, json, os, subprocess, tempfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

CONFIG_PATH = "/home/arduino/kiosk/config.json"
MODE_PATH = "/home/arduino/kiosk/mode"
DEFAULT_URL = "https://example.com"
WIFI_HELPER = "/usr/local/sbin/kiosk-wifi-connect.sh"

def read_url():
    try:
        with open(CONFIG_PATH) as f:
            return json.load(f).get("url", DEFAULT_URL)
    except FileNotFoundError:
        return DEFAULT_URL

def atomic_write(path, content):
    d = os.path.dirname(path)
    os.makedirs(d, exist_ok=True)
    fd, tmp_path = tempfile.mkstemp(dir=d)
    with os.fdopen(fd, "w") as f:
        f.write(content)
    os.rename(tmp_path, path)

def write_url(url):
    atomic_write(CONFIG_PATH, json.dumps({"url": url}))

def set_mode(mode):
    atomic_write(MODE_PATH, mode)

def return_to_site():
    set_mode("site")
    subprocess.run(["pkill", "-f", "chromium.*--app="], check=False)

def _unescape_nmcli(s):
    return s.replace("\\:", ":").replace("\\\\", "\\")

def get_current_ssid():
    try:
        proc = subprocess.run(
            ["nmcli", "-t", "-f", "active,ssid", "device", "wifi"],
            capture_output=True, text=True, timeout=10,
        )
    except (subprocess.TimeoutExpired, OSError):
        return None
    for line in proc.stdout.splitlines():
        if line.startswith("yes:"):
            return _unescape_nmcli(line[len("yes:"):])
    return None

def scan_networks():
    try:
        proc = subprocess.run(
            ["nmcli", "-t", "-m", "multiline", "-f", "SSID,SIGNAL,SECURITY",
             "device", "wifi", "list", "--rescan", "yes"],
            capture_output=True, text=True, timeout=15,
        )
    except subprocess.TimeoutExpired:
        return [], "Scan timed out."
    except OSError as e:
        return [], str(e)
    if proc.returncode != 0:
        return [], (proc.stderr or proc.stdout or "Scan failed.").strip()

    networks = {}
    ssid = signal = None
    for line in proc.stdout.splitlines():
        if line.startswith("SSID:"):
            ssid = _unescape_nmcli(line[len("SSID:"):])
        elif line.startswith("SIGNAL:"):
            signal = line[len("SIGNAL:"):]
        elif line.startswith("SECURITY:"):
            security = _unescape_nmcli(line[len("SECURITY:"):])
            if ssid:
                try:
                    sig = int(signal)
                except (TypeError, ValueError):
                    sig = 0
                secured = bool(security.strip())
                existing = networks.get(ssid)
                if existing is None or sig > existing[0]:
                    networks[ssid] = (sig, secured)
            ssid = signal = None

    result = [{"ssid": s, "signal": v[0], "secured": v[1]} for s, v in networks.items()]
    result.sort(key=lambda n: n["signal"], reverse=True)
    return result, None

def attempt_connect(ssid, password, hidden):
    payload = json.dumps({"ssid": ssid, "password": password, "hidden": hidden}).encode()
    try:
        result = subprocess.run(
            ["sudo", "-n", WIFI_HELPER],
            input=payload, capture_output=True, timeout=50,
        )
    except subprocess.TimeoutExpired:
        return False, "Connection attempt timed out."
    if result.returncode == 124:
        return False, "Connection attempt timed out — check the password and try again."
    detail = (result.stdout + result.stderr).decode(errors="replace").strip()
    if result.returncode == 0:
        return True, detail or "Connected."
    return False, detail or "Connection failed."

SETTINGS_PAGE = """<!doctype html>
<html><head><meta charset="utf-8"><title>Kiosk Settings</title>
<style>
  body {{ font-family: sans-serif; background:#111; color:#eee; display:flex;
         align-items:center; justify-content:center; height:100vh; margin:0; }}
  form {{ background:#1c1c1c; padding:2rem; border-radius:8px; width:min(90%,480px); }}
  input {{ width:100%; padding:0.6rem; font-size:1rem; box-sizing:border-box; margin-top:0.5rem; }}
  button {{ margin-top:1rem; padding:0.6rem 1.2rem; font-size:1rem; cursor:pointer; }}
  p {{ opacity: 0.7; }}
  a {{ color:#8ab4f8; }}
</style></head>
<body>
  <form method="post" action="/settings">
    <label>Website URL</label>
    <input name="url" type="text" value="{url}" required>
    <button type="submit">Save &amp; Return to Site</button>
    <p>Saving returns the display to the site automatically.</p>
    <p><a href="/wifi">Change Wi-Fi Network</a></p>
  </form>
</body></html>
"""

WIFI_PAGE = """<!doctype html>
<html><head><meta charset="utf-8"><title>Wi-Fi Settings</title>
<style>
  body {{ font-family: sans-serif; background:#111; color:#eee; display:flex;
         align-items:center; justify-content:center; min-height:100vh; margin:0; padding:2rem 0; }}
  .card {{ background:#1c1c1c; padding:2rem; border-radius:8px; width:min(90%,480px); }}
  h2 {{ margin-top:0; font-size:1.1rem; }}
  .current {{ opacity:0.8; margin-bottom:1rem; }}
  .networks {{ list-style:none; padding:0; margin:0 0 1.5rem 0; }}
  .networks li {{ margin-bottom:0.5rem; }}
  .networks button {{ width:100%; text-align:left; padding:0.6rem; font-size:1rem;
                       cursor:pointer; background:#252525; color:#eee; border:1px solid #333;
                       border-radius:6px; }}
  .networks button:hover {{ background:#2f2f2f; }}
  input {{ width:100%; padding:0.6rem; font-size:1rem; box-sizing:border-box; margin-top:0.5rem; }}
  button.submit {{ margin-top:1rem; padding:0.6rem 1.2rem; font-size:1rem; cursor:pointer; }}
  .notice {{ background:#3a2a10; padding:0.75rem; border-radius:6px; margin-bottom:1rem; }}
  a {{ color:#8ab4f8; }}
  .links {{ margin-top:1.5rem; }}
  .checkbox {{ display:block; margin-top:0.75rem; font-size:0.9rem; opacity:0.85; }}
  .checkbox input {{ width:auto; margin:0 0.4rem 0 0; vertical-align:middle; }}
</style></head>
<body>
  <div class="card">
    <h2>Wi-Fi Networks</h2>
    <div class="current">Currently connected to: <strong>{current}</strong></div>
    {notice}
    <ul class="networks">
      {network_items}
    </ul>
    <form method="post" action="/wifi/connect">
      <label>Connect to a different or hidden network</label>
      <input name="ssid" type="text" placeholder="Network name" required>
      <input name="password" type="password" placeholder="Password (leave blank if none)">
      <label class="checkbox"><input type="checkbox" name="hidden_network" value="1">
        This network is hidden (doesn&rsquo;t broadcast its name)</label>
      <button class="submit" type="submit">Connect</button>
    </form>
    <div class="links">
      <a href="/wifi">Rescan</a> &middot; <a href="/settings">Back to Settings</a>
    </div>
  </div>
</body></html>
"""

WIFI_CONNECT_FORM_PAGE = """<!doctype html>
<html><head><meta charset="utf-8"><title>Connect to {ssid_h}</title>
<style>
  body {{ font-family: sans-serif; background:#111; color:#eee; display:flex;
         align-items:center; justify-content:center; height:100vh; margin:0; }}
  form {{ background:#1c1c1c; padding:2rem; border-radius:8px; width:min(90%,480px); }}
  input {{ width:100%; padding:0.6rem; font-size:1rem; box-sizing:border-box; margin-top:0.5rem; }}
  button {{ margin-top:1rem; padding:0.6rem 1.2rem; font-size:1rem; cursor:pointer; }}
  a {{ color:#8ab4f8; }}
</style></head>
<body>
  <form method="post" action="/wifi/connect">
    <label>Connect to &ldquo;{ssid_h}&rdquo;</label>
    {password_field}
    <input type="hidden" name="ssid" value="{ssid_h}">
    <button type="submit">Connect</button>
    <p><a href="/wifi">Cancel</a></p>
  </form>
</body></html>
"""

WIFI_SUCCESS_PAGE = """<!doctype html>
<html><head><meta charset="utf-8"><title>Connected</title>
<meta http-equiv="refresh" content="3;url=/wifi/return-to-site">
<style>
  body {{ font-family: sans-serif; background:#111; color:#eee; display:flex;
         align-items:center; justify-content:center; height:100vh; margin:0; text-align:center; }}
  .card {{ background:#1c1c1c; padding:2rem; border-radius:8px; width:min(90%,480px); }}
  .btn {{ display:inline-block; margin-top:1rem; padding:0.6rem 1.2rem; font-size:1rem;
          background:#2f6fed; color:#fff; text-decoration:none; border-radius:6px; }}
</style></head>
<body>
  <div class="card">
    <h2>Connected to &ldquo;{ssid_h}&rdquo;</h2>
    <p>Returning to the site in a few seconds&hellip;</p>
    <a class="btn" href="/wifi/return-to-site">Continue Now</a>
  </div>
</body></html>
"""

WIFI_FAILURE_PAGE = """<!doctype html>
<html><head><meta charset="utf-8"><title>Connection Failed</title>
<style>
  body {{ font-family: sans-serif; background:#111; color:#eee; display:flex;
         align-items:center; justify-content:center; height:100vh; margin:0; text-align:center; }}
  .card {{ background:#1c1c1c; padding:2rem; border-radius:8px; width:min(90%,480px); }}
  .detail {{ opacity:0.8; margin-top:0.5rem; word-break:break-word; }}
  .btn {{ display:inline-block; margin-top:1rem; margin-right:0.5rem; padding:0.6rem 1.2rem;
          font-size:1rem; background:#333; color:#eee; text-decoration:none; border-radius:6px; }}
</style></head>
<body>
  <div class="card">
    <h2>Couldn&rsquo;t connect to &ldquo;{ssid_h}&rdquo;</h2>
    <p class="detail">{detail_h}</p>
    <a class="btn" href="/wifi">Try Again</a>
    <a class="btn" href="/settings">Back to Settings</a>
  </div>
</body></html>
"""

def render_wifi_page():
    current = get_current_ssid()
    current_h = html.escape(current) if current else "Not connected"
    networks, scan_error = scan_networks()
    if scan_error:
        notice = ('<div class="notice">Couldn’t scan for networks: {}. '
                   'You can still connect manually below.</div>').format(html.escape(scan_error))
    else:
        notice = ""
    items = []
    for n in networks:
        ssid_h = html.escape(n["ssid"])
        lock = " \U0001F512" if n["secured"] else ""
        items.append(
            '<li><form method="get" action="/wifi/connect">'
            '<input type="hidden" name="ssid" value="{ssid}">'
            '<input type="hidden" name="secured" value="{secured}">'
            '<button type="submit">{ssid_disp} — {signal}%{lock}</button>'
            '</form></li>'.format(
                ssid=ssid_h, secured="1" if n["secured"] else "0",
                ssid_disp=ssid_h, signal=n["signal"], lock=lock,
            )
        )
    if not items and not scan_error:
        items.append('<li style="opacity:0.7">No networks found.</li>')
    return WIFI_PAGE.format(current=current_h, notice=notice, network_items="".join(items))

def render_wifi_connect_form(ssid, secured):
    ssid_h = html.escape(ssid)
    if secured:
        password_field = '<input name="password" type="password" placeholder="Password" required>'
    else:
        password_field = '<p style="opacity:0.7">Open network — no password needed.</p>'
    return WIFI_CONNECT_FORM_PAGE.format(ssid_h=ssid_h, password_field=password_field)

class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def _send_html(self, body):
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _redirect(self, location):
        self.send_response(303)
        self.send_header("Location", location)
        self.end_headers()

    def do_GET(self):
        parsed = urlsplit(self.path)
        path = parsed.path
        if path == "/settings":
            self._send_html(SETTINGS_PAGE.format(url=read_url()).encode())
        elif path == "/wifi":
            self._send_html(render_wifi_page().encode())
        elif path == "/wifi/connect":
            qs = parse_qs(parsed.query)
            ssid = qs.get("ssid", [""])[0]
            secured = qs.get("secured", ["0"])[0] == "1"
            self._send_html(render_wifi_connect_form(ssid, secured).encode())
        elif path == "/wifi/return-to-site":
            return_to_site()
            self._redirect("/settings")
        else:
            self._redirect("/settings")

    def do_POST(self):
        if self.path == "/settings":
            length = int(self.headers.get("Content-Length", 0))
            data = parse_qs(self.rfile.read(length).decode())
            url = data.get("url", [""])[0].strip()
            if url.startswith("http://") or url.startswith("https://"):
                write_url(url)
                return_to_site()
            self._redirect("/settings")
        elif self.path == "/wifi/connect":
            length = int(self.headers.get("Content-Length", 0))
            data = parse_qs(self.rfile.read(length).decode())
            ssid = data.get("ssid", [""])[0].strip()
            password = data.get("password", [""])[0]
            hidden = data.get("hidden_network", [""])[0] == "1"
            if not ssid:
                body = WIFI_FAILURE_PAGE.format(
                    ssid_h="(none)", detail_h=html.escape("No network name given.")
                ).encode()
                self._send_html(body)
                return
            ok, detail = attempt_connect(ssid, password, hidden)
            ssid_h = html.escape(ssid)
            if ok:
                body = WIFI_SUCCESS_PAGE.format(ssid_h=ssid_h).encode()
            else:
                body = WIFI_FAILURE_PAGE.format(ssid_h=ssid_h, detail_h=html.escape(detail)).encode()
            self._send_html(body)
        else:
            self.send_response(404)
            self.end_headers()

if __name__ == "__main__":
    os.makedirs(os.path.dirname(CONFIG_PATH), exist_ok=True)
    if not os.path.exists(MODE_PATH):
        set_mode("site")
    ThreadingHTTPServer(("127.0.0.1", 8080), Handler).serve_forever()
PYEOF

cat <<'WRAPEOF' > /home/arduino/kiosk/kiosk-chromium.sh
#!/bin/bash
xset s off
xset -dpms
xset s noblank

CONFIG=/home/arduino/kiosk/config.json
MODE=/home/arduino/kiosk/mode

get_target() {
  mode=$(cat "$MODE" 2>/dev/null || echo site)
  if [ "$mode" = "settings" ]; then
    echo "http://localhost:8080/settings"
  else
    python3 -c "import json;print(json.load(open('$CONFIG')).get('url','https://example.com'))" 2>/dev/null || echo "https://example.com"
  fi
}

while true; do
  target=$(get_target)
  chromium \
    --kiosk \
    --no-first-run \
    --disable-infobars \
    --noerrdialogs \
    --disable-session-crashed-bubble \
    --disable-translate \
    --incognito \
    --check-for-update-interval=31536000 \
    --app="$target"
  sleep 1
done
WRAPEOF
chmod +x /home/arduino/kiosk/kiosk-chromium.sh

cat <<'TOGGLEEOF' > /home/arduino/kiosk/toggle-settings.sh
#!/bin/bash
echo settings > /home/arduino/kiosk/mode
pkill -f 'chromium.*--app='
TOGGLEEOF
chmod +x /home/arduino/kiosk/toggle-settings.sh

cat <<CFGEOF > /home/arduino/kiosk/config.json
{"url": "$TARGET_URL"}
CFGEOF
echo site > /home/arduino/kiosk/mode

echo "==> Chromium kiosk autostart entry"
cat <<'DESKTOPEOF' > /home/arduino/.config/autostart/kiosk-chromium.desktop
[Desktop Entry]
Type=Application
Name=Kiosk Chromium
Exec=/home/arduino/kiosk/kiosk-chromium.sh
X-GNOME-Autostart-enabled=true
NoDisplay=true
DESKTOPEOF

echo "==> Unclutter (hide mouse cursor) autostart entry"
cat <<'UNCLUTTEREOF' > /home/arduino/.config/autostart/unclutter.desktop
[Desktop Entry]
Type=Application
Name=Unclutter
Exec=unclutter-xfixes --timeout 1 --jitter 2
X-GNOME-Autostart-enabled=true
NoDisplay=true
UNCLUTTEREOF

echo "==> Disabling Arduino App Lab's own autostart (it ships a system-wide"
echo "    /etc/xdg/autostart entry that otherwise pops up on top of the kiosk"
echo "    on every login). Standard XDG override -- no /etc edit needed, so"
echo "    no overlayroot workaround is needed even on an already-provisioned board."
cat <<'APPLABEOF' > /home/arduino/.config/autostart/ArduinoAppLab.desktop
[Desktop Entry]
Hidden=true
APPLABEOF

echo "==> Disabling light-locker autostart (stock-image screen locker; if it"
echo "    ever engaged it would park an unattended kiosk on a password prompt)"
cat <<'LOCKEREOF' > /home/arduino/.config/autostart/light-locker.desktop
[Desktop Entry]
Hidden=true
LOCKEREOF

echo "==> Ctrl+Alt+S settings hotkey (written directly to xfconf's XML store,"
echo "    so it applies on first XFCE login without needing a live session)"
XFCONF_FILE=/home/arduino/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-keyboard-shortcuts.xml
if [ -f "$XFCONF_FILE" ] && grep -q 'toggle-settings.sh' "$XFCONF_FILE"; then
  echo "    (already present, leaving as-is)"
else
  cat <<'XFCONFEOF' > "$XFCONF_FILE"
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-keyboard-shortcuts" version="1.0">
  <property name="commands" type="empty">
    <property name="custom" type="empty">
      <property name="&lt;Primary&gt;&lt;Alt&gt;s" type="string" value="/home/arduino/kiosk/toggle-settings.sh"/>
      <property name="override" type="bool" value="true"/>
    </property>
  </property>
</channel>
XFCONFEOF
fi
# If an XFCE session is already running (e.g. the script was started from the
# board's own desktop terminal), xfconfd has this channel cached in memory and
# won't pick up the file edit -- and may write its stale copy back over it.
# Set the same properties through the live daemon so both agree.
BUS="/run/user/$(id -u)/bus"
if [ -S "$BUS" ] && pgrep -u "$(id -u)" -x xfconfd > /dev/null; then
  export DBUS_SESSION_BUS_ADDRESS="unix:path=$BUS"
  xfconf-query -c xfce4-keyboard-shortcuts -p "/commands/custom/<Primary><Alt>s" \
    -n -t string -s /home/arduino/kiosk/toggle-settings.sh || true
  xfconf-query -c xfce4-keyboard-shortcuts -p /commands/custom/override \
    -n -t bool -s true || true
fi

echo "==> lightdm autologin (arduino -> xfce session)"
sudo mkdir -p /etc/lightdm/lightdm.conf.d
cat <<'AUTOLOGIN' | sudo tee /etc/lightdm/lightdm.conf.d/50-autologin.conf > /dev/null
[Seat:*]
autologin-user=arduino
autologin-user-timeout=0
autologin-session=xfce
AUTOLOGIN

echo "==> kiosk-server systemd service"
cat <<SERVICE | sudo tee /etc/systemd/system/kiosk-server.service > /dev/null
[Unit]
Description=Kiosk local settings/display server
After=network.target

[Service]
ExecStart=/usr/bin/python3 /home/arduino/kiosk/server.py
Restart=always
RestartSec=2
User=arduino
Group=arduino

[Install]
WantedBy=multi-user.target
SERVICE

sudo systemctl daemon-reload
sudo systemctl enable --now kiosk-server.service

echo "==> Wi-Fi connect helper (root-owned, invoked via a scoped sudoers NOPASSWD rule)"
echo "    Lives in /usr/local/sbin (not /home/arduino) so the unprivileged arduino"
echo "    user can never overwrite it and turn the sudoers grant into arbitrary root."
cat <<'WIFIEOF' | sudo tee /usr/local/sbin/kiosk-wifi-connect.sh > /dev/null
#!/bin/bash
# Invoked via sudo by server.py (running as the unprivileged `arduino` user).
# Takes a single JSON blob on stdin: {"ssid":..., "password":..., "hidden":true/false}
# rather than argv, so the password never appears in this script's own argv.
#
# Known residual risk: nmcli's own "device wifi connect ... password X" subcommand
# has no stdin-based secret input, so the plaintext password IS briefly visible in
# THAT process's argv (e.g. to `ps`) for the life of the nmcli call. Accepted here
# since no other local accounts exist on these boards.
set -uo pipefail

PERSIST_DIR=/home/arduino/kiosk/wifi-connections

payload=$(cat)
ssid=$(printf '%s' "$payload" | python3 -c 'import json,sys;print(json.load(sys.stdin)["ssid"])')
password=$(printf '%s' "$payload" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("password",""))')
hidden=$(printf '%s' "$payload" | python3 -c 'import json,sys;print("yes" if json.load(sys.stdin).get("hidden") else "")')

# Wrong-password attempts don't fail instantly -- NetworkManager retries the
# handshake for tens of seconds. Bound it so this can't hang the caller forever.
# Exit code 124 (from `timeout`) means "gave up", distinct from nmcli's own failures.
if [ -n "$password" ]; then
    # nmcli's own "device wifi connect ... password X" convenience wrapper has
    # multiple known bugs around 802-11-wireless-security.key-mgmt going missing:
    # one when it auto-generates a fresh profile for a HIDDEN network, another when
    # it UPDATES an EXISTING saved profile's password (reproduced live against a
    # real, already-known, non-hidden network -- NetworkManager's own audit log
    # showed op="connection-update" ... reason="802-11-wireless-security.key-mgmt:
    # property is missing"). Sidestep both by managing the profile ourselves instead
    # of trusting nmcli's create-or-update heuristic: explicitly (re)set key-mgmt
    # and psk before ever bringing the connection up, whether new or pre-existing.
    wifi_dev=$(nmcli -t -f DEVICE,TYPE device | awk -F: '$2=="wifi"{print $1; exit}')
    was_new=0
    if nmcli -t -f NAME connection show | grep -qFx "$ssid"; then
        nmcli connection modify "$ssid" \
            802-11-wireless.hidden "${hidden:-no}" \
            802-11-wireless-security.key-mgmt wpa-psk \
            802-11-wireless-security.psk "$password"
        add_rc=$?
    else
        was_new=1
        nmcli connection add type wifi con-name "$ssid" ifname "$wifi_dev" ssid "$ssid" \
            802-11-wireless.hidden "${hidden:-no}" \
            802-11-wireless-security.key-mgmt wpa-psk \
            802-11-wireless-security.psk "$password"
        add_rc=$?
    fi
    if [ "$add_rc" -eq 0 ]; then
        timeout 45 nmcli connection up "$ssid"
        rc=$?
        [ "$rc" -eq 0 ] || [ "$was_new" -eq 0 ] || nmcli connection delete "$ssid" >/dev/null 2>&1
    else
        rc=$add_rc
    fi
else
    # Open network, no wireless-security section involved -- nmcli's own
    # convenience wrapper has no known bug in this case.
    args=(device wifi connect "$ssid")
    [ -n "$hidden" ] && args+=(hidden yes)
    timeout 45 nmcli "${args[@]}"
    rc=$?
fi

# NetworkManager saves the new connection profile under /etc/NetworkManager,
# which lives on the tmpfs root overlay (see overlayroot below) -- it would
# otherwise vanish on the very next reboot/power cut, silently undoing what
# the front end just "saved". Copy it onto the real, persistent /home/arduino
# disk so kiosk-wifi-restore.sh can put it back before NetworkManager starts.
if [ "$rc" -eq 0 ]; then
    conn_file=$(nmcli -t -f TYPE,FILENAME connection show --active \
        | awk -F: '$1=="802-11-wireless"{print substr($0, length($1)+2); exit}')
    if [ -n "$conn_file" ] && [ -f "$conn_file" ]; then
        mkdir -p "$PERSIST_DIR"
        chmod 700 "$PERSIST_DIR"
        cp -p "$conn_file" "$PERSIST_DIR/$(basename "$conn_file")"
        chmod 600 "$PERSIST_DIR/$(basename "$conn_file")"
    fi
fi
exit "$rc"
WIFIEOF
sudo chown root:root /usr/local/sbin/kiosk-wifi-connect.sh
sudo chmod 700 /usr/local/sbin/kiosk-wifi-connect.sh

echo "==> Wi-Fi connection restore helper + boot-time systemd unit"
echo "    Copies persisted connection profiles from /home/arduino back into"
echo "    /etc/NetworkManager/system-connections before NetworkManager starts,"
echo "    since the tmpfs root overlay wipes that directory on every reboot."
cat <<'RESTOREEOF' | sudo tee /usr/local/sbin/kiosk-wifi-restore.sh > /dev/null
#!/bin/bash
# Run as root by kiosk-wifi-restore.service, before NetworkManager.service starts.
set -uo pipefail

SRC=/home/arduino/kiosk/wifi-connections
DST=/etc/NetworkManager/system-connections

[ -d "$SRC" ] || exit 0
mkdir -p "$DST"

shopt -s nullglob
for f in "$SRC"/*.nmconnection; do
    cp -p "$f" "$DST/"
    chown root:root "$DST/$(basename "$f")"
    chmod 600 "$DST/$(basename "$f")"
done
RESTOREEOF
sudo chown root:root /usr/local/sbin/kiosk-wifi-restore.sh
sudo chmod 700 /usr/local/sbin/kiosk-wifi-restore.sh

cat <<SERVICE | sudo tee /etc/systemd/system/kiosk-wifi-restore.service > /dev/null
[Unit]
Description=Restore persisted Wi-Fi connection profiles before NetworkManager starts
Before=NetworkManager.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/kiosk-wifi-restore.sh
RemainAfterExit=yes

[Install]
WantedBy=NetworkManager.service
SERVICE

sudo systemctl daemon-reload
sudo systemctl enable kiosk-wifi-restore.service

echo "==> Scoped sudoers rule for the Wi-Fi connect helper"
TMP_SUDOERS=$(mktemp)
cat <<'SUDOEOF' > "$TMP_SUDOERS"
# Managed by provision-kiosk.sh. Allows the kiosk server (running as `arduino`)
# to invoke ONLY this one wrapper as root, to change Wi-Fi from the on-device
# settings UI. The wrapper is root-owned and lives outside arduino's writable
# tree, so this grant cannot be escalated into arbitrary root access.
arduino ALL=(root) NOPASSWD: /usr/local/sbin/kiosk-wifi-connect.sh
SUDOEOF
sudo visudo -c -f "$TMP_SUDOERS"
sudo install -o root -g root -m 0440 "$TMP_SUDOERS" /etc/sudoers.d/kiosk-wifi
rm -f "$TMP_SUDOERS"

echo "==> Enabling overlayroot (read-only root, protects against hard power cuts)"
echo "    Doing this LAST and BEFORE root is ever overlaid, so this is a plain"
echo "    disk write -- no chroot dance needed (that's only required to patch"
echo "    an ALREADY-overlaid system after the fact)."
sudo bash -c '
set -e
sed -i "s/^overlayroot=.*/overlayroot=\"tmpfs:recurse=0\"/" /etc/overlayroot.conf
grep -q "^overlayroot=" /etc/overlayroot.conf || echo "overlayroot=\"tmpfs:recurse=0\"" >> /etc/overlayroot.conf
grep "^overlayroot=" /etc/overlayroot.conf
update-initramfs -u -k "$(uname -r)"
'

echo "==> Provisioning complete. Rebooting to activate everything..."
echo "    (autologin, kiosk display, Ctrl+Alt+S hotkey, hidden cursor,"
echo "     and the read-only overlay root all take effect from this boot on)"
sudo reboot
