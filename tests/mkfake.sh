#!/usr/bin/env bash
# Make runnable copies of both report scripts that talk to the stand-in API.
# Only the API base URL changes; every other line is the script as it ships.
#
#   tests/mkfake.sh PORT DEST
#
set -u
PORT="$1"; DEST="$2"
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)

sed -e "s#^API=\"https://api.axur.com.*#API=\"http://127.0.0.1:$PORT\"#" \
    "$ROOT/axur-report.sh" > "$DEST/r.sh"
chmod +x "$DEST/r.sh"

sed -e "s#^\$api = \"https://api.axur.com.*#\$api = \"http://127.0.0.1:$PORT\"#" \
    "$ROOT/axur-report.ps1" > "$DEST/r.ps1"

# Two things have to be true, not one. A copy that still names the real API
# would talk to Axur with whatever key it is given. A copy where the change
# silently missed would talk to nothing, and every check would then be testing
# the error path instead of the thing it names.
for f in "$DEST/r.sh" "$DEST/r.ps1"; do
  if grep -q 'api\.axur\.com' "$f"; then
    echo "mkfake.sh: $f still points at the real API." >&2; exit 1
  fi
  if ! grep -q "http://127.0.0.1:$PORT" "$f"; then
    echo "mkfake.sh: $f does not point at http://127.0.0.1:$PORT." >&2; exit 1
  fi
done
