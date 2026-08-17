#!/usr/bin/env bash
# adopt.sh — additive overlay of llm-wiki-memory-template into an existing
# repository.
#
# Default mode is dry-run: classify the ADD allowlist against the target
# repo (ADD / SKIP / REFUSE) and print a report. With --apply it mutates
# the target: copies every ADD entry (never overwrites), applies the
# host-owned TOUCH grant (.claude/settings.json merge) from
# .llm-wiki-adopt-grants.yml or the built-in
# defaults, runs wiki/init-wiki.sh to bootstrap the wiki sub-repo, runs the
# chosen overlay's wiki/agents/<agent>/setup.sh, optionally wires the GitHub
# Wiki backend (--github-wiki), and appends a manifest of what changed to
# .llm-wiki-adopt-log.md. Guards against re-adoption, routing an already-
# adopted host to update-from-template.sh instead.
#
# Known limitation: --features is parsed but features are not installed yet.
#
# Design:
#   https://github.com/crcresearch/llm-wiki-memory-template/wiki/Adopt-Existing-Repo-Design
# Issue:
#   https://github.com/crcresearch/llm-wiki-memory-template/issues/6

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_ROOT="$(cd "$HERE/.." && pwd)"

# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh"
# shellcheck source=lib/template-manifest.sh
source "$HERE/lib/template-manifest.sh"

# --- ADD allowlist + KNOWN_GRANTS -------------------------------------------
# Both vocabularies live in scripts/lib/template-manifest.sh. The ADD set
# is assembled by lw_manifest_assemble_active_files in agent mode (the
# --agent flag drives overlay inclusion). The known-grant lookup
# (lw_manifest_known_grant_type) is the single source of truth for what
# operations the template performs on host-owned files. To add a synced
# path or a new host-owned grant, edit the manifest and nothing else.

# --- parse_grants_file ------------------------------------------------------
# Minimal YAML reader for the .llm-wiki-adopt-grants.yml host file. Accepts
# only the flat 'grants:' dictionary; anything else is ignored. Each emitted
# line has the form '<path>|<type>'. Comments (#) and blank lines are
# stripped. Robust against trailing whitespace; not robust against quoted
# keys, multi-line values, or nested structures (deliberately out of scope:
# the grants file is meant to be tiny and hand-authored).
parse_grants_file() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    awk '
        # toggle in_grants only on top-level "grants:" key, not on nested ones
        /^grants:[[:space:]]*$/ { in_grants = 1; next }
        # any other top-level key (line starting with non-space, non-#) closes the section
        /^[^[:space:]#]/ { in_grants = 0; next }
        # within grants, look for "  key: value" lines
        in_grants && /^[[:space:]]+[^[:space:]#]/ {
            sub(/^[[:space:]]+/, "")
            sub(/[[:space:]]*#.*$/, "")
            sub(/[[:space:]]+$/, "")
            if (length($0) == 0) next
            # split on the first ":"
            colon = index($0, ":")
            if (colon == 0) next
            key = substr($0, 1, colon - 1)
            val = substr($0, colon + 1)
            # trim both
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
            if (length(key) == 0 || length(val) == 0) next
            printf "%s|%s\n", key, val
        }
    ' "$file"
}

# --- GitHub Wiki helpers ----------------------------------------------------
# Used by --github-wiki dispatch in Phase 2B. Extract the host from any
# origin URL form (HTTPS, SSH, with/without .git, with/without user@) so
# the caller can soft-skip non-GitHub hosts BEFORE invoking lw_wiki_url
# (which dies loud on non-GitHub via lw_die). Returns the host on stdout;
# returns rc!=0 only if the URL is empty.
_lw_host_from_url() {
    local url="$1" rest host
    [[ -z "$url" ]] && return 1
    rest="$url"
    case "$rest" in
        *://*) rest="${rest#*://}"; rest="${rest#*@}" ;;
        *@*:*) rest="${rest#*@}" ;;
    esac
    host="${rest%%[:/]*}"
    printf '%s\n' "$host"
}

# Print the GitHub Wiki 404 fallback instructions on stderr. Mirrors the
# message instantiate.sh prints, but parameterised so the re-run hint
# matches the adopt.sh invocation the user actually issued. Called only
# from the failure path of the seed-push subshell.
_github_wiki_fallback_message() {
    local wiki_ui_url="$1" target_arg="$2"
    {
        echo ""
        echo "Wiki bootstrap via direct push failed."
        echo "This is the most common outcome on the first --github-wiki"
        echo "run for a project: GitHub requires the first Wiki page to be"
        echo "created through the UI before <repo>.wiki.git becomes a"
        echo "clonable/pushable repository. Until then, push returns 404."
        echo ""
        echo "Workaround:"
        echo "  1. Open $wiki_ui_url in a browser."
        echo "  2. Click \"Create the first page\", title \"Home\", any content, save."
        echo "  3. Re-run: bash scripts/adopt.sh --target=$target_arg --apply --github-wiki"
        echo ""
        echo "Or, to skip GitHub Wiki entirely and use a local-only wiki, omit --github-wiki."
        echo ""
    } >&2
}

