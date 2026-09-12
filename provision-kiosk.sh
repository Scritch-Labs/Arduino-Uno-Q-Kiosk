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
import json, os, subprocess, tempfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs

CONFIG_PATH = "/home/arduino/kiosk/config.json"
MODE_PATH = "/home/arduino/kiosk/mode"
DEFAULT_URL = "https://example.com"

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

SETTINGS_PAGE = """<!doctype html>
<html><head><meta charset="utf-8"><title>Kiosk Settings</title>
<style>
  body {{ font-family: sans-serif; background:#111; color:#eee; display:flex;
         align-items:center; justify-content:center; height:100vh; margin:0; }}
  form {{ background:#1c1c1c; padding:2rem; border-radius:8px; width:min(90%,480px); }}
  input {{ width:100%; padding:0.6rem; font-size:1rem; box-sizing:border-box; margin-top:0.5rem; }}
  button {{ margin-top:1rem; padding:0.6rem 1.2rem; font-size:1rem; cursor:pointer; }}
  p {{ opacity: 0.7; }}
</style></head>
<body>
  <form method="post" action="/settings">
    <label>Website URL</label>
    <input name="url" type="text" value="{url}" required>
    <button type="submit">Save &amp; Return to Site</button>
    <p>Saving returns the display to the site automatically.</p>
  </form>
</body></html>
"""

class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def do_GET(self):
        if self.path == "/settings":
            body = SETTINGS_PAGE.format(url=read_url()).encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(303)
            self.send_header("Location", "/settings")
            self.end_headers()

    def do_POST(self):
        if self.path == "/settings":
            length = int(self.headers.get("Content-Length", 0))
            data = parse_qs(self.rfile.read(length).decode())
            url = data.get("url", [""])[0].strip()
            if url.startswith("http://") or url.startswith("https://"):
                write_url(url)
                set_mode("site")
                subprocess.run(["pkill", "-f", "chromium.*--app="], check=False)
            self.send_response(303)
            self.send_header("Location", "/settings")
            self.end_headers()
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
    </property>
  </property>
</channel>
XFCONFEOF
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
