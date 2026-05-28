#!/bin/bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$DIR")"

errors=0
checked=0

for f in "$REPO_ROOT"/displaycameras "$REPO_ROOT"/omxplayer_dbuscontrol "$REPO_ROOT"/*.sh "$REPO_ROOT"/lib/*.sh "$REPO_ROOT"/scripts/*.sh; do
    [ -f "$f" ] || continue
    if ! bash -n "$f" 2>&1; then
        echo "FAIL: $f" >&2
        errors=$((errors + 1))
    else
        echo "OK:   $f"
    fi
    checked=$((checked + 1))
done

echo
echo "Checked $checked files, $errors failures"

if [ "$errors" -gt 0 ]; then
    exit 1
fi