# --- Argument parsing -------------------------------------------------------
APPLY=0          # default: dry-run; --apply opts in to mutating the host
FORCE=0          # opt-out of the "already adopted -> abort" advisory
TARGET=""
AGENT="claude-code"
FEATURES=""
GITHUB_WIKI=0    # opt-in to the GitHub Wiki bootstrap dance (Phase 2B sub-step)

usage() {
    cat <<'EOF'
Usage: adopt.sh [--target=PATH] [--apply] [--agent=NAME] [--features=LIST]
                [--github-wiki] [--help]

Classifies the ADD allowlist against a target repo. With --apply, also
copies every ADD entry into the target (never overwrites; REFUSE entries
are left alone) and writes .llm-wiki-adopt-log.md with the manifest of
what was created. Default is dry-run.

TOUCH grants: by default adopt applies the one standard grant
(.claude/settings.json merge) -- the integration touchpoint the
wiki-memory pattern needs to function as designed (SessionStart hook
registration). To customise, commit a .llm-wiki-adopt-grants.yml
at the host repo root before --apply; it overrides the defaults entirely
(an empty 'grants:' map opts out of all touches).

Options:
  --target=PATH      Repo to adopt into (default: current directory)
  --apply            Actually create ADD entries in the target. Refused
                     if the target's working tree has uncommitted changes,
                     OR if the target already shows the adoption pattern
                     (use scripts/update-from-template.sh for that case).
  --force            Bypass the 'already adopted' advisory abort. Useful
                     only for the rare case where you really do want adopt
                     mode against a host that already has the pattern.
  --agent=NAME       claude-code | none | cursor (cursor: not yet supported)
  --features=LIST    Comma-separated feature names (parsed but not installed)
  --github-wiki      Bootstrap the host's GitHub Wiki backend before init-wiki
                     runs: enable Wikis on the project repo via gh api (best
                     effort) and push a seed Home.md so <repo>.wiki.git
                     materializes. init-wiki then clones it. On the GitHub
                     architecture quirk (first wiki page must exist via the
                     UI), seed-push returns 404; adopt logs github-wiki:
                     failed, prints the workaround on stderr, and falls back
                     to a local-only wiki. Re-run --github-wiki after the
                     manual UI step to complete the migration. Non-GitHub
                     origins (or no origin) are soft-skipped.
  --dry-run          Default; included for forward compatibility
  --help, -h         Show this help

See the design at
https://github.com/crcresearch/llm-wiki-memory-template/wiki/Adopt-Existing-Repo-Design
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)            usage; exit 0 ;;
        --apply)              APPLY=1; shift ;;
        --dry-run)            APPLY=0; shift ;;
        --force)              FORCE=1; shift ;;
        --target=*)           TARGET="${1#*=}"; shift ;;
        --target)             TARGET="${2:-}"; shift 2 ;;
        --agent=*)            AGENT="${1#*=}"; shift ;;
        --agent)              AGENT="${2:-}"; shift 2 ;;
        --features=*)         FEATURES="${1#*=}"; shift ;;
        --features)           FEATURES="${2:-}"; shift 2 ;;
        --github-wiki)        GITHUB_WIKI=1; shift ;;
        *)                    lw_die "unknown argument: $1" ;;
    esac
done

# --- Validate target --------------------------------------------------------
if [[ -z "$TARGET" ]]; then
    TARGET="$PWD"
fi

if [[ ! -d "$TARGET" ]]; then
    lw_die "target does not exist or is not a directory: $TARGET"
fi

TARGET="$(cd "$TARGET" && pwd)"

if [[ ! -d "$TARGET/.git" ]]; then
    lw_die "target is not a git repository (no .git/): $TARGET"
fi

if [[ "$TARGET" == "$TEMPLATE_ROOT" ]]; then
    lw_die "target is the template itself; adopt.sh is for OTHER repos"
fi

# --- Validate agent ---------------------------------------------------------
case "$AGENT" in
    claude-code|none) ;;
    cursor)
        lw_die "agent 'cursor' is not yet supported (see issue #6, deferred)"
        ;;
    *)
        lw_die "unknown agent '$AGENT' (expected: claude-code, none, cursor)"
        ;;
esac

# --- Resolve identity -------------------------------------------------------
PROJECT_NAME="$(lw_name_from_origin "$TARGET")"

# --- Detect 'already adopted' via composite signals -------------------------
# No single marker is decisive. The template-log file is only written by
# update-from-template.sh's first run; the wiki sub-repo lives in a separate
# remote and may not be cloned alongside the parent; any single file present
# could be coincidence. Combining independent signals — each one specific to
# the pattern in a different way — reduces both false positives (a single
# coincidental match) and false negatives (a single marker missing locally).
#
# Signals checked, all harness-agnostic (they come from the pattern itself,
# not from any specific agent overlay):
#   A: llm-wiki.md byte-identical to template
#      (strong: file unique to the pattern; byte-equal -> came from template)
#   B: wiki/agents/discipline-gates.md byte-identical to template
#      (strong: shared overlay-agnostic file from TEMPLATE_SHARED_INFRA; present
#       regardless of which overlay the host chose, including --agent=none)
#   C: wiki/init-wiki.sh present in target
#      (moderate: specific file from the pattern; may be host-modified)
#
# Threshold: at least 2 of 3 signals must match. A single signal can be
# coincidence; two independent signals from different parts of the pattern
# make the inference reliable.
#
# Which overlay the host happens to be running (claude-code, cursor, etc.)
# is reported separately as metadata, not as a detection signal — see the
# DETECTED_OVERLAYS block below.
ADOPTION_SIGNALS=()

