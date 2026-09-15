#!/usr/bin/env bash
# Shared helpers for the full-text store toolkit. Sourced by fulltext-*.sh.
# Text pointers live in the wiki (git); the bytes live in a shared Google Drive,
# reached via the repo-local rclone binary. Nothing binary goes in git.
#
# Drive layout (uniform across all LLM-wiki projects): one shared parent folder
# on the same Drive, with a distinct subfolder per project:
#     <RCLONE_REMOTE>:<FULLTEXT_ROOT>/<project-label>/<Year>_<LeadAuthor>_<PMID|NoPMID>.pdf
#     <RCLONE_REMOTE>:<FULLTEXT_ROOT>/<project-label>/fulltext-manifest.csv
# The project label is derived from the repo directory name (see project_label),
# so every project's fulltext.env is byte-for-byte identical.

set -uo pipefail

FT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$FT_DIR/../.." && pwd)"
RCLONE="$FT_DIR/bin/rclone"
CACHE_DIR="$REPO_ROOT/.fulltext-cache"

# Wiki sub-repo (the single wiki/<repo>.wiki/ directory).
WIKI_DIR="$(find "$REPO_ROOT/wiki" -maxdepth 1 -type d -name '*.wiki' 2>/dev/null | head -1)"

# Controlled vocabulary for fulltext_access / --access.
#   open-access | nd-library | publisher = PDF papers.
#   web = a captured web-article text snapshot (news/gov/org page, no PDF).
ACCESS_VALUES="open-access nd-library publisher web"

# NCBI E-utilities / idconv require a tool name and contact email per their
# usage policy. Used for the DOI<->PMID/PMCID lookups below.
NCBI_TOOL="gsd3-wiki"
NCBI_EMAIL="mmostaf2@nd.edu"

die() { echo "error: $*" >&2; exit 1; }

# Derive this project's Drive subfolder label from the repo directory name,
# dropping common wiki-template suffixes so projects map to clean, distinct
# labels (e.g. Some-Disease-Memory -> Some-Disease). A plain name like
# "GSD-III" with no such suffix passes through unchanged.
project_label() {
  local b; b="$(basename "$REPO_ROOT")"
  b="${b%-Memory}"; b="${b%-LLMwiki}"; b="${b%-LLMWiki}"
  printf '%s' "$b"
}

load_env() {
  local env="$FT_DIR/fulltext.env"
  [ -f "$env" ] || die "missing $env — copy fulltext.env.example to fulltext.env and edit it."
  # shellcheck disable=SC1090
  source "$env"
  : "${RCLONE_REMOTE:?set RCLONE_REMOTE in fulltext.env}"
  # DRIVE_FOLDER is normally derived (uniform config). An explicit DRIVE_FOLDER
  # in fulltext.env still wins, for back-compat or one-off relocations.
  if [ -z "${DRIVE_FOLDER:-}" ]; then
    : "${FULLTEXT_ROOT:?set FULLTEXT_ROOT in fulltext.env (or an explicit DRIVE_FOLDER)}"
    DRIVE_FOLDER="${FULLTEXT_ROOT}/${FULLTEXT_PROJECT:-$(project_label)}"
  fi
  REMOTE_BASE="${RCLONE_REMOTE}:${DRIVE_FOLDER}"
  MANIFEST_REMOTE="${REMOTE_BASE}/fulltext-manifest.csv"
}

preflight() {
  [ -x "$RCLONE" ] || die "rclone not found at $RCLONE (run the install step in scripts/fulltext/README.md)."
  [ -n "$WIKI_DIR" ] || die "no wiki/*.wiki/ directory found under $REPO_ROOT/wiki."
  "$RCLONE" listremotes 2>/dev/null | grep -qx "${RCLONE_REMOTE}:" \
    || die "rclone remote '${RCLONE_REMOTE}:' not configured. Run: $RCLONE config   (see README)."
}

# Reject an --access value that is not in the controlled vocabulary.
validate_access() {
  local a="$1" v
  for v in $ACCESS_VALUES; do [ "$a" = "$v" ] && return 0; done
  die "invalid --access '$a' (allowed: ${ACCESS_VALUES// /, })"
}

# The item_type: value on a page (may be empty; only the applied-tool pages set it).
page_item_type() {
  grep -m1 '^item_type:' "$1" 2>/dev/null | sed -E 's/^item_type:[[:space:]]*"?([^"]*)"?[[:space:]]*$/\1/'
}

