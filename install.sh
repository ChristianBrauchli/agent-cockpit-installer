#!/bin/sh
# Agent Cockpit — connector installer for macOS and Linux.
#
# This is the *public* half of the installation: it contains no cockpit source,
# no connector source and no secret.  It downloads the connector from the
# operator's own cockpit over TLS pinned to a certificate fingerprint, installs
# it for the current user, registers a background service and pairs the computer
# with the cockpit.
#
# The whole install runs as the normal user.  Nothing is installed globally, no
# administrator rights are required, and an existing installation (OpenClaw
# configuration, sessions, agent data) is never destroyed.
#
# Typical use — the cockpit shows this exact command in its setup wizard:
#
#   curl -fsSL https://raw.githubusercontent.com/ChristianBrauchli/agent-cockpit-installer/main/install.sh \
#     | sh -s -- --cockpit cockpit.example.org:8444 --fingerprint sha256:… --code ABCD-1234
#
set -eu

INSTALLER_VERSION="0.1.0"
MANIFEST_VERSION="1"

# ---------------------------------------------------------------- output ----
say()  { printf '%s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }
ok()   { printf '   ok    %s\n' "$*"; }
warn() { printf '   !!!   %s\n' "$*" >&2; }
die()  { printf '\n   FEHLER: %s\n' "$*" >&2; exit 1; }

# --------------------------------------------------------------- options ----
COCKPIT=""          # host:port of the cockpit's download endpoint
FINGERPRINT=""      # sha256:… of the cockpit certificate
CODE=""             # one-time pairing code
NAME=""             # display name for this computer
HUB_PORT=""         # override the connector hub port from the manifest
BUNDLE_URL=""       # override the connector bundle URL
BUNDLE_SHA=""       # override the connector bundle checksum
DO_SERVICE=1
DO_OPENCLAW=1
DRY_RUN=0
UNINSTALL=0
PURGE=0

usage() {
  cat <<'USAGE'
Agent Cockpit — Installation des Connectors

  --cockpit HOST:PORT    Adresse des Cockpits (Download-Endpunkt), z. B. cockpit.example.org:8444
  --fingerprint sha256:… Zertifikat-Fingerabdruck des Cockpits (steht im Cockpit)
  --code CODE            einmaliger Kopplungscode (steht im Cockpit)
  --name NAME            Name dieses Computers (Standard: Hostname)
  --hub-port PORT        Port des Connector-Kanals überschreiben
  --bundle URL           Connector-Paket überschreiben
  --bundle-sha256 HEX    Prüfsumme des Connector-Pakets überschreiben
  --no-service           keinen Hintergrunddienst einrichten
  --no-openclaw          OpenClaw nicht installieren (nur den Connector)
  --dry-run              nur anzeigen, was geschehen würde
  --uninstall            Connector entfernen (Agentendaten bleiben erhalten)
  --purge                mit --uninstall: auch die Agentendaten löschen
  --version              Version dieses Installers anzeigen
  -h, --help             diese Hilfe
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --cockpit)        COCKPIT="${2:-}"; shift 2 ;;
    --fingerprint)    FINGERPRINT="${2:-}"; shift 2 ;;
    --code)           CODE="${2:-}"; shift 2 ;;
    --name)           NAME="${2:-}"; shift 2 ;;
    --hub-port)       HUB_PORT="${2:-}"; shift 2 ;;
    --bundle)         BUNDLE_URL="${2:-}"; shift 2 ;;
    --bundle-sha256)  BUNDLE_SHA="${2:-}"; shift 2 ;;
    --no-service)     DO_SERVICE=0; shift ;;
    --no-openclaw)    DO_OPENCLAW=0; shift ;;
    --dry-run)        DRY_RUN=1; shift ;;
    --uninstall)      UNINSTALL=1; shift ;;
    --purge)          PURGE=1; shift ;;
    --version)        say "agent-cockpit-installer $INSTALLER_VERSION"; exit 0 ;;
    -h|--help)        usage; exit 0 ;;
    --cockpit=*)      COCKPIT="${1#*=}"; shift ;;
    --fingerprint=*)  FINGERPRINT="${1#*=}"; shift ;;
    --code=*)         CODE="${1#*=}"; shift ;;
    --name=*)         NAME="${1#*=}"; shift ;;
    --hub-port=*)     HUB_PORT="${1#*=}"; shift ;;
    --bundle=*)       BUNDLE_URL="${1#*=}"; shift ;;
    --bundle-sha256=*) BUNDLE_SHA="${1#*=}"; shift ;;
    *) die "Unbekannte Option: $1 (--help zeigt alle Optionen)" ;;
  esac
