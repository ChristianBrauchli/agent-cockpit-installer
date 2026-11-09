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

# Network behaviour.  A computer behind a firewall that silently drops packets
# must fail with a sentence within a sane time, not hang until the user gives up.
CONNECT_TIMEOUT="${COCKPIT_CONNECT_TIMEOUT:-15}"
READ_TIMEOUT="${COCKPIT_READ_TIMEOUT:-90}"
FETCH_ATTEMPTS="${COCKPIT_FETCH_ATTEMPTS:-3}"

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
HUB_HOST=""         # override the connector hub host from the manifest
HUB_PORT=""         # override the connector hub port from the manifest
BUNDLE_URL=""       # override the connector bundle URL
BUNDLE_SHA=""       # override the connector bundle checksum
DO_SERVICE=1
DO_OPENCLAW=1
DRY_RUN=0
UNINSTALL=0
PURGE=0

# What each stage actually did.  The closing screen reports these instead of
# claiming success, so a service that did not start is never described as
# running.  Values: skipped | ok | failed.
PAIR_RESULT="skipped"
SERVICE_RESULT="skipped"

usage() {
  cat <<'USAGE'
Agent Cockpit — Installation des Connectors

  --cockpit HOST:PORT    Adresse des Cockpits (Download-Endpunkt), z. B. cockpit.example.org:8444
  --fingerprint sha256:… Zertifikat-Fingerabdruck des Cockpits (steht im Cockpit)
  --code CODE            einmaliger Kopplungscode (steht im Cockpit)
  --name NAME            Name dieses Computers (Standard: Hostname)
  --hub-host HOST        Adresse des Connector-Kanals überschreiben
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
    --hub-host)       HUB_HOST="${2:-}"; shift 2 ;;
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
    --hub-host=*)     HUB_HOST="${1#*=}"; shift ;;
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
#
# The pin, not a CA chain, is what makes this transport trusted: the cockpit's
# certificate is self-signed, so a browser shows a warning for the same name —
# and that is exactly why this command does not depend on the browser, and why
# the certificate is checked here against the fingerprint the operator pasted.
#
# Exit codes let fetch() tell a transient failure from a permanent one:
#   2 name not resolvable   3 connection/read failed   4 certificate pin mismatch
#   5 HTTP error            6 TLS handshake failed
pinned_get() {
  PYTHONIOENCODING=utf-8 "$PY" - "$1" "$2" "$3" "$4" "$FINGERPRINT" \
      "$CONNECT_TIMEOUT" "$READ_TIMEOUT" <<'PY'
import hashlib, http.client, socket, ssl, sys
host, port, path, out, pin, connect_t, read_t = sys.argv[1:8]
port = int(port)
connect_t = float(connect_t)
read_t = float(read_t)


def fail(message, code):
    sys.stderr.write(message + "\n")
    raise SystemExit(code)


ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE
ctx.minimum_version = ssl.TLSVersion.TLSv1_2

try:
    raw = socket.create_connection((host, port), timeout=connect_t)
except socket.gaierror as exc:
    fail("Der Name %s liess sich nicht aufloesen (%s). Stimmt die Adresse?"
         % (host, exc), 2)
except (socket.timeout, TimeoutError):
    fail("Keine Antwort von %s:%s innerhalb von %gs. Blockiert eine Firewall "
         "oder ein Proxy die Verbindung? (Ausgangsport %s/TCP noetig)"
         % (host, port, connect_t, port), 3)
except OSError as exc:
    fail("Keine Verbindung zu %s:%s (%s). Laeuft das Cockpit, und stimmt die "
         "Adresse?" % (host, port, exc), 3)

try:
    tls = ctx.wrap_socket(raw, server_hostname=host)
except (ssl.SSLError, OSError) as exc:
    raw.close()
    fail("Die verschluesselte Verbindung zu %s:%s ist fehlgeschlagen (%s). "
         "Vermutlich antwortet an dieser Adresse ein anderer Dienst."
         % (host, port, exc), 6)

der = tls.getpeercert(binary_form=True) or b""
got = "sha256:" + hashlib.sha256(der).hexdigest()
if pin and got != pin:
    tls.close()
    fail("Das Zertifikat passt nicht: erhalten %s, erwartet %s. Der Befehl "
         "wurde moeglicherweise von einer anderen Adresse als der aktuellen "
         "kopiert — im Cockpit einen neuen Befehl erzeugen." % (got, pin), 4)

conn = http.client.HTTPSConnection(host, port, timeout=read_t, context=ctx)
conn.sock = tls
try:
    conn.request("GET", path, headers={
        "User-Agent": "agent-cockpit-installer/" + "0.1.0",
        "Connection": "close"})
    resp = conn.getresponse()
    body = resp.read()
    status = resp.status
except (socket.timeout, TimeoutError):
    tls.close()
    fail("Der Server hat %s nicht innerhalb von %gs vollstaendig beantwortet."
         % (path, read_t), 3)
except (OSError, http.client.HTTPException) as exc:
    tls.close()
    fail("Die Uebertragung von %s wurde abgebrochen (%s)." % (path, exc), 3)
finally:
    try:
        tls.close()
    except OSError:
        pass

if status != 200:
    fail("Der Server antwortete mit HTTP %s fuer %s." % (status, path), 5)
if out == "-":
    sys.stdout.buffer.write(body)
else:
    with open(out, "wb") as fh:
        fh.write(body)
PY
}

