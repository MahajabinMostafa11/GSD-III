#!/usr/bin/env bash
# Acquire a paper's full text, store it in Drive as
# <Year>_<LeadAuthor>_<PMID|NoPMID>.pdf, write the fulltext_* pointer onto the
# wiki page, and record a row in the Drive manifest.
#
# Usage:
#   fulltext-add.sh <page-slug> --url <URL>     # download (open-access)
#   fulltext-add.sh <page-slug> --file <PATH>   # use a local file (e.g. a paywalled
#                                               #   PDF you fetched via your library's
#                                               #   institutional access)
# Options:
#   --access <open-access|nd-library|publisher>   provenance/license (default: inferred)
#   --doi <DOI>                                   DOI for the manifest (default: from page)
set -uo pipefail
FT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$FT_DIR/lib.sh"
UA='Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16 Safari/605.1.15'

slug=""; url=""; file=""; access=""; doi=""
while [ $# -gt 0 ]; do case "$1" in
  --url) url="$2"; shift 2;; --file) file="$2"; shift 2;;
  --access) access="$2"; shift 2;; --doi) doi="$2"; shift 2;;
  -h|--help) grep -E '^#( |$)' "$0" | sed 's/^# \?//'; exit 0;;
  -*) die "unknown option: $1";; *) slug="$1"; shift;;
esac; done
[ -n "$slug" ] || die "need a wiki page slug"
[ -n "$url$file" ] || die "need --url <URL> or --file <PATH>"
load_env; preflight
page="$(page_file "$slug")"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT; src="$tmp/in"; jar="$tmp/cookies"
if [ -n "$file" ]; then
  [ -f "$file" ] || die "file not found: $file"; cp "$file" "$src"; : "${access:=publisher}"
else
  page_doi_for_referer="$(page_doi "$page")"

  # [H5 fix, 2026-09-09] Nature-portfolio serves an HTML paywall shell with HTTP 200
  # at articles/<id>.pdf for many items, while articles/<id>_reference.pdf is the real
  # PDF. Prefer the _reference form and fall back, so a caller's natural URL still works.
  cands="$url"
  case "$url" in
    *nature.com/articles/*.pdf) cands="${url%.pdf}_reference.pdf $url";;
  esac

  got=""
  for u in $cands; do
    echo "downloading $u ..."
    # Prime cookies by visiting the DOI landing page first, and send a Referer
    # header pointing at it. Several publishers (OUP, Wiley, Springer, etc.)
    # reject a direct PDF request with no referer/cookie as a hotlink-protection
    # measure, even for a genuinely open-access article -- this is a normal
    # "click through from the article page" pattern, not a paywall bypass.
    if [ -n "$page_doi_for_referer" ]; then
      curl -sL --max-time 20 -A "$UA" -c "$jar" -b "$jar" \
        "https://doi.org/${page_doi_for_referer}" -o /dev/null 2>/dev/null
    fi
    curl -fL --retry 3 --retry-delay 2 --max-time 90 \
      -A "$UA" -H "Accept: application/pdf,*/*" \
      -e "https://doi.org/${page_doi_for_referer}" \
      -c "$jar" -b "$jar" -o "$src" "$u" 2>/dev/null || continue
    [ -s "$src" ] || continue
    got="$u"
    head -c4 "$src" | grep -q '%PDF' && break   # else try the next candidate
  done
  [ -n "$got" ] || die "download failed: $url"
  url="$got"
  case "$url" in
    *arxiv.org*|*biorxiv*|*chemrxiv*|*/pmc*|*frontiersin*) : "${access:=open-access}";;
    *) : "${access:=publisher}";;
  esac
fi
[ -s "$src" ] || die "downloaded/copied file is empty"
validate_access "$access"

ext=pdf
if [ "$access" = web ]; then ext=txt      # captured web-article text snapshot
elif head -c4 "$src" | grep -q '%PDF'; then ext=pdf
else
  # [H5 fix, 2026-09-09] REFUSE rather than store. This used to store the bytes as
  # .html and still write the fulltext_* pointer, so the page read as "full text
  # stored" while holding a paywall or login page — and the warning went to stderr,
  # where an unattended run never saw it. A failed acquisition must leave the page an
  # HONEST GAP that fulltext-status.sh still counts. (fulltext-backfill.sh already
  # guarded this on its own path; the exposed path was a direct --url call, which is
  # what the standing fetch-full-text-on-ingest rule tells every ingest agent to make.)
  if head -c64 "$src" | grep -qi '<!doctype html\|<html'; then
    die "refusing to store: content is HTML, not a PDF (paywall/login page?). Page left as a gap. For a paywalled item, fetch it via your library's institutional access and re-run with --file <path> --access nd-library."
  fi
  die "refusing to store: content is not a PDF (no %PDF magic bytes). Page left as a gap."
fi

sha="$(shasum -a 256 "$src" | awk '{print $1}')"
bytes="$(wc -c < "$src" | tr -d ' ')"

# <Year>_<LeadAuthor>_<PMID|NoPMID>.<ext> -- see build_fulltext_stem in lib.sh
# for the full PMID/author/year resolution chain (PubMed direct link -> body
# PMID mention -> DOI-to-PMID conversion -> Crossref fallback).
drive_file="$(build_fulltext_stem "$page").${ext}"
dest="${REMOTE_BASE}/${drive_file}"

echo "uploading -> $dest ($bytes bytes) ..."
"$RCLONE" copyto "$src" "$dest" || die "rclone upload failed"

# Private view URL built from the Drive file ID — does NOT make the file public.
id="$("$RCLONE" lsjson "$dest" 2>/dev/null | python3 -c 'import sys,json;a=json.load(sys.stdin);print(a[0]["ID"] if a else "")' 2>/dev/null)"
share_url=""; [ -n "$id" ] && share_url="https://drive.google.com/file/d/${id}/view"

[ -n "$doi" ] || doi="$(page_doi "$page")"
src_url="$(page_source_url "$page")"
# arXiv fallback identifier for the manifest when the page has no DOI
if [ -z "$doi" ]; then
  axid="$(printf '%s' "$src_url" | grep -oE '[0-9]{4}\.[0-9]{4,5}' | head -1)"
  [ -n "$axid" ] && case "$src_url" in *arxiv*) doi="arXiv:${axid}";; esac
fi
# whose store this pointer references (shared wiki may have several contributors)
handle="$(git -C "$WIKI_DIR" config user.name 2>/dev/null)"; [ -n "$handle" ] || handle="$(whoami)"
today="$(date +%F)"

man="$tmp/manifest.csv"; manifest_cat > "$man"
grep -v "^${slug}," "$man" > "$man.new" 2>/dev/null || true; mv "$man.new" "$man"
printf '%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
  "$slug" "$doi" "$drive_file" "$share_url" "$sha" "$bytes" "$today" "$access" "$src_url" >> "$man"
"$RCLONE" copyto "$man" "$MANIFEST_REMOTE" || die "manifest update failed"

python3 "$FT_DIR/_inject_pointer.py" "$page" \
  "fulltext=${REMOTE_BASE}/${drive_file}" \
  "fulltext_url=${share_url}" \
  "fulltext_sha256=${sha}" \
  "fulltext_fetched=${today}" \
  "fulltext_access=${access}" \
  "fulltext_by=${handle}"

echo "done: $slug -> $drive_file  [$access, $bytes bytes]"
echo "  Bytes are in Drive; only the text pointer changed in git. Commit the wiki page."