done

HOME_DIR="${HOME:-}"
[ -n "$HOME_DIR" ] || die "HOME ist nicht gesetzt."
ROOT="${COCKPIT_HOME:-$HOME_DIR/.agent-cockpit}"
APP="$ROOT/app"
PYZ="$APP/connector.pyz"
STATE_DATA="$ROOT/data"

# ------------------------------------------------------------ system info ----
detect_os() {
  case "$(uname -s)" in
    Linux)  OS=linux ;;
    Darwin) OS=macos ;;
    *)      OS=unknown ;;
  esac
  ARCH="$(uname -m)"
  HOSTNAME_LOCAL="$(hostname 2>/dev/null || echo computer)"
}
detect_os
[ -n "$NAME" ] || NAME="$HOSTNAME_LOCAL"

case "$OS" in
  linux) OS_LABEL="Linux ($ARCH)" ;;
  macos) OS_LABEL="macOS ($ARCH)" ;;
  *)     OS_LABEL="unbekanntes System ($(uname -s))" ;;
esac

# ------------------------------------------------------------- utilities ----
need_python() {
  command -v python3 >/dev/null 2>&1 \
    || die "python3 wurde nicht gefunden. Installiere Python 3 (macOS: 'brew install python3' oder die Version von python.org; Ubuntu/Debian: 'sudo apt install python3')."
  PY="$(command -v python3)"
  "$PY" - <<'PY' || die "python3 ist zu alt (benötigt wird 3.8 oder neuer)."
import sys
sys.exit(0 if sys.version_info >= (3, 8) else 1)
PY
}

# Fetch a path from the cockpit over TLS pinned to $FINGERPRINT.
#   pinned_get HOST PORT PATH OUTFILE   (OUTFILE "-" writes to stdout)
pinned_get() {
  "$PY" - "$1" "$2" "$3" "$4" "$FINGERPRINT" <<'PY'
import hashlib, http.client, ssl, sys
host, port, path, out, pin = sys.argv[1:6]
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE
conn = http.client.HTTPSConnection(host, int(port), context=ctx, timeout=60)
try:
    conn.connect()
except OSError as exc:
    sys.stderr.write("keine Verbindung zu %s:%s (%s)\n" % (host, port, exc))
    sys.exit(3)
der = conn.sock.getpeercert(binary_form=True)
got = "sha256:" + hashlib.sha256(der).hexdigest()
if pin and got != pin:
    sys.stderr.write("Zertifikat passt nicht: erhalten %s, erwartet %s\n" % (got, pin))
    sys.exit(4)
conn.request("GET", path, headers={"User-Agent": "agent-cockpit-installer/" + "0.1.0"})
resp = conn.getresponse()
body = resp.read()
if resp.status != 200:
    sys.stderr.write("Server antwortete mit HTTP %s für %s\n" % (resp.status, path))
    sys.exit(5)
if out == "-":
    sys.stdout.buffer.write(body)
else:
    with open(out, "wb") as fh:
        fh.write(body)
PY
}

sha256_of() {
  "$PY" - "$1" <<'PY'
import hashlib, sys
h = hashlib.sha256()
with open(sys.argv[1], "rb") as fh:
    for chunk in iter(lambda: fh.read(1 << 20), b""):
        h.update(chunk)
print(h.hexdigest())
PY
}

# ------------------------------------------------------------- uninstall ----
service_stop_and_remove() {
  case "$OS" in
    linux)
      UNIT="$HOME_DIR/.config/systemd/user/agent-cockpit-connector.service"
      if command -v systemctl >/dev/null 2>&1; then
        systemctl --user stop agent-cockpit-connector.service 2>/dev/null || true
        systemctl --user disable agent-cockpit-connector.service 2>/dev/null || true
      fi
      [ -f "$UNIT" ] && rm -f "$UNIT" && ok "systemd-Dienst entfernt"
      ;;
    macos)
      PLIST="$HOME_DIR/Library/LaunchAgents/com.agentcockpit.connector.plist"
      if command -v launchctl >/dev/null 2>&1; then
        launchctl unload "$PLIST" 2>/dev/null || true
      fi
      [ -f "$PLIST" ] && rm -f "$PLIST" && ok "launchd-Dienst entfernt"
      ;;
  esac
  return 0
}

