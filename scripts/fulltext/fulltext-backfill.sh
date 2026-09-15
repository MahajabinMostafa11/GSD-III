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
# Resolution, in order (each yields <kind> <url> <access> <doi>):
#   arXiv:<id> / arxiv.org/...      -> arxiv          https://arxiv.org/pdf/<id>     open-access
#   a source: that is a PDF         -> pdf-url        <src>                          open-access
#   DOI 10.1038/<id> (Nature)       -> nature-ip       https://www.nature.com/articles/<id>.pdf  nd-library
#                                       (IP-authenticated; works on an authorized institutional network)
#   DOI via Unpaywall                -> unpaywall      <best_oa url_for_pdf>          open-access
#   DOI landing page's citation_pdf_url meta tag (last resort before MANUAL)
#                                     -> publisher-meta <scraped url>                 open-access
#   anything else / no PDF           -> MANUAL (paywalled, bot-walled, or non-resolvable)
#
# NOTE ON PMC (deliberately not attempted here, as of 2026-09):
#   PMC's human-facing article viewer now requires solving a client-side
#   proof-of-work JS challenge before serving a PDF. NCBI's older programmatic
#   OA Web Service API (oa.fcgi) was fully retired by NCBI in August 2026. A
#   PMC-only paper currently lands in MANUAL -- open its PMC page in a real
#   browser (the challenge solves itself there) and use fulltext-add.sh --file.
#
# NOTE ON BOT-CHALLENGE DETECTION: several publisher platforms require
# executing JavaScript in a real browser before serving content, even for
# genuinely open-access articles. Two known forms so far:
#   - Cloudflare (academic.oup.com, sciencedirect.com): signals via the
#     cf-mitigated: challenge RESPONSE HEADER -- not present in the body.
#   - A Fastly-style "Client Challenge" page (seen on Springer/BMC-hosted
#     content): signals via BODY text ("Client Challenge", "Enable
#     JavaScript to proceed").
# Both are checked together from a single request (headers dumped to one
# file, body to another) so neither detection is dropped in favor of the
# other. This toolkit does not attempt to solve either challenge -- it
# reports them honestly as BLOCKED rather than a generic FAILED.
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

# Detect a known anti-bot challenge from a request's response headers and/or
# body, regardless of vendor. Checks both because the signal lives in
# different places depending on the vendor (see note above).
is_bot_challenge() {
  local hdrfile="$1" bodyfile="$2"
  grep -qi '^cf-mitigated: *challenge' "$hdrfile" 2>/dev/null && return 0
  grep -qi 'Client Challenge\|Enable JavaScript to proceed\|Checking your browser' "$bodyfile" 2>/dev/null && return 0
  return 1
}

# Resolve a fetchable PDF URL. Echoes "<kind>\t<url>\t<access>\t<doi>" or nothing.
# The doi (4th field) is passed through so the download step can prime cookies
# and set a Referer against the DOI landing page -- several publishers (OUP,
# Wiley, Springer, etc.) reject a direct PDF hit with no referer/cookie even
# for genuinely open-access articles.
resolve_oa() {
  local src="$1" id doi oa
  case "$src" in
    *[aA]r[xX]iv:*)        id="$(printf '%s' "$src" | sed -E 's/.*[aA]r[xX]iv:[[:space:]]*//; s/[[:space:]].*//')"
                           printf 'arxiv\thttps://arxiv.org/pdf/%s\topen-access\t' "$id"; return;;
    *arxiv.org/abs/*|*arxiv.org/pdf/*)
                           id="$(printf '%s' "$src" | sed -E 's#.*arxiv.org/(abs|pdf)/##; s/v[0-9]+$//; s/[?#].*//')"
                           printf 'arxiv\thttps://arxiv.org/pdf/%s\topen-access\t' "$id"; return;;
    *.pdf|*.pdf\?*)        printf 'pdf-url\t%s\topen-access\t' "$src"; return;;
  esac
  doi="$(printf '%s' "$src" | grep -oE '10\.[0-9]{4,9}/[^ "]+' | head -1)"
  if [ -z "$doi" ]; then
    case "$src" in
      http*) doi="$(curl -sL --max-time 20 -A "$UA" "$src" 2>/dev/null \
                    | tr '>' '\n' | grep -i citation_doi \
                    | grep -oE '10\.[0-9]{4,9}/[^ "]+' | head -1)";;
    esac
  fi
  doi="${doi%%]*}"
  [ -z "$doi" ] && return
  case "$doi" in
    10.1038/*) printf 'nature-ip\thttps://www.nature.com/articles/%s.pdf\tnd-library\t%s' "${doi#10.1038/}" "$doi"; return;;
  esac
  oa="$(curl -s --max-time 25 "https://api.unpaywall.org/v2/${doi}?email=${UNPAYWALL_EMAIL}" 2>/dev/null \
        | python3 -c 'import sys,json
try:
    d=json.load(sys.stdin); loc=d.get("best_oa_location") or {}
    print(loc.get("url_for_pdf") or "")
except Exception:
    print("")' 2>/dev/null)"
  if [ -n "$oa" ]; then
    printf 'unpaywall\t%s\topen-access\t%s' "$oa" "$doi"; return
  fi
  local landing meta
  landing="$(curl -sL --max-time 20 -A "$UA" "https://doi.org/${doi}" 2>/dev/null)"
  meta="$(printf '%s' "$landing" | grep -oE '<meta name="citation_pdf_url" content="[^"]+"' | head -1 \
          | sed -E 's/.*content="([^"]+)".*/\1/')"
  [ -n "$meta" ] && printf 'publisher-meta\t%s\topen-access\t%s' "$meta" "$doi"
}