if [[ -f "$TARGET/llm-wiki.md" ]] \
    && cmp -s "$TEMPLATE_ROOT/llm-wiki.md" "$TARGET/llm-wiki.md"; then
    ADOPTION_SIGNALS+=("llm-wiki.md byte-identical to template")
fi
if [[ -f "$TARGET/wiki/agents/discipline-gates.md" ]] \
    && cmp -s "$TEMPLATE_ROOT/wiki/agents/discipline-gates.md" \
              "$TARGET/wiki/agents/discipline-gates.md"; then
    ADOPTION_SIGNALS+=("wiki/agents/discipline-gates.md byte-identical to template")
fi
if [[ -e "$TARGET/wiki/init-wiki.sh" ]]; then
    ADOPTION_SIGNALS+=("wiki/init-wiki.sh present")
fi

ADOPTION_THRESHOLD=2
ADOPTION_COUNT=${#ADOPTION_SIGNALS[@]}

# --- Detect which overlay (if any) is present (metadata, not a signal) ------
# Catalog approach mirroring how vulnerability scanners detect package
# managers: each overlay leaves a canonical mark in a canonical path.
# Presence here is informational; the adoption decision above does not
# depend on which overlay is configured.
DETECTED_OVERLAYS=()
if [[ -d "$TARGET/.claude" ]] || [[ -f "$TARGET/wiki/agents/claude-code/setup.sh" ]]; then
    DETECTED_OVERLAYS+=("claude-code")
fi
if [[ -d "$TARGET/.cursor" ]] || [[ -f "$TARGET/wiki/agents/cursor/setup.sh" ]]; then
    DETECTED_OVERLAYS+=("cursor")
fi

# --- Classify each path -----------------------------------------------------
# Assemble the active set from the shared manifest in agent mode (empty
# repo_root, AGENT drives overlay inclusion). For each path:
#   not present in target  -> ADD
#   present + identical    -> SKIP
#   present + different    -> REFUSE
ACT_ADD=()
ACT_SKIP=()
ACT_REFUSE=()
ADD_PATHS=()
while IFS= read -r _path; do
    ADD_PATHS+=("$_path")
done < <(lw_manifest_assemble_active_files "" "$AGENT")
# Sync-tree members (TEMPLATE_SYNC_TREES, e.g. the test harness) resolved
# from the template checkout on disk — dir mode, since adopt copies from
# $TEMPLATE_ROOT rather than a git ref (#90).
while IFS= read -r _path; do
    ADD_PATHS+=("$_path")
done < <(lw_manifest_tree_files dir "$TEMPLATE_ROOT")
for path in "${ADD_PATHS[@]}"; do
    src="$TEMPLATE_ROOT/$path"
    dst="$TARGET/$path"
    if [[ ! -e "$src" ]]; then
        # Manifest drift from the actual template; report so we don't
        # silently produce a misleading ADD line.
        ACT_REFUSE+=("$path  (missing in template: $src)")
        continue
    fi
    if [[ ! -e "$dst" ]]; then
        ACT_ADD+=("$path")
    elif cmp -s "$src" "$dst"; then
        ACT_SKIP+=("$path")
    else
        ACT_REFUSE+=("$path  (host-modified)")
    fi
done

# --- Classify TOUCH grants --------------------------------------------------
# Reads $TARGET/.llm-wiki-adopt-grants.yml. For each entry:
#   target unknown to template     -> TOUCH_INVALID (refuse the grant)
#   type mismatches template's op  -> TOUCH_INVALID (refuse with reason)
#   otherwise                      -> TOUCH
#
# Absent targets are NOT rejected. TOUCH grants govern HOW adopt may
# safely modify a host file, not WHETHER adopt may create one. When
# the target is absent the host has no content to preserve, so the
# overlay's seed is installed (for .claude/settings.json, setup.sh --hook
# creates it from canonical). Reported as design inconsistency by Chris
# Sweet on PR #51 (items 3, 4, 5).
#
# When the host did not author a .llm-wiki-adopt-grants.yml, adopt uses
# the manifest's TEMPLATE_HOST_OWNED list as the default grant set: the
# one standard grant that every wiki-memory adopter has historically
# wanted (.claude/settings.json merge). Without this default the
# adoption is partial: the SessionStart hook is never registered, so
# claude-code does not auto-pull the wiki at session start. The host can
# override by committing an explicit .llm-wiki-adopt-grants.yml --
# including an empty 'grants:' map to opt out of all touches.
GRANTS_FILE="$TARGET/.llm-wiki-adopt-grants.yml"
ACT_TOUCH=()           # "path|type|was_absent"
ACT_TOUCH_INVALID=()   # "path  (reason)"
N_GRANTS=0
GRANTS_SOURCE="defaults"   # "defaults" or "file"

if [[ -f "$GRANTS_FILE" ]]; then
    GRANTS_SOURCE="file"
    while IFS='|' read -r g_path g_type; do
        [[ -z "$g_path" ]] && continue
        N_GRANTS=$((N_GRANTS + 1))
        expected="$(lw_manifest_known_grant_type "$g_path")"
        if [[ -z "$expected" ]]; then
            ACT_TOUCH_INVALID+=("$g_path  (unknown grant target; template has no operation for it)")
            continue
        fi
        if [[ "$g_type" != "$expected" ]]; then
            ACT_TOUCH_INVALID+=("$g_path  (type mismatch: grant says '$g_type', template knows '$expected')")
            continue
        fi
        if [[ -e "$TARGET/$g_path" ]]; then
            was_absent=0
        else
            was_absent=1
        fi
        ACT_TOUCH+=("$g_path|$g_type|$was_absent")
    done < <(parse_grants_file "$GRANTS_FILE")
else
    # No grants file: classify TEMPLATE_HOST_OWNED entries as TOUCH. Same
    # classification path as the file branch; the manifest is the single
    # source of truth for the vocabulary.
    for entry in "${TEMPLATE_HOST_OWNED[@]}"; do
        g_path="${entry%%|*}"
        g_type="${entry#*|}"
        N_GRANTS=$((N_GRANTS + 1))
        if [[ -e "$TARGET/$g_path" ]]; then
            was_absent=0
        else
            was_absent=1
        fi
        ACT_TOUCH+=("$g_path|$g_type|$was_absent")
    done
fi

# --- Print report -----------------------------------------------------------
if [[ "$GRANTS_SOURCE" == "file" ]]; then
    grants_status="$(basename "$GRANTS_FILE") ($N_GRANTS grant(s) found)"
else
    grants_status="defaults ($N_GRANTS standard grants; no .llm-wiki-adopt-grants.yml found; commit one to override)"
fi

if [[ "$APPLY" -eq 1 ]]; then
    MODE_BANNER="adopt.sh --apply"
else
    MODE_BANNER="adopt.sh --dry-run"
fi

cat <<EOF
$MODE_BANNER

Target:           $TARGET
Resolved:         $PROJECT_NAME   (lw_name_from_origin)
Template:         $TEMPLATE_ROOT
Agent overlay:    $AGENT
Features:         ${FEATURES:-<none>}
Grants file:      $grants_status
EOF

if [[ "$ADOPTION_COUNT" -ge "$ADOPTION_THRESHOLD" ]]; then
    echo "Status:           already adopted ($ADOPTION_COUNT of 3 indicators matched)"
    for sig in "${ADOPTION_SIGNALS[@]}"; do
        echo "                  - $sig"
    done
    # Overlay metadata (catalog-style detection; separate from the
    # adopted/not-adopted decision above).
    if [[ ${#DETECTED_OVERLAYS[@]} -eq 0 ]]; then
        echo "                  Overlay(s) detected: none"
    else
        overlay_list="$(IFS=','; printf '%s' "${DETECTED_OVERLAYS[*]}")"
        echo "                  Overlay(s) detected: ${overlay_list//,/, }"
    fi
    # Advice: route to update-from-template AND surface the semantic gotcha.
    # Future refactor will reword 'sync list' to 'TEMPLATE_SHARED_INFRA'
    # once scripts/lib/template-manifest.sh exists; everything else stays.
    cat <<'EOF'
                  for incremental sync of template-owned files, see scripts/update-from-template.sh
                  note: that script OVERWRITES files in its sync list. The REFUSE entries
                  below mark places where overwriting would discard local changes — review
                  before using update-from-template.sh on them.
EOF
fi
echo ""

echo "ADD  (would create ${#ACT_ADD[@]} files)"
if [[ ${#ACT_ADD[@]} -eq 0 ]]; then
    echo "  (none)"
else
    for p in "${ACT_ADD[@]}"; do echo "  + $p"; done
fi
echo ""

echo "SKIP (already present, identical to template — ${#ACT_SKIP[@]} files)"
if [[ ${#ACT_SKIP[@]} -eq 0 ]]; then
    echo "  (none)"
else
    for p in "${ACT_SKIP[@]}"; do echo "  = $p"; done
fi
echo ""

echo "REFUSE (host has a different version — ${#ACT_REFUSE[@]} files)"
if [[ ${#ACT_REFUSE[@]} -eq 0 ]]; then
    echo "  (none)"
else
    for p in "${ACT_REFUSE[@]}"; do echo "  ✗ $p"; done
fi
echo ""

echo "TOUCH (host-owned, granted — ${#ACT_TOUCH[@]} files)"
if [[ ${#ACT_TOUCH[@]} -eq 0 ]]; then
    echo "  (none)"
else
    for entry in "${ACT_TOUCH[@]}"; do
        # entry = "path|type|was_absent"
        t_path="${entry%%|*}"
        rest="${entry#*|}"
        t_type="${rest%%|*}"
        t_was_absent="${rest#*|}"
        marker=""
        if [[ "$t_was_absent" == "1" ]]; then
            marker=" [absent; will create from canonical]"
        fi
        printf "  ~ %-32s %s%s\n" "$t_path" "$t_type" "$marker"
    done
fi
echo ""

if [[ ${#ACT_TOUCH_INVALID[@]} -gt 0 ]]; then
    echo "GRANT WARNINGS (entries in grants file that did not produce a TOUCH)"
    # Bash 3.2 (macOS default) treats "${arr[@]}" on an empty declared
    # array as an unbound variable under set -u, so the for-loop needs
    # its own ${#arr[@]} guard. Same pattern as the ACT_ADD loop below.
    for p in "${ACT_TOUCH_INVALID[@]}"; do echo "  ! $p"; done
    echo ""
fi

cat <<'EOF'
NOT IMPLEMENTED YET (planned; parsed but not wired, not absent from the design)
  - Feature install via --features (install_feature from scripts/lib/)
EOF
echo ""

# --- GitHub Wiki preview (--github-wiki, dry-run only) ----------------------
# Read-only probes: origin URL, host check, wiki URL derivation, ls-remote.
# Reports the prospective github-wiki status without mutating anything.
# Mirrors the status vocabulary the apply path uses, prefixed 'would-' to
# make the intent obvious. Skipped silently when --github-wiki is absent.
if [[ "$GITHUB_WIKI" -eq 1 ]]; then
    echo "GITHUB WIKI (--github-wiki preview; read-only)"
    _gw_origin=$(lw_origin_url "$TARGET" 2>/dev/null || true)
    if [[ -z "$_gw_origin" ]]; then
        echo "  would-skip (no origin remote on target; cannot derive wiki URL)"
    else
        _gw_host=$(_lw_host_from_url "$_gw_origin")
        case "$_gw_host" in
            *github*)
                _gw_wiki_url=$(lw_wiki_url "$_gw_origin")
                if git ls-remote "$_gw_wiki_url" >/dev/null 2>&1; then
                    echo "  would-skip (wiki already materialized at $_gw_wiki_url; would clone via init-wiki --github)"
                else
                    echo "  would-apply (seed-push to $_gw_wiki_url (master); wiki not yet materialized)"
                fi
                ;;
            *)
                echo "  would-skip (non-github host '$_gw_host')"
                ;;
        esac
    fi
    echo ""
fi

# --- Apply mode -------------------------------------------------------------
# Phase 1: ADD apply only. Refuses to touch the host if the working tree
# has uncommitted changes (so the host owner can review the resulting diff
# cleanly via `git status` / `git diff` after the run). TOUCH apply is
# deferred to Phase 2 and is currently still classification-only above.
if [[ "$APPLY" -eq 0 ]]; then
    echo "Dry-run only. No files in $TARGET were modified."
    echo "Re-run with --apply to create the ADD entries above."
    exit 0
fi

# Safety guard: refuse to write into a dirty working tree.
if [[ -n "$(git -C "$TARGET" status --porcelain 2>/dev/null)" ]]; then
    lw_die "target has uncommitted changes in its working tree; commit or stash before --apply"
fi

# --- Advisory abort: 'already adopted' hosts route to update-from-template ---
# adopt.sh is for FIRST-TIME adoption. When the composite detector finds the
# pattern already present (>= ADOPTION_THRESHOLD signals), the right tool is
# update-from-template.sh, which consumes the same template manifest and handles drift
# between template versions. Re-running adopt --apply on an adopted host
# would re-trigger Phase 1 ADD (no-op for SKIPs, REFUSE for divergences)
# and Phase 2B (which invokes host's possibly-drifted
# init-wiki.sh / overlay setup.sh, with brittle results). Cleaner to refuse
# and route. --force is the escape hatch when the user really means it.
if [[ "$ADOPTION_COUNT" -ge "$ADOPTION_THRESHOLD" && "$FORCE" -eq 0 ]]; then
    {
        echo ""
        echo "ERROR: this repo has already adopted the wiki-memory pattern."
        echo "       adopt.sh is for first-time adoption only."
        echo ""
        echo "       Detected $ADOPTION_COUNT of 3 indicators:"
        for sig in "${ADOPTION_SIGNALS[@]}"; do
            printf '         - %s\n' "$sig"
        done
        echo ""
        echo "For ongoing sync of template-owned files, use:"
        echo "       bash scripts/update-from-template.sh"
        echo ""
        echo "If you really need to force adopt mode against this repo, pass --force."
    } >&2
    exit 1
fi

# Honor the same per-path rules the dry-run reported: ADD entries get
# copied (host did not have them; no overwrite risk); SKIP entries are
# byte-equal already (no-op); REFUSE entries are left alone (host
# divergence is sacred). Tracking what was actually applied so the
# manifest reflects on-disk truth, not the dry-run intent.
APPLIED_ADDS=()
FAILED_ADDS=()
# Guard the for-loop expansion: bash 3.2 (macOS default) treats
# "${arr[@]}" on an empty declared array as an unbound variable under
# set -u, so a second --apply on a fully-adopted host (ACT_ADD empty)
# would die before reaching the manifest write. ${#arr[@]} is safe.
if [[ ${#ACT_ADD[@]} -gt 0 ]]; then
    for path in "${ACT_ADD[@]}"; do
        src="$TEMPLATE_ROOT/$path"
        dst="$TARGET/$path"
        # Capture RC instead of trusting the command unconditionally:
        # cp -p can fail (permissions, disk full, read-only mount,
        # destination path blocked by a non-directory) and without
        # set -e the script kept going and recorded the path in
        # APPLIED_ADDS regardless. The manifest would then lie about
        # disk state. mkdir -p can fail for the same reasons.
        if mkdir -p "$(dirname "$dst")" 2>/dev/null && cp -p "$src" "$dst" 2>/dev/null; then
            APPLIED_ADDS+=("$path")
        else
            FAILED_ADDS+=("$path")
        fi
    done
fi

# --- Wiki sub-repo init (Phase 2B) ------------------------------------------
# init-wiki.sh is now in the host (copied by ADD). It auto-detects create vs
# update mode based on the presence of wiki/<repo>.wiki/, so calling it is
# safe whether or not the sub-repo exists. Captures status for the manifest
# but does NOT abort adopt on failure: a host that can't init wiki still
# benefits from the ADDed files.
#
# When --github-wiki is passed, a sub-step runs BEFORE init-wiki to bootstrap
# the GitHub Wiki backend (seed-push to materialize <repo>.wiki.git), then
# init-wiki is invoked with --github so it clones the now-real wiki instead
# of init'ing locally. The sub-step has its own status pair
# (GITHUB_WIKI_STATUS / GITHUB_WIKI_DETAIL) recorded in the manifest. A
# seed-push 404 (GitHub's "first page must exist via UI" architecture quirk)
# is captured as 'failed', the workaround is printed to stderr, and adopt
# falls back to invoking init-wiki WITHOUT --github (local-only wiki). The
# user can re-run --github-wiki after the manual UI step to complete the
# migration. Non-GitHub origins (or no origin) are soft-skipped.
INIT_WIKI_STATUS="not-run"
INIT_WIKI_DETAIL=""
GITHUB_WIKI_STATUS="skipped"
GITHUB_WIKI_DETAIL="not requested"
WIKI_SUBREPO_DIR="$TARGET/wiki/$PROJECT_NAME.wiki"
if [[ -d "$WIKI_SUBREPO_DIR/.git" ]]; then
    INIT_WIKI_STATUS="already-present"
    INIT_WIKI_DETAIL="wiki/$PROJECT_NAME.wiki/ already initialised"
    if [[ "$GITHUB_WIKI" -eq 1 ]]; then
        GITHUB_WIKI_STATUS="skipped"
        GITHUB_WIKI_DETAIL="wiki sub-repo already present; no seed-push needed"
    fi
    # The ADDed wiki/*.md.template pages (e.g. Edge-Types.md.template, #75)
    # are stamped into the wiki by init-wiki, which this branch never runs
    # — and running a full update pass over a PRE-EXISTING wiki from adopt
    # would risk overwriting host content (issue #66's Home.md case). Stamp
    # only the MISSING pages instead: creates what is absent, touches
    # nothing that exists.
    if [[ -f "$TARGET/wiki/init-wiki.sh" ]]; then
        stamp_rc=0
        (cd "$TARGET" && bash wiki/init-wiki.sh --repo-name "$PROJECT_NAME" \
            --stamp-missing-templates >/dev/null 2>&1) || stamp_rc=$?
        if [[ $stamp_rc -eq 0 ]]; then
            INIT_WIKI_DETAIL="$INIT_WIKI_DETAIL; stamped missing wiki template pages"
        else
            INIT_WIKI_DETAIL="$INIT_WIKI_DETAIL; stamp-missing-templates exited $stamp_rc"
        fi
    fi
elif [[ -f "$TARGET/wiki/init-wiki.sh" ]]; then
    # init_wiki_args: assembled below; --github appended only when seed-push
    # succeeded OR the wiki was already materialized upstream. On any
    # failure path the args stay bare and init-wiki falls back to local
    # init (current behaviour, fully backward compatible).
    init_wiki_args=(--repo-name "$PROJECT_NAME")

    if [[ "$GITHUB_WIKI" -eq 1 ]]; then
        _origin=$(lw_origin_url "$TARGET" 2>/dev/null || true)
        if [[ -z "$_origin" ]]; then
            GITHUB_WIKI_STATUS="skipped"
            GITHUB_WIKI_DETAIL="no origin remote on target; cannot derive wiki URL"
        else
            _host=$(_lw_host_from_url "$_origin")
            case "$_host" in
                *github*)
                    # Inline-safe: we know it's a GitHub host, so lw_wiki_url
                    # won't trip its lw_die guard.
                    _wiki_url=$(lw_wiki_url "$_origin")
                    if git ls-remote "$_wiki_url" >/dev/null 2>&1; then
                        GITHUB_WIKI_STATUS="wiki-already-materialized"
                        GITHUB_WIKI_DETAIL="$_wiki_url responds; skipping seed push"
                        init_wiki_args+=(--github)
                    else
                        # Best-effort PATCH has_wiki=true (defensive; the
                        # default is already true on most repos). Failure is
                        # silenced because the seed push below tests the
                        # actual state we care about.
                        if command -v gh >/dev/null 2>&1; then
                            _slug=$(lw_repo_slug "$_origin")
                            gh api "repos/$_slug" -X PATCH -F has_wiki=true >/dev/null 2>&1 || true
                        fi
                        # Seed push: identical mechanics to instantiate.sh,
                        # but the failure path does NOT exit. Adopt is
                        # additive; we capture and fall back to local init.
                        # symbolic-ref + push to refs/heads/<branch> works on
                        # git >= 2.7 without --initial-branch.
                        _seed_branch="master"
                        if (
                            _tmp=$(mktemp -d) \
                            && cd "$_tmp" \
                            && git init -q \
                            && git symbolic-ref HEAD "refs/heads/$_seed_branch" \
                            && printf '# Home\n\nBootstrapped by llm-wiki-memory-template/scripts/adopt.sh.\n' > Home.md \
                            && git add Home.md \
                            && git -c user.email=adopt@llm-wiki-memory-template \
                                   -c user.name="adopt.sh" \
                                   commit -m "Initialize wiki" -q \
                            && git push -q "$_wiki_url" "$_seed_branch:$_seed_branch" \
                            && cd / \
                            && rm -rf "$_tmp"
                        ); then
                            GITHUB_WIKI_STATUS="applied"
                            GITHUB_WIKI_DETAIL="seed-push to $_wiki_url ($_seed_branch)"
                            init_wiki_args+=(--github)
                        else
                            GITHUB_WIKI_STATUS="failed"
                            GITHUB_WIKI_DETAIL="seed-push 404; GitHub UI step required (open <repo>/wiki, create Home, re-run --github-wiki)"
                            # Surface the workaround inline; the user will
                            # see this on the terminal and the manifest will
                            # carry the same diagnosis.
                            _wiki_ui_url="${_origin%.git}"
                            _wiki_ui_url="${_wiki_ui_url/git@github.com:/https://github.com/}"
                            _wiki_ui_url="${_wiki_ui_url}/wiki"
                            _github_wiki_fallback_message "$_wiki_ui_url" "$TARGET"
                            # init_wiki_args stays bare -> local fallback.
                        fi
                    fi
                    ;;
                *)
                    GITHUB_WIKI_STATUS="skipped"
                    GITHUB_WIKI_DETAIL="non-github host '$_host'"
                    # init_wiki_args stays bare -> local fallback.
                    ;;
            esac
        fi
    fi

    init_wiki_rc=0
    (cd "$TARGET" && bash wiki/init-wiki.sh "${init_wiki_args[@]}" >/dev/null 2>&1) || init_wiki_rc=$?
    if [[ $init_wiki_rc -eq 0 ]]; then
        INIT_WIKI_STATUS="applied"
        INIT_WIKI_DETAIL="ran wiki/init-wiki.sh ${init_wiki_args[*]}"
    else
        INIT_WIKI_STATUS="failed"
        INIT_WIKI_DETAIL="wiki/init-wiki.sh exited $init_wiki_rc"
    fi
else
    INIT_WIKI_STATUS="skipped"
    INIT_WIKI_DETAIL="wiki/init-wiki.sh not present in target after ADD"
    if [[ "$GITHUB_WIKI" -eq 1 ]]; then
        GITHUB_WIKI_STATUS="skipped"
        GITHUB_WIKI_DETAIL="init-wiki.sh missing; cannot seed-push without follow-on"
    fi
fi

# --- Overlay setup (Phase 2B) -----------------------------------------------
# wiki/agents/<AGENT>/setup.sh is now in the host (copied by ADD). It is
# idempotent (each of its steps is presence-guarded), so safe
# to invoke even on subsequent --apply runs. Skipped entirely when
# --agent=none.
OVERLAY_SETUP_STATUS="not-run"
OVERLAY_SETUP_DETAIL=""
if [[ "$AGENT" == "none" ]]; then
    OVERLAY_SETUP_STATUS="skipped"
    OVERLAY_SETUP_DETAIL="--agent=none, no overlay to set up"
else
    OVERLAY_SETUP_PATH="$TARGET/wiki/agents/$AGENT/setup.sh"
    if [[ -f "$OVERLAY_SETUP_PATH" ]]; then
        overlay_rc=0
        (cd "$TARGET" && bash "$OVERLAY_SETUP_PATH" >/dev/null 2>&1) || overlay_rc=$?
        if [[ $overlay_rc -eq 0 ]]; then
            OVERLAY_SETUP_STATUS="applied"
            OVERLAY_SETUP_DETAIL="ran wiki/agents/$AGENT/setup.sh"
        else
            OVERLAY_SETUP_STATUS="failed"
            OVERLAY_SETUP_DETAIL="wiki/agents/$AGENT/setup.sh exited $overlay_rc"
        fi
    else
        OVERLAY_SETUP_STATUS="skipped"
        OVERLAY_SETUP_DETAIL="wiki/agents/$AGENT/setup.sh not present in target after ADD"
    fi
fi

# --- TOUCH apply (Phase 3 merge) ---------------------------------------------
# For valid TOUCH entries, dispatch by mechanism:
#   merge -> Phase 3 (jq deep-merge via overlay setup.sh --hook)
# (managed-block was retired with the CLAUDE.md grant; the behavioral
# instructions ship as .claude/rules/*.md ADD entries instead.)
#
# Each entry's status is captured for the manifest.
APPLIED_TOUCHES=()
if [[ ${#ACT_TOUCH[@]} -gt 0 ]]; then
    for entry in "${ACT_TOUCH[@]}"; do
        # entry = "path|type|was_absent"
        t_path="${entry%%|*}"
        rest="${entry#*|}"
        t_type="${rest%%|*}"
        t_was_absent="${rest#*|}"
        case "$t_type" in
            merge)
                # Mirror Phase 2B's pattern: delegate to overlay setup.sh
                # with the flag that performs the jq deep-merge for this
                # target. For claude-code's .claude/settings.json today
                # that flag is --hook, which is idempotent (the script
                # checks for the hook name before merging) AND already
                # handles the 'no settings.json yet' case (creates from
                # canonical), so an absent target lands here and gets
                # created with the SessionStart hook in one step.
                if [[ "$AGENT" == "none" ]]; then
                    APPLIED_TOUCHES+=("$t_path ($t_type): skipped (--agent=none, no overlay to merge through)")
                else
                    merge_overlay="$TARGET/wiki/agents/$AGENT/setup.sh"
                    if [[ ! -f "$merge_overlay" ]]; then
                        APPLIED_TOUCHES+=("$t_path ($t_type): skipped (wiki/agents/$AGENT/setup.sh not present)")
                    else
                        merge_rc=0
                        (cd "$TARGET" && bash "$merge_overlay" --hook >/dev/null 2>&1) || merge_rc=$?
                        if [[ $merge_rc -eq 0 ]]; then
                            if [[ "$t_was_absent" == "1" ]]; then
                                APPLIED_TOUCHES+=("$t_path ($t_type): created from canonical via wiki/agents/$AGENT/setup.sh --hook")
                            else
                                APPLIED_TOUCHES+=("$t_path ($t_type): applied via wiki/agents/$AGENT/setup.sh --hook")
                            fi
                        else
                            APPLIED_TOUCHES+=("$t_path ($t_type): failed (setup.sh --hook exited $merge_rc)")
                        fi
                    fi
                fi
                ;;
        esac
    done
fi

# --- Write the adoption manifest --------------------------------------------
# Records what happened on disk: signals matched, overlay detected, ADD
# paths actually created, classification counts. Append-only across
# multiple --apply runs (each run is its own entry).
ADOPT_LOG="$TARGET/.llm-wiki-adopt-log.md"
TODAY=$(date +%Y-%m-%d)
overlay_for_log="${DETECTED_OVERLAYS[*]:-none}"
overlay_for_log="${overlay_for_log// /, }"
# Decide on the heading BEFORE the redirect opens the file (>> creates the
# file if absent before the inner commands run, so a check inside the block
# would always see it as existing).
FIRST_ENTRY=0
[[ -f "$ADOPT_LOG" ]] || FIRST_ENTRY=1
{
    (( FIRST_ENTRY )) && printf '# llm-wiki adopt log\n\n'
    printf '## [%s] adopt --apply (phases 1, 2B, 3)\n' "$TODAY"
    printf -- '- project: %s\n' "$PROJECT_NAME"
    printf -- '- agent: %s\n' "$AGENT"
    printf -- '- signals matched: %s of 3 (%s)\n' \
        "$ADOPTION_COUNT" "${ADOPTION_SIGNALS[*]:-none}"
    printf -- '- overlay(s) detected: %s\n' "$overlay_for_log"
    printf -- '- ADDed (%s files):\n' "${#APPLIED_ADDS[@]}"
    # Same bash 3.2 guard as the apply loop above.
    if [[ ${#APPLIED_ADDS[@]} -gt 0 ]]; then
        for p in "${APPLIED_ADDS[@]}"; do printf '  - %s\n' "$p"; done
    fi
    # FAILED_ADDS surfaces cp / mkdir -p failures that the apply loop
    # captured. Silent on the happy path (block omitted when empty);
    # explicit when something went wrong so the manifest stays honest.
    if [[ ${#FAILED_ADDS[@]} -gt 0 ]]; then
        printf -- '- ADD FAILED (%s files; cp or mkdir -p returned non-zero):\n' "${#FAILED_ADDS[@]}"
        for p in "${FAILED_ADDS[@]}"; do printf '  - %s\n' "$p"; done
    fi
    printf -- '- SKIPped (%s, byte-equal already)\n' "${#ACT_SKIP[@]}"
    printf -- '- REFUSEd (%s, host-modified; left alone)\n' "${#ACT_REFUSE[@]}"
    printf -- '- init-wiki: %s (%s)\n' "$INIT_WIKI_STATUS" "$INIT_WIKI_DETAIL"
    printf -- '- github-wiki: %s (%s)\n' "$GITHUB_WIKI_STATUS" "$GITHUB_WIKI_DETAIL"
    printf -- '- overlay setup: %s (%s)\n' "$OVERLAY_SETUP_STATUS" "$OVERLAY_SETUP_DETAIL"
    printf -- '- TOUCH applied (%s):\n' "${#APPLIED_TOUCHES[@]}"
    if [[ ${#APPLIED_TOUCHES[@]} -gt 0 ]]; then
        for t in "${APPLIED_TOUCHES[@]}"; do printf '  - %s\n' "$t"; done
    fi
    printf '\n'
} >> "$ADOPT_LOG"

echo ""
if [[ ${#FAILED_ADDS[@]} -gt 0 ]]; then
    echo "Applied: ${#APPLIED_ADDS[@]} file(s) created, ${#FAILED_ADDS[@]} FAILED in $TARGET"
    echo "Review ADD FAILED block in .llm-wiki-adopt-log.md for the failing paths."
else
    echo "Applied: ${#APPLIED_ADDS[@]} file(s) created in $TARGET"
fi
echo "Manifest written to .llm-wiki-adopt-log.md"
echo "Review the result with: git -C $TARGET status && git -C $TARGET diff"