do_uninstall() {
  step "Agent Cockpit — Connector entfernen"
  say "   System: $OS_LABEL"
  if [ "$DRY_RUN" = "1" ]; then
    say "   (Probelauf) Dienst stoppen und entfernen, $APP löschen"
    [ "$PURGE" = "1" ] && say "   (Probelauf) Agentendaten löschen: $STATE_DATA" \
                       || say "   (Probelauf) Agentendaten bleiben: $STATE_DATA"
    return 0
  fi
  service_stop_and_remove
  if [ -d "$APP" ]; then
    rm -rf "$APP"
    ok "Programm entfernt: $APP"
  fi
  rm -f "$ROOT/config.json" 2>/dev/null || true
  if [ "$PURGE" = "1" ]; then
    rm -rf "$STATE_DATA"
    ok "Agentendaten entfernt: $STATE_DATA"
  else
    say "   Agentendaten bleiben erhalten: $STATE_DATA"
  fi
  say ""
  say "   Der Computer wurde vom Cockpit getrennt. Im Cockpit kann der Eintrag"
  say "   unter „Verbundene Geräte“ zusätzlich entfernt werden."
  return 0
}

# --------------------------------------------------------------- service ----
install_service_linux() {
  UNIT_DIR="$HOME_DIR/.config/systemd/user"
  UNIT="$UNIT_DIR/agent-cockpit-connector.service"
  if ! command -v systemctl >/dev/null 2>&1; then
    warn "systemd ist nicht vorhanden — der Connector startet nicht automatisch."
    return 1
  fi
  mkdir -p "$UNIT_DIR"
  cat > "$UNIT" <<EOF
[Unit]
Description=Agent Cockpit connector
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=COCKPIT_CONNECTOR_HOME=$ROOT
Environment=COCKPIT_CONNECTOR_ROOT=$ROOT
ExecStart=$PY $PYZ run
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
EOF
  systemctl --user daemon-reload 2>/dev/null || true
  systemctl --user enable agent-cockpit-connector.service >/dev/null 2>&1 || true
  systemctl --user restart agent-cockpit-connector.service >/dev/null 2>&1 || true
  if systemctl --user is-active agent-cockpit-connector.service >/dev/null 2>&1; then
    ok "Hintergrunddienst läuft (systemd --user)"
  else
    warn "Der Dienst wurde eingerichtet, läuft aber noch nicht."
  fi
  # Without lingering a user service stops when the last session ends.  Enabling
  # it may need administrator rights; say so rather than pretending.
  if command -v loginctl >/dev/null 2>&1; then
    if loginctl enable-linger "$(id -un)" >/dev/null 2>&1; then
      ok "Der Dienst startet auch nach einem Neustart ohne Anmeldung."
    else
      warn "Für den automatischen Start nach dem Neustart fehlt eventuell noch:"
      warn "  sudo loginctl enable-linger $(id -un)"
    fi
  fi
  return 0
}

install_service_macos() {
  PLIST_DIR="$HOME_DIR/Library/LaunchAgents"
  PLIST="$PLIST_DIR/com.agentcockpit.connector.plist"
  mkdir -p "$PLIST_DIR"
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.agentcockpit.connector</string>
  <key>ProgramArguments</key>
  <array>
    <string>$PY</string>
    <string>$PYZ</string>
    <string>run</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>COCKPIT_CONNECTOR_HOME</key><string>$ROOT</string>
    <key>COCKPIT_CONNECTOR_ROOT</key><string>$ROOT</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$ROOT/connector.log</string>
  <key>StandardErrorPath</key><string>$ROOT/connector.log</string>
</dict>
</plist>
EOF
  if command -v launchctl >/dev/null 2>&1; then
    launchctl unload "$PLIST" 2>/dev/null || true
    launchctl load -w "$PLIST" >/dev/null 2>&1 || true
    ok "Hintergrunddienst eingerichtet (launchd) — startet automatisch nach der Anmeldung"
  else
    warn "launchctl nicht gefunden — der Connector startet nicht automatisch."
    return 1
  fi
  return 0
}