auto=0; manual=0; done_n=0; fail=0; skiptool=0; skipweb=0; n=0
echo "=== full-text backfill ($([ "$dry" = 1 ] && echo DRY-RUN || echo LIVE)) ==="
echo "remote: $REMOTE_BASE"
for f in "$WIKI_DIR"/*.md; do
  grep -q '^type: source-summary' "$f" || continue
  grep -q '^source:' "$f" || continue
  grep -q '^fulltext:' "$f" && continue
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
  kind="$(printf '%s' "$res" | cut -f1)"
  url="$(printf '%s' "$res" | cut -f2)"
  access="$(printf '%s' "$res" | cut -f3)"
  res_doi="$(printf '%s' "$res" | cut -f4)"
  if [ "$dry" = 1 ]; then
    auto=$((auto+1)); echo "  AUTO[$kind/$access]  $slug   -> $url"; continue
  fi
  echo "  FETCH[$kind] $slug ..."
  tmp="$(mktemp)"; jar="$(mktemp)"; hdrs="$(mktemp)"
  cands="$url"
  case "$url" in
    *nature.com/articles/*.pdf) cands="${url%.pdf}_reference.pdf $url";;
  esac
  blocked=0
  for u in $cands; do
    if [ -n "$res_doi" ]; then
      curl -sL --max-time 20 -A "$UA" -c "$jar" -b "$jar" \
        "https://doi.org/${res_doi}" -o /dev/null 2>/dev/null
    fi
    curl -sL --retry 2 --retry-delay 2 --max-time 90 \
      -A "$UA" -H "Accept: application/pdf,*/*" \
      -e "https://doi.org/${res_doi}" \
      -c "$jar" -b "$jar" -D "$hdrs" -o "$tmp" "$u" 2>/dev/null
    if [ "$(head -c5 "$tmp" 2>/dev/null)" = "%PDF-" ]; then
      break
    fi
    if is_bot_challenge "$hdrs" "$tmp"; then
      blocked=1; continue
    fi
  done
  rm -f "$jar" "$hdrs"
  if [ "$(head -c5 "$tmp" 2>/dev/null)" = "%PDF-" ] && [ "$(wc -c <"$tmp")" -gt 40000 ] \
     && "$FT_DIR/fulltext-add.sh" "$slug" --file "$tmp" --access "$access" --doi "$res_doi" >/dev/null 2>&1; then
    done_n=$((done_n+1)); echo "    stored $slug [$access]"
  elif [ "$blocked" = 1 ]; then
    manual=$((manual+1))
    echo "    BLOCKED[bot-challenge] $slug -- publisher requires a real browser; fetch via institutional access (url: $url)"
  else
    fail=$((fail+1)); echo "    FAILED $slug (not a PDF or store failed; url: $url)"
  fi
  rm -f "$tmp"
done
echo "--- summary ---"
if [ "$dry" = 1 ]; then echo "auto-fetchable: $auto   manual (paywalled/unresolved): $manual   skipped: tool/docs=$skiptool web=$skipweb"
else echo "stored: $done_n   failed: $fail   manual (paywalled/bot-walled/unresolved): $manual   skipped: tool/docs=$skiptool web=$skipweb"; fi
echo "=== done ==="