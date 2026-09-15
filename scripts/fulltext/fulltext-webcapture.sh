#!/usr/bin/env bash
# Capture web-article source-summaries (news / gov / org pages that have no PDF)
# as text snapshots. For every source-summary whose source: classifies as `web`
# and has no fulltext:, fetch the page, extract the readable article text, and
# store it as <slug>.txt in Drive with fulltext_access: web. This preserves the
# article against link-rot; the wiki page stays the curated summary. Papers are
# handled by fulltext-add/-backfill instead — this only touches `web` pages.
#
# Usage:
#   fulltext-webcapture.sh [--dry-run] [--limit N] [<slug>]
#     --dry-run   list the web pages that would be captured; fetch nothing
#     --limit N   process at most N pages
#     <slug>      capture just this one page
set -uo pipefail
FT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$FT_DIR/lib.sh"
UA='Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16 Safari/605.1.15'

dry=0; limit=0; only=""
while [ $# -gt 0 ]; do case "$1" in
  --dry-run) dry=1; shift;;
  --limit) limit="$2"; shift 2;;
  -h|--help) grep -E '^#( |$)' "$0" | sed 's/^# \?//'; exit 0;;
  -*) die "unknown option: $1";;
  *) only="$1"; shift;;
esac; done
load_env; preflight

extract_text() {  # $1 = html file -> clean readable text on stdout
  python3 - "$1" <<'PY'
import sys, re, html
h = open(sys.argv[1], encoding='utf-8', errors='ignore').read()
mt = re.search(r'<title[^>]*>(.*?)</title>', h, re.S | re.I)
title = html.unescape(re.sub('<.*?>', '', mt.group(1)).strip()) if mt else ''
h = re.sub(r'<(script|style|nav|footer|header)[^>]*>.*?</\1>', ' ', h, flags=re.S | re.I)
out = []
for p in re.findall(r'<p[^>]*>(.*?)</p>', h, re.S | re.I):
    t = html.unescape(re.sub('<.*?>', '', p)).strip()
    if len(t) > 50:
        out.append(t)
if title:
    print(title + "\n")
print("\n\n".join(out))
PY
}

n=0; ok=0; skip=0
echo "=== web-article capture ($([ "$dry" = 1 ] && echo DRY-RUN || echo LIVE)) ==="
echo "remote: $REMOTE_BASE"
for f in "$WIKI_DIR"/*.md; do
  grep -qE '^type: source(-summary)?[[:space:]]*$' "$f" || continue
  grep -q '^source:' "$f" || continue
  grep -q '^fulltext:' "$f" && continue
  slug="$(basename "$f" .md)"
  [ -n "$only" ] && [ "$slug" != "$only" ] && continue
  src="$(page_source_url "$f")"
  [ "$(source_kind "$src" "$(page_item_type "$f")")" = web ] || continue
  [ "$limit" -gt 0 ] && [ "$n" -ge "$limit" ] && break
  n=$((n+1))
  if [ "$dry" = 1 ]; then echo "  WEB $slug   -> $src"; continue; fi
  htmlf="$(mktemp)"; txt="$(mktemp)"
  curl -sL --max-time 40 -A "$UA" "$src" -o "$htmlf" 2>/dev/null
  extract_text "$htmlf" > "$txt" 2>/dev/null
  words="$(wc -w < "$txt" | tr -d ' ')"
  if [ "${words:-0}" -ge 120 ] && "$FT_DIR/fulltext-add.sh" "$slug" --file "$txt" --access web >/dev/null 2>&1; then
    ok=$((ok+1)); echo "  CAPTURED $slug   ($words words)"
  else
    skip=$((skip+1)); echo "  THIN     $slug   ($words words — skipped; likely paywalled/JS-rendered)"
  fi
  rm -f "$htmlf" "$txt"
done
echo "--- summary ---"
echo "captured: $ok   thin/skipped: $skip   of $n web pages"
echo "=== done ==="
