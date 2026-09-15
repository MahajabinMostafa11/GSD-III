#!/usr/bin/env bash
# Reconcile the wiki against the Drive full-text store: which source pages still
# lack a stored copy (gaps), and which manifest rows point at a missing Drive file
# (drift).
#
# Usage: fulltext-status.sh
set -uo pipefail
FT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$FT_DIR/lib.sh"
load_env; preflight

echo "=== full-text store status ==="
echo "remote: $REMOTE_BASE"

have=0; gaps=0; tooln=0; webn=0
echo "--- gaps (type: source/source-summary with a source: but no fulltext:) ---"
for f in "$WIKI_DIR"/*.md; do
  grep -qE '^type: source(-summary)?[[:space:]]*$' "$f" || continue
  grep -q '^source:' "$f" || continue
  if grep -q '^fulltext:' "$f"; then have=$((have+1)); continue; fi
  case "$(source_kind "$(page_source_url "$f")" "$(page_item_type "$f")")" in
    tool) tooln=$((tooln+1)); echo "  n/a (tool/docs):      $(basename "$f" .md)";;
    web)  webn=$((webn+1));   echo "  web-article (capture): $(basename "$f" .md)";;
    *)    gaps=$((gaps+1));   echo "  GAP (paper):          $(basename "$f" .md)";;
  esac
done
echo "stored: $have   paper-gaps: $gaps   web-articles (capture, not a paper gap): $webn   tool/docs (no full text): $tooln"

echo "--- drift (manifest row whose Drive file is missing) ---"
manifest_cat | tail -n +2 | while IFS=, read -r slug doi drive_file rest; do
  [ -z "${drive_file:-}" ] && continue
  "$RCLONE" lsf "${REMOTE_BASE}/${drive_file}" >/dev/null 2>&1 \
    || echo "  MISSING in Drive: $drive_file (slug $slug)"
done
echo "=== done ==="
