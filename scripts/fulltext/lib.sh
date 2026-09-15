#!/usr/bin/env bash
# Shared helpers for the full-text store toolkit. Sourced by fulltext-*.sh.
# Text pointers live in the wiki (git); the bytes live in a shared Google Drive,
# reached via the repo-local rclone binary. Nothing binary goes in git.
#
# Drive layout (uniform across all LLM-wiki projects): one shared parent folder
# on the same Drive, with a distinct subfolder per project:
#     <RCLONE_REMOTE>:<FULLTEXT_ROOT>/<project-label>/<page-slug>.pdf
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

die() { echo "error: $*" >&2; exit 1; }

# Derive this project's Drive subfolder label from the repo directory name,
# dropping the wiki-template suffixes so the projects map to clean, distinct
# labels: AI-Sci-Disc-Memory -> AI-Sci-Disc, AI-National-Security-LLMwiki ->
# AI-National-Security, Human-AI-Team-Science -> Human-AI-Team-Science.
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
#   paper = a citable PDF artifact: DOI / arXiv / .pdf, or an academic-publisher
#           / preprint / national-academy report domain. Fetch the PDF.
#   tool  = a software tool whose reference is a code repo or docs site — the wiki
#           page is the consolidated reference, so no full text (not a gap).
#   web   = a news / government / general-org web article (no PDF) — captured as a
#           text snapshot via fulltext-webcapture.sh, NOT counted as a paper gap.
# A citable source (DOI/arXiv/.pdf) ALWAYS wins, so a tool or web page that also
# has a DOI stays a paper. The publisher/report allowlist is extensible.
source_kind() {
  local s="$1" it="${2:-}"
  # 1. citable artifact -> paper (wins even for software/news that also has a DOI)
  printf '%s' "$s" | grep -qiE '10\.[0-9]{4,9}/|arxiv|doi\.org|\.pdf' && { echo paper; return; }
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

MANIFEST_HEADER="slug,doi,drive_file,share_url,sha256,bytes,fetched,access,source_url"

# Pull the Drive manifest to stdout (header-only if it doesn't exist yet).
manifest_cat() {
  "$RCLONE" cat "$MANIFEST_REMOTE" 2>/dev/null || printf '%s\n' "$MANIFEST_HEADER"
}