# Classify a page for full-text purposes -> paper | tool | web.
#   paper = a citable PDF artifact: DOI / PMID / arXiv / .pdf, or an academic-
#           publisher / preprint / national-academy report domain. Fetch the PDF.
#   tool  = a software tool whose reference is a code repo or docs site — the wiki
#           page is the consolidated reference, so no full text (not a gap).
#   web   = a news / government / general-org web article (no PDF) — captured as a
#           text snapshot via fulltext-webcapture.sh, NOT counted as a paper gap.
# A citable source (DOI/PMID/arXiv/.pdf) ALWAYS wins, so a tool or web page that
# also has a DOI stays a paper. The publisher/report allowlist is extensible.
source_kind() {
  local s="$1" it="${2:-}"
  # 1. citable artifact -> paper (wins even for software/news that also has a DOI)
  printf '%s' "$s" | grep -qiE '10\.[0-9]{4,9}/|arxiv|doi\.org|\.pdf|pubmed\.ncbi\.nlm\.nih\.gov' && { echo paper; return; }
  # 2. academic publisher / preprint server / national-academy report body -> paper
  printf '%s' "$s" | grep -qiE 'nature\.com|sciencedirect|/pii|springer|wiley|onlinelibrary|ieeexplore|pubs\.acs\.org|pubs\.rsc\.org|academic\.oup|sagepub|tandfonline|mdpi\.com|frontiersin|pnas\.org|science\.org|cell\.com|aiaa\.org|asmedigitalcollection|biorxiv|medrxiv|chemrxiv|aclanthology|openreview|jmlr|iopscience|ncbi\.nlm\.nih\.gov|nationalacademies|nap\.edu|leopoldina|cca-reports|royalsociety' && { echo paper; return; }
  # 3. code repo / package registry / docs site, or software item_type at a bare homepage -> tool
  printf '%s' "$s" | grep -qiE 'github\.com|gitlab\.com|bitbucket|sourceforge|readthedocs|pypi\.org|anaconda|conda-forge|/docs(/|$)' && { echo tool; return; }
  if printf '%s' "$it" | grep -qiwE 'framework|library|tool|toolkit|simulator|platform|package' \
     && printf '%s' "$s" | grep -qiE '^https?://'; then echo tool; return; fi
  # 4. any other bare website (news / gov / general org) -> web article
  printf '%s' "$s" | grep -qiE '^https?://' && { echo web; return; }
  # 5. fallback
  echo paper
}

# Map a wiki page slug -> its markdown file; verify it exists.
page_file() {
  local slug="$1" f="$WIKI_DIR/$1.md"
  [ -f "$f" ] || die "no wiki page '$slug' (expected $f)."
  printf '%s' "$f"
}

# The source: URL recorded on a page (used as default provenance).
page_source_url() {
  grep -m1 '^source:' "$1" 2>/dev/null | sed -E 's/^source:[[:space:]]*"?([^"]*)"?[[:space:]]*$/\1/'
}

# ----------------------------------------------------------------------------
# PMID / author / year resolution, shared by fulltext-add.sh and (indirectly)
# fulltext-backfill.sh. A page's source: is most often a DOI, not a PubMed
# link, so PMID resolution tries several places before giving up:
#   1. A pubmed.ncbi.nlm.nih.gov/<id> link in source: (fastest, no lookup).
#   2. A "PMID: <id>" / "PMID <id>" mention anywhere in the page body.
#   3. If a DOI is present instead, ask NCBI's ID Converter API to map DOI -> PMID.
# ----------------------------------------------------------------------------

# Extract a DOI from a page (source: field, or a bare DOI anywhere in the file).
page_doi() {
  local page="$1" doi
  doi="$(page_source_url "$page" | grep -oE '10\.[0-9]{4,9}/[^ "]+' | head -1)"
  [ -z "$doi" ] && doi="$(grep -m1 -oE '10\.[0-9]{4,9}/[^"() ]+' "$page" | head -1)"
  printf '%s' "$doi"
}

# Resolve a PMID for a page: check source: for a PubMed link, then the body
# text for a "PMID: ..." mention, then fall back to converting a DOI via
# NCBI's ID Converter API. Prints the PMID or nothing.
#
# NOTE: idconv requires tool= and email= parameters per NCBI's usage policy
# (calls without them return an HTTP 400) -- see NCBI_TOOL/NCBI_EMAIL above.
resolve_pmid() {
  local page="$1" doi="${2:-}" pmid
  pmid="$(page_source_url "$page" | grep -oE 'pubmed\.ncbi\.nlm\.nih\.gov/([0-9]+)' | grep -oE '[0-9]+$')"
  if [ -z "$pmid" ]; then
    pmid="$(grep -m1 -oE 'PMID:?[[:space:]]*\[?([0-9]{4,9})' "$page" | grep -oE '[0-9]{4,9}$')"
  fi
  if [ -z "$pmid" ] && [ -n "$doi" ]; then
    pmid="$(curl -sL --max-time 15 \
      "https://www.ncbi.nlm.nih.gov/pmc/utils/idconv/v1.0/?tool=${NCBI_TOOL}&email=${NCBI_EMAIL}&ids=${doi}&format=json" 2>/dev/null \
      | python3 -c 'import sys, json
try:
    d = json.load(sys.stdin)
    recs = d.get("records", [])
    print(recs[0].get("pmid", "") if recs else "")
except Exception:
    print("")' 2>/dev/null)"
  fi
  printf '%s' "$pmid"
}

