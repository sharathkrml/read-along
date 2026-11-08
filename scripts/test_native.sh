#!/bin/bash
# Native + fixture checks for Read Along: reproducible PDF fixtures, then an
# assert-based native executable built from the non-app-entry Swift sources.
# Uses only temporary workspaces; no network, model weights, live library, or
# microphone. Fails nonzero on any assertion or compiler failure.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PY="$ROOT/.venv/bin/python"
[ -x "$PY" ] || { echo "missing $PY (run make setup)" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/readalong-native-checks.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

echo "==> Fixtures"
"$PY" "$ROOT/macapp/Tests/make_fixtures.py" generate "$WORK/a" >/dev/null
"$PY" "$ROOT/macapp/Tests/make_fixtures.py" generate "$WORK/b" >/dev/null
diff "$WORK/a/summary.json" "$WORK/b/summary.json" >/dev/null
echo "ok  fixture regeneration is reproducible"
"$PY" "$ROOT/macapp/Tests/make_fixtures.py" verify "$WORK/a"

echo "==> Native checks"
BIN="$WORK/NativeChecks"
xcrun swiftc -O -target arm64-apple-macos14.0 -framework Foundation \
  -o "$BIN" \
  "$ROOT/macapp/Models.swift" \
  "$ROOT/macapp/ReadingSession.swift" \
  "$ROOT/macapp/ReaderTheme.swift" \
  "$ROOT/macapp/SourceViewer.swift" \
  "$ROOT/macapp/Tests/NativeChecks.swift"
"$BIN" "$WORK/a"