# --------------------------------------------------------------- openclaw ----
install_openclaw() {
  if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
    warn "Node.js/npm fehlt — OpenClaw kann nicht installiert werden."
    warn "Installiere Node.js 20 oder neuer, dann führe diesen Befehl erneut aus."
    return 1
  fi
  OC_DIR="$ROOT/openclaw"
  mkdir -p "$OC_DIR"
  if [ -f "$OC_DIR/node_modules/openclaw/package.json" ]; then
    HAVE="$("$PY" -c "import json,sys;print(json.load(open(sys.argv[1]))['version'])" \
           "$OC_DIR/node_modules/openclaw/package.json" 2>/dev/null || echo '')"
    if [ -n "$HAVE" ] && [ "$HAVE" = "$OC_VERSION" ]; then
      ok "OpenClaw $HAVE ist bereits installiert (Konfiguration bleibt erhalten)"
      return 0
    fi
    [ -n "$HAVE" ] && say "   OpenClaw $HAVE gefunden, aktualisiere auf $OC_VERSION"
  fi
  cat > "$OC_DIR/package.json" <<EOF
{
  "name": "agent-cockpit-openclaw-runtime",
  "version": "0.1.0",
  "private": true,
  "description": "Local, reproducible OpenClaw install used as Agent Cockpit's agent engine.",
  "license": "MIT",
  "allowScripts": { "openclaw": true },
  "dependencies": { "openclaw": "$OC_VERSION" }
}
EOF
  say "   Installiere OpenClaw $OC_VERSION (kann einige Minuten dauern) …"
  if (cd "$OC_DIR" && npm install --no-audit --no-fund --loglevel=error >/dev/null 2>&1); then
    ok "OpenClaw $OC_VERSION installiert"
    return 0
  fi
  warn "Die OpenClaw-Installation ist fehlgeschlagen. Details:"
  (cd "$OC_DIR" && npm install --no-audit --no-fund --loglevel=error 2>&1 | tail -n 15) || true
  return 1
}