# Given a PMID, fetch its full lead-author name (not just an initial) and
# publication year directly from PubMed via EFetch (XML). PubMed's ESummary
# API truncates given names to a single initial, so EFetch is used instead.
# Prints "GivenName Surname|Year" (either half may be empty on a miss).
pubmed_author_year() {
  local pmid="$1" xml last_name fore_name year
  [ -z "$pmid" ] && { printf '|'; return; }
  xml="$(curl -sL --max-time 15 \
    "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi?db=pubmed&id=${pmid}&retmode=xml&tool=${NCBI_TOOL}&email=${NCBI_EMAIL}" 2>/dev/null)"
  [ -z "$xml" ] && { printf '|'; return; }
  last_name="$(printf '%s' "$xml" | grep -oE '<LastName>[^<]+' | head -1 | sed 's/<LastName>//')"
  fore_name="$(printf '%s' "$xml" | grep -oE '<ForeName>[^<]+' | head -1 | sed 's/<ForeName>//')"
  year="$(printf '%s' "$xml" | grep -oE '<Year>[0-9]{4}' | head -1 | sed 's/<Year>//')"
  printf '%s %s|%s' "$fore_name" "$last_name" "$year" | sed 's/^ *//'
}

# Given a DOI, fetch lead-author name and year from Crossref's public API
# (no key required). Used only when PubMed resolution didn't work. Prints
# "GivenName Surname|Year".
crossref_author_year() {
  local doi="$1" cr
  [ -z "$doi" ] && { printf '|'; return; }
  cr="$(curl -s --max-time 15 "https://api.crossref.org/works/${doi}" 2>/dev/null)"
  [ -z "$cr" ] && { printf '|'; return; }
  printf '%s' "$cr" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin).get("message", {})
    authors = d.get("author") or []
    given = authors[0].get("given", "") if authors else ""
    family = authors[0].get("family", "") if authors else ""
    name = f"{given} {family}".strip()
    year = ""
    for key in ("published-print", "published-online", "issued"):
        parts = d.get(key, {}).get("date-parts")
        if parts and parts[0]:
            year = str(parts[0][0])
            break
    print(f"{name}|{year}")
except Exception:
    print("|")
' 2>/dev/null
}

# Build the "<Year>_<LeadAuthor>_<PMID|NoPMID>" filename stem (without
# extension) for a wiki page. Tries PubMed first (via resolve_pmid, which
# itself tries a direct PubMed link, then a body PMID mention, then DOI->PMID
# conversion), falls back to Crossref via DOI if PubMed didn't yield a full
# author/year, falls back to "UnknownYear_Unknown" if neither resolves.
# Never fails/blocks the caller — always prints something usable.
build_fulltext_stem() {
  local page="$1" doi pmid author year parsed

  doi="$(page_doi "$page")"
  pmid="$(resolve_pmid "$page" "$doi")"

  author=""; year=""
  if [ -n "$pmid" ]; then
    parsed="$(pubmed_author_year "$pmid")"
    author="${parsed%%|*}"; year="${parsed##*|}"
  fi
  if [ -z "$author" ] || [ -z "$year" ]; then
    parsed="$(crossref_author_year "$doi")"
    [ -z "$author" ] && author="${parsed%%|*}"
    [ -z "$year" ] && year="${parsed##*|}"
  fi

  [ -z "$year" ] && year="UnknownYear"
  [ -z "$author" ] && author="Unknown"
  author="$(printf '%s' "$author" | sed 's/[^A-Za-z0-9 -]//g' | sed 's/^ *//;s/ *$//')"
  [ -z "$author" ] && author="Unknown"

  printf '%s_%s_%s' "$year" "$author" "${pmid:-NoPMID}"
}

MANIFEST_HEADER="slug,doi,drive_file,share_url,sha256,bytes,fetched,access,source_url"

# Pull the Drive manifest to stdout (header-only if it doesn't exist yet).
manifest_cat() {
  "$RCLONE" cat "$MANIFEST_REMOTE" 2>/dev/null || printf '%s\n' "$MANIFEST_HEADER"
}