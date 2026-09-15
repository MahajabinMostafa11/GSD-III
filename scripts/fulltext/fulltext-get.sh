#!/usr/bin/env bash
# Fetch a stored paper from Drive into the local gitignored cache so it can be
# read; extract text if it is a PDF.
#
# Usage: fulltext-get.sh <page-slug>
set -uo pipefail
FT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$FT_DIR/lib.sh"
slug="${1:-}"; [ -n "$slug" ] || die "usage: fulltext-get.sh <page-slug>"
load_env; preflight
mkdir -p "$CACHE_DIR"

row="$(manifest_cat | grep -m1 "^${slug},")" || true
[ -n "$row" ] || die "no manifest entry for '$slug' — add it first with fulltext-add.sh"
drive_file="$(printf '%s' "$row" | awk -F, '{print $3}')"
out="$CACHE_DIR/$drive_file"

echo "downloading ${REMOTE_BASE}/${drive_file} -> $out"
"$RCLONE" copyto "${REMOTE_BASE}/${drive_file}" "$out" || die "download failed"
echo "cached: $out"

if [ "${drive_file##*.}" = "pdf" ]; then
  txt="${out%.pdf}.txt"
  if "$REPO_ROOT/.venv/bin/python" - "$out" "$txt" <<'PY'
import sys
try:
    from pypdf import PdfReader
except ImportError:
    sys.exit(3)
r = PdfReader(sys.argv[1])
open(sys.argv[2], "w").write("\n".join((p.extract_text() or "") for p in r.pages))
print(f"text extracted: {sys.argv[2]} ({len(r.pages)} pages)")
PY
  then :; else echo "(for text extraction: $REPO_ROOT/.venv/bin/pip install pypdf)"; fi
fi
