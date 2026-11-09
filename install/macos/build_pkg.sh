#!/bin/sh
# Build the Agent Cockpit macOS installer package.  macOS only: it needs
# `pkgbuild`, which exists on no other platform.
#
#   sh install/macos/build_pkg.sh [OUTPUT.pkg]
#
# The package is deliberately **generic**: it carries the public installer and
# the pairing helper, and no address, no code and no secret.  A package that
# knew which cockpit to talk to would have to be built per pairing, and the
# cockpit runs on Linux where `pkgbuild` does not exist — so the pairing link
# carries the details instead.
#
# The package is **unsigned**: no Apple Developer ID is available here.  Gatekeeper
# will therefore warn on first launch; that is stated in the README and in the
# cockpit, never hidden.  Signing and notarising would only add
# `productsign`/`notarytool` steps around this same payload.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
OUT="${1:-$ROOT/AgentCockpit.pkg}"
VERSION="${VERSION:-1.0.0}"
IDENTIFIER="${IDENTIFIER:-com.agentcockpit.installer}"

command -v pkgbuild >/dev/null 2>&1 \
  || { echo "pkgbuild not found — this script builds macOS packages and needs macOS." >&2; exit 2; }

# The installer lives in `install/` in the cockpit checkout and at the root of
# the distribution repository, so accept either layout.
installer=""
for candidate in "$ROOT/install/install.sh" "$ROOT/install.sh"; do
  if [ -f "$candidate" ]; then installer="$candidate"; break; fi
done
[ -n "$installer" ] \
  || { echo "install.sh not found (looked in install/ and the repository root)" >&2; exit 2; }
[ -f "$HERE/app/Info.plist" ] || { echo "Info.plist missing" >&2; exit 2; }
[ -f "$HERE/app/agent-cockpit-pair" ] || { echo "pairing helper missing" >&2; exit 2; }
[ -f "$HERE/README.txt" ] || { echo "README.txt missing" >&2; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

APP="$WORK/root/Applications/Agent Cockpit.app"
mkdir -p "$WORK/root/usr/local/bin" "$APP/Contents/MacOS" "$WORK/root/usr/local/share/agent-cockpit"

# The installer itself, at a fixed place the pairing helper knows.
install -m 0755 "$installer" "$WORK/root/usr/local/bin/agent-cockpit-install"
# The app that receives the pairing link.  Its executable is a shell script, so
# it runs even on a Mac that has no Python yet — the installer it calls is what
# then explains how to get Python.
install -m 0644 "$HERE/app/Info.plist" "$APP/Contents/Info.plist"
install -m 0755 "$HERE/app/agent-cockpit-pair" "$APP/Contents/MacOS/agent-cockpit-pair"
install -m 0644 "$HERE/README.txt" "$WORK/root/usr/local/share/agent-cockpit/README.txt"

rm -f "$OUT"
pkgbuild --root "$WORK/root" \
         --identifier "$IDENTIFIER" \
         --version "$VERSION" \
         --install-location / \
         "$OUT"
echo "built $OUT"
