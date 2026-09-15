#!/usr/bin/env bash
# Backfill the full-text store. For every source-summary page that has a source:
# but no fulltext:, try to acquire the PDF and store it. Only *paper* pages are
# attempted; tool/docs and web-article pages are skipped (web articles get text
# snapshots via fulltext-webcapture.sh). Every candidate URL is verified to be a
# real PDF before storing, so paywall/challenge HTML is never filed.
#
# Usage:
#   fulltext-backfill.sh [--dry-run] [--limit N]
#     --dry-run   classify gap pages (auto-fetchable vs manual); download nothing
#     --limit N   process at most N gap pages (testing / incremental runs)
#
# Resolution, in order (each yields <kind> <url> <access>):
#   arXiv:<id> / arxiv.org/...  -> arxiv     https://arxiv.org/pdf/<id>     open-access
#   a source: that is a PDF     -> pdf-url   <src>                          open-access
#   DOI 10.1038/<id> (Nature)   -> nature-ip https://www.nature.com/articles/<id>.pdf  nd-library
#                                  (IP-authenticated; works on the ND network)
#   DOI via Unpaywall           -> unpaywall <best_oa url_for_pdf>          open-access
#   anything else / no PDF      -> MANUAL (paywalled or non-resolvable; ND-library queue)
set -uo pipefail
FT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$FT_DIR/lib.sh"
UA='Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16 Safari/605.1.15'

dry=0; limit=0
while [ $# -gt 0 ]; do case "$1" in
  --dry-run) dry=1; shift;;
  --limit) limit="$2"; shift 2;;
  -h|--help) grep -E '^#( |$)' "$0" | sed 's/^# \?//'; exit 0;;
  *) die "unknown option: $1";;
esac; done

load_env; preflight
UNPAYWALL_EMAIL="${UNPAYWALL_EMAIL:-mmostaf2@nd.edu}"

# Resolve a fetchable PDF URL. Echoes "<kind>\t<url>\t<access>" or nothing.
resolve_oa() {
  local src="$1" id doi oa
  case "$src" in
    *[aA]r[xX]iv:*)        id="$(printf '%s' "$src" | sed -E 's/.*[aA]r[xX]iv:[[:space:]]*//; s/[[:space:]].*//')"
                           printf 'arxiv\thttps://arxiv.org/pdf/%s\topen-access' "$id"; return;;
    *arxiv.org/abs/*|*arxiv.org/pdf/*)
                           id="$(printf '%s' "$src" | sed -E 's#.*arxiv.org/(abs|pdf)/##; s/v[0-9]+$//; s/[?#].*//')"
                           printf 'arxiv\thttps://arxiv.org/pdf/%s\topen-access' "$id"; return;;
    *.pdf|*.pdf\?*)        printf 'pdf-url\t%s\topen-access' "$src"; return;;
  esac
  doi="$(printf '%s' "$src" | grep -oE '10\.[0-9]{4,9}/[^ "]+' | head -1)"
  # Publisher article URL with no DOI in the string: resolve it from the page's
  # citation_doi meta tag (one fetch) so the routes below can be tried.
  if [ -z "$doi" ]; then
    case "$src" in
      http*) doi="$(curl -sL --max-time 20 -A "$UA" "$src" 2>/dev/null \
                    | tr '>' '\n' | grep -i citation_doi \
                    | grep -oE '10\.[0-9]{4,9}/[^ "]+' | head -1)";;
    esac
  fi
  doi="${doi%%]*}"
  [ -z "$doi" ] && return
  # Nature portfolio: institutional IP-direct PDF (works on the ND network). Try
  # before Unpaywall so we get the published version, not just a preprint.
  case "$doi" in
    10.1038/*) printf 'nature-ip\thttps://www.nature.com/articles/%s.pdf\tnd-library' "${doi#10.1038/}"; return;;
  esac
  oa="$(curl -s --max-time 25 "https://api.unpaywall.org/v2/${doi}?email=${UNPAYWALL_EMAIL}" 2>/dev/null \
        | python3 -c 'import sys,json
try:
    d=json.load(sys.stdin); loc=d.get("best_oa_location") or {}
    print(loc.get("url_for_pdf") or "")
except Exception:
    print("")' 2>/dev/null)"
  [ -n "$oa" ] && printf 'unpaywall\t%s\topen-access' "$oa"
}

auto=0; manual=0; done_n=0; fail=0; skiptool=0; skipweb=0; n=0
echo "=== full-text backfill ($([ "$dry" = 1 ] && echo DRY-RUN || echo LIVE)) ==="
echo "remote: $REMOTE_BASE"
for f in "$WIKI_DIR"/*.md; do
  grep -q '^type: source-summary' "$f" || continue
  grep -q '^source:' "$f" || continue
  grep -q '^fulltext:' "$f" && continue          # already stored
  slug="$(basename "$f" .md)"
  src="$(page_source_url "$f")"
  [ "$limit" -gt 0 ] && [ "$n" -ge "$limit" ] && break
  n=$((n+1))
  case "$(source_kind "$src" "$(page_item_type "$f")")" in
    tool) skiptool=$((skiptool+1)); echo "  SKIP[tool/docs]   $slug"; continue;;
    web)  skipweb=$((skipweb+1));   echo "  SKIP[web-article] $slug   (use fulltext-webcapture.sh)"; continue;;
  esac
  res="$(resolve_oa "$src")"
  if [ -z "$res" ]; then
    manual=$((manual+1)); echo "  MANUAL   $slug   ($src)"; continue
  fi
  kind="${res%%$'\t'*}"; rest="${res#*$'\t'}"; url="${rest%%$'\t'*}"; access="${rest##*$'\t'}"
  if [ "$dry" = 1 ]; then
    auto=$((auto+1)); echo "  AUTO[$kind/$access]  $slug   -> $url"; continue
  fi
  echo "  FETCH[$kind] $slug ..."
  tmp="$(mktemp)"; jar="$(mktemp)"
  # [H5 fix, 2026-09-09] Same Nature-portfolio trap fulltext-add.sh now handles:
  # articles/<id>.pdf returns an HTML shell with HTTP 200; <id>_reference.pdf is the
  # PDF. This path already REFUSED the HTML below (so it never wrote a false pointer),
  # but it refused as FAILED where the paper was in fact fetchable.
  cands="$url"
  case "$url" in
    *nature.com/articles/*.pdf) cands="${url%.pdf}_reference.pdf $url";;
  esac
  for u in $cands; do
    curl -sL --max-time 90 -A "$UA" -c "$jar" -b "$jar" -o "$tmp" "$u" 2>/dev/null
    [ "$(head -c5 "$tmp" 2>/dev/null)" = "%PDF-" ] && break
  done
  rm -f "$jar"
  if [ "$(head -c5 "$tmp" 2>/dev/null)" = "%PDF-" ] && [ "$(wc -c <"$tmp")" -gt 40000 ] \
     && "$FT_DIR/fulltext-add.sh" "$slug" --file "$tmp" --access "$access" >/dev/null 2>&1; then
    done_n=$((done_n+1)); echo "    stored $slug [$access]"
  else
    fail=$((fail+1)); echo "    FAILED $slug (not a PDF or store failed; url: $url)"
  fi
  rm -f "$tmp"
done
echo "--- summary ---"
if [ "$dry" = 1 ]; then echo "auto-fetchable: $auto   manual (paywalled/unresolved): $manual   skipped: tool/docs=$skiptool web=$skipweb"
else echo "stored: $done_n   failed: $fail   manual (paywalled/unresolved): $manual   skipped: tool/docs=$skiptool web=$skipweb"; fi
echo "=== done ==="