# --------------------------------------------------------------- install ----
do_install() {
  need_python

  [ -n "$COCKPIT" ] || die "--cockpit HOST:PORT fehlt."
  case "$COCKPIT" in
    *:*) DIST_HOST="${COCKPIT%%:*}"; DIST_PORT="${COCKPIT##*:}" ;;
    *)   die "--cockpit muss HOST:PORT sein, z. B. cockpit.example.org:8444" ;;
  esac
  [ -n "$FINGERPRINT" ] || die "--fingerprint sha256:… fehlt."
  case "$FINGERPRINT" in
    sha256:*) : ;;
    *) die "--fingerprint muss mit 'sha256:' beginnen." ;;
  esac

  step "Agent Cockpit — Installation"
  say "   System:     $OS_LABEL"
  say "   Cockpit:    $DIST_HOST:$DIST_PORT"
  say "   Zielordner: $ROOT"
  say "   Name:       $NAME"

  # -- manifest ------------------------------------------------------------
  MANIFEST="$(pinned_get "$DIST_HOST" "$DIST_PORT" "/dl/manifest.json" -)" \
    || die "Das Cockpit ist nicht erreichbar oder das Zertifikat passt nicht. Stimmt die Adresse, und läuft der Dienst?"
  read_manifest() {
    printf '%s' "$MANIFEST" | "$PY" -c \
      "import json,sys;d=json.load(sys.stdin);print(eval('d'+sys.argv[1]))" "$1"
  }
  MV="$(read_manifest "['manifest_version']" 2>/dev/null || echo '')"
  [ "$MV" = "$MANIFEST_VERSION" ] || die "Der Server spricht eine andere Installationsversion ($MV). Bitte Cockpit und Installer aktualisieren."
  [ -n "$HUB_PORT" ] || HUB_PORT="$(read_manifest "['hub']['port']")"
  [ -n "$BUNDLE_URL" ] || BUNDLE_URL="$(read_manifest "['bundle']['url']")"
  [ -n "$BUNDLE_SHA" ] || BUNDLE_SHA="$(read_manifest "['bundle']['sha256']")"
  OC_VERSION="$(read_manifest "['openclaw']['version']")"
  ok "Cockpit erkannt (Installer-Version $MV)"

  if [ "$DRY_RUN" = "1" ]; then
    say ""
    say "   (Probelauf) Es würde nun:"
    say "     - der Connector nach $PYZ geladen und geprüft"
    [ "$DO_OPENCLAW" = "1" ] && say "     - OpenClaw $OC_VERSION in $ROOT/openclaw installiert"
    [ "$DO_SERVICE" = "1" ] && say "     - ein Hintergrunddienst eingerichtet"
    say "     - dieser Computer mit dem Cockpit gekoppelt (Code $CODE)"
    return 0
  fi

  mkdir -p "$APP"

  # -- connector bundle ----------------------------------------------------
  TMP="$APP/connector.pyz.part"
  if [ -n "$BUNDLE_URL" ]; then
    BUNDLE_PATH="${BUNDLE_URL#*://}"; BUNDLE_PATH="/${BUNDLE_PATH#*/}"
    pinned_get "$DIST_HOST" "$DIST_PORT" "$BUNDLE_PATH" "$TMP" \
      || die "Der Connector konnte nicht geladen werden."
  else
    pinned_get "$DIST_HOST" "$DIST_PORT" "/dl/connector.pyz" "$TMP" \
      || die "Der Connector konnte nicht geladen werden."
  fi
  GOT_SHA="$(sha256_of "$TMP")"
  if [ -n "$BUNDLE_SHA" ] && [ "$GOT_SHA" != "$BUNDLE_SHA" ]; then
    rm -f "$TMP"
    die "Die Prüfsumme des Connectors stimmt nicht (erhalten $GOT_SHA). Die Datei wurde verworfen."
  fi
  mv "$TMP" "$PYZ"
  chmod 700 "$PYZ"
  ok "Connector installiert und geprüft (sha256 ${GOT_SHA%${GOT_SHA#??????}}…)"

  # -- OpenClaw ------------------------------------------------------------
  if [ "$DO_OPENCLAW" = "1" ]; then
    install_openclaw || warn "OpenClaw fehlt noch — der Agent kann erst nach der Installation antworten."
  fi

  # -- pairing -------------------------------------------------------------
  PAIR_RESULT="skipped"
  if [ -n "$CODE" ]; then
    step "Computer mit dem Cockpit koppeln"
    if COCKPIT_CONNECTOR_HOME="$ROOT" COCKPIT_CONNECTOR_ROOT="$ROOT" \
        "$PY" "$PYZ" pair --cockpit-host "$DIST_HOST" --cockpit-port "$HUB_PORT" \
          --fingerprint "$FINGERPRINT" --code "$CODE" --name "$NAME"; then
      PAIR_RESULT="ok"
      ok "Dieser Computer ist mit dem Cockpit verbunden."
    else
      PAIR_RESULT="failed"
      warn "Die Kopplung ist nicht gelungen. Der Code ist nur einmal und nur kurz gültig."
      warn "Im Cockpit einen neuen Code erzeugen und diesen Befehl erneut ausführen."
    fi
  else
    warn "Kein Kopplungscode angegeben — die Kopplung muss später im Cockpit erfolgen."
  fi

  # -- service -------------------------------------------------------------
  if [ "$DO_SERVICE" = "1" ]; then
    step "Hintergrunddienst einrichten"
    case "$OS" in
      linux) install_service_linux || true ;;
      macos) install_service_macos || true ;;
      *)     warn "Unbekanntes System — kein Dienst eingerichtet." ;;
    esac
  fi

  # -- what actually happened ---------------------------------------------
  # The last screen has to say whether the *pairing* succeeded.  It used to
  # print the same "everything is connected" summary after a rejected code,
  # which is exactly the kind of claim the product must never make.
  step "Ergebnis"
  case "$PAIR_RESULT" in
    ok)
      say "   Dieser Computer ist mit dem Cockpit verbunden."
      say "   Der Connector läuft im Hintergrund und verbindet sich automatisch neu."
      say "   Öffne das Cockpit und wähle diesen Computer als Agentenlaufzeit aus."
      ;;
    failed)
      say "   Die Installation ist abgeschlossen, die Kopplung aber NICHT."
      say "   Erzeuge im Cockpit einen neuen Code und führe denselben Befehl erneut aus."
      ;;
    *)
      say "   Der Connector ist installiert, aber noch nicht gekoppelt."
      say "   Die Kopplung erfolgt im Cockpit unter „Computer verbinden“."
      ;;
  esac
  say ""
  say "   Deinstallieren:  sh install.sh --uninstall   (Agentendaten bleiben erhalten)"
}

# ------------------------------------------------------------------ main ----
if [ "$UNINSTALL" = "1" ]; then
  do_uninstall
  exit 0
fi
do_install