# Fetch a path, retrying the failures that are worth retrying — a slow network, a
# service still starting — and giving up at once on the ones that are not: a name
# that does not resolve, a certificate that does not match, a wrong answer.
#   fetch HOST PORT PATH OUTFILE
fetch() {
  _attempt=1
  while : ; do
    _code=0
    pinned_get "$1" "$2" "$3" "$4" || _code=$?
    [ "$_code" -eq 0 ] && return 0
    case "$_code" in
      2|4|5) return "$_code" ;;
    esac
    if [ "$_attempt" -ge "$FETCH_ATTEMPTS" ]; then
      say "   Nach $FETCH_ATTEMPTS Versuchen keine stabile Verbindung." >&2
      return "$_code"
    fi
    say "   Verbindung unterbrochen — neuer Versuch ($_attempt/$FETCH_ATTEMPTS) …" >&2
    _attempt=$((_attempt + 1))
    sleep 3
  done
}

# Turn a fetch() exit code into one sentence the operator can act on.  The whole
# point of distinct exit codes is that this can be specific.
fetch_hint() {
  case "$1" in
    2) say "   Der Name der Cockpit-Adresse lässt sich auf diesem Computer nicht auflösen." >&2 ;;
    3) say "   Die Verbindung kam nicht zustande. Prüfe die Internetverbindung; in Firmennetzen muss der Ausgangsport $DIST_PORT/TCP erlaubt sein." >&2 ;;
    4) say "   Das Zertifikat passt nicht zum Fingerabdruck. Erzeuge im Cockpit einen neuen Befehl und führe genau diesen aus." >&2 ;;
    5) say "   Der Server hat die Datei nicht herausgegeben. Vermutlich müssen im Cockpit zuerst die Installationsdateien gebaut werden." >&2 ;;
    6) say "   An dieser Adresse antwortet kein Cockpit. Stimmen Host und Port?" >&2 ;;
  esac
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
    SERVICE_RESULT="failed"
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
  # A unit that is enabled is not a unit that is running.  Ask systemd, and let
  # the closing screen say what it answered.
  for _ in 1 2 3 4 5 6 7 8; do
    if systemctl --user is-active agent-cockpit-connector.service >/dev/null 2>&1; then
      SERVICE_RESULT="ok"
      break
    fi
    sleep 0.5
  done
  if [ "$SERVICE_RESULT" = "ok" ]; then
    ok "Hintergrunddienst läuft (systemd --user)"
  else
    SERVICE_RESULT="failed"
    warn "Der Dienst ist eingerichtet, läuft aber noch nicht:"
    systemctl --user status agent-cockpit-connector.service --no-pager 2>&1 \
      | tail -n 4 >&2 || true
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
    if launchctl list com.agentcockpit.connector >/dev/null 2>&1; then
      SERVICE_RESULT="ok"
      ok "Hintergrunddienst läuft (launchd) — startet automatisch nach der Anmeldung"
    else
      SERVICE_RESULT="failed"
      warn "Der Dienst ist eingerichtet, ist aber nicht geladen."
    fi
  else
    SERVICE_RESULT="failed"
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
  # One retrying fetch, and a sentence that names what actually failed instead of
  # one generic "not reachable" for every cause.
  _code=0
  MANIFEST="$(fetch "$DIST_HOST" "$DIST_PORT" "/dl/manifest.json" -)" || _code=$?
  if [ "$_code" -ne 0 ]; then
    say "   Das Cockpit unter $DIST_HOST:$DIST_PORT konnte nicht kontaktiert werden." >&2
    fetch_hint "$_code"
    die "Die Installation wurde abgebrochen — nichts wurde verändert."
  fi
  read_manifest() {
    printf '%s' "$MANIFEST" | "$PY" -c \
      "import json,sys;d=json.load(sys.stdin);print(eval('d'+sys.argv[1]))" "$1"
  }
  MV="$(read_manifest "['manifest_version']" 2>/dev/null || echo '')"
  [ "$MV" = "$MANIFEST_VERSION" ] || die "Der Server spricht eine andere Installationsversion ($MV). Bitte Cockpit und Installer aktualisieren."
  [ -n "$HUB_PORT" ] || HUB_PORT="$(read_manifest "['hub']['port']")"
  # The hub can live at a different address than the download endpoint — a
  # tunnel hands out one host per forwarded port.  The manifest says where it is;
  # the download host is only the fallback, so a computer that downloaded the
  # installer successfully still pairs against the port it can actually reach.
  [ -n "$HUB_HOST" ] || HUB_HOST="$(read_manifest "['hub']['host']" 2>/dev/null || echo '')"
  [ -n "$HUB_HOST" ] || HUB_HOST="$DIST_HOST"
  [ -n "$BUNDLE_URL" ] || BUNDLE_URL="$(read_manifest "['bundle']['url']")"
  [ -n "$BUNDLE_SHA" ] || BUNDLE_SHA="$(read_manifest "['bundle']['sha256']")"
  OC_VERSION="$(read_manifest "['openclaw']['version']")"
  ok "Cockpit erkannt (Installer-Version $MV, Connector-Kanal $HUB_HOST:$HUB_PORT)"

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
  else
    BUNDLE_PATH="/dl/connector.pyz"
  fi
  _code=0
  fetch "$DIST_HOST" "$DIST_PORT" "$BUNDLE_PATH" "$TMP" || _code=$?
  if [ "$_code" -ne 0 ]; then
    rm -f "$TMP" 2>/dev/null || true
    say "   Der Connector konnte nicht geladen werden ($BUNDLE_PATH)." >&2
    fetch_hint "$_code"
    die "Die Installation wurde abgebrochen — nichts wurde verändert."
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
        "$PY" "$PYZ" pair --cockpit-host "$HUB_HOST" --cockpit-port "$HUB_PORT" \
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
      *)     warn "Unbekanntes System — kein Dienst eingerichtet."
             SERVICE_RESULT="failed" ;;
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
  # ...and whether the background service is really running, not merely written.
  if [ "$DO_SERVICE" = "1" ]; then
    case "$SERVICE_RESULT" in
      ok) say "   Der Hintergrunddienst läuft und startet nach einem Neustart neu." ;;
      failed) warn "Der Hintergrunddienst ist eingerichtet, startet aber noch nicht." ;;
    esac
  fi
  say ""
  say "   Deinstallieren:  sh install.sh --uninstall   (Agentendaten bleiben erhalten)"
}

# ------------------------------------------------------------------ main ----
if [ "$UNINSTALL" = "1" ]; then
  do_uninstall
  exit 0
fi
do_install
