#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
#
# setup.sh — Cursor overlay on top of an llm-wiki project.
#
# This script is the Cursor-specific layer of the llm-wiki pattern, parallel
# to wiki/agents/claude-code/setup.sh. wiki/init-wiki.sh stays agent-agnostic.
#
# Usage:
#   ./wiki/agents/cursor/setup.sh                 # verify wiki and rules
#
# What it does:
#   1. Verifies the wiki is present (else points to init-wiki.sh).
#   2. Reports presence/absence of the .cursor/rules/*.mdc set. These ship
#      with the repository and the script only verifies them. The overlay
#      never touches CLAUDE.md: the behavioral instructions live in the
#      rules files (wiki-as-memory and memory-boundary are alwaysApply).
#
# Cursor has no SessionStart hook equivalent and no per-user memory directory
# managed by the IDE, so the Claude Code overlay's --hook and --seed-memory
# flags have no analog here. The always-applied rule wiki-as-memory.mdc
# carries the same persistent intent.
#
# There is no single-file .cursorrules fallback: Cursor reads
# .cursor/rules/*.mdc since 0.45 (January 2025) and marks .cursorrules
# legacy, so the overlay ships only the .mdc form.
#
# Does not commit anything. Does not push.
#

set -euo pipefail

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# --- Load shared library ---
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../../scripts/lib/common.sh
source "$HERE/../../../scripts/lib/common.sh"

# --- Detect project layout ---
REPO_ROOT=$(lw_repo_root)
# This overlay runs post-clone, so the canonical name is already committed
# as wiki/<name>.wiki. Read it from there rather than from the clone
# directory name (a fork or renamed clone makes the basename, and origin,
# wrong here). lw_discover_wiki_name fails loud if the wiki is absent.
REPO_NAME=$(lw_discover_wiki_name "$REPO_ROOT")
WIKI_DIR="$REPO_ROOT/wiki/${REPO_NAME}.wiki"
SCHEMA_FILE="$WIKI_DIR/SCHEMA_${REPO_NAME}.md"

RULES_DIR="$REPO_ROOT/.cursor/rules"

# --- Step 1: verify wiki present ---
if [[ ! -f "$SCHEMA_FILE" ]]; then
    echo "ERROR: wiki not found at $WIKI_DIR" >&2
    echo "       (expected $SCHEMA_FILE)" >&2
    echo "" >&2
    echo "Run wiki/init-wiki.sh first, then re-run this script." >&2
    exit 1
fi

# --- Step 2: verify .cursor/rules/*.mdc present ---
# The overlay's behavioral instructions live entirely in these rules files;
# nothing is injected into the host's CLAUDE.md.
RULES_MISSING=()
for rule in wiki-as-memory memory-boundary wiki-experiment wiki-source wiki-lint; do
    if [[ ! -f "$RULES_DIR/${rule}.mdc" ]]; then
        RULES_MISSING+=("$rule")
    fi
done

if [[ ${#RULES_MISSING[@]} -eq 0 ]]; then
    lw_record_skip ".cursor/rules/: all five present (wiki-as-memory, memory-boundary, wiki-experiment, wiki-source, wiki-lint)"
else
    lw_record_skip ".cursor/rules/: MISSING — ${RULES_MISSING[*]} (these should be committed in the repo)"
fi

# --- Summary ---
echo ""
echo "================ Cursor overlay setup ================"
echo "Repo:        $REPO_ROOT"
echo "Wiki:        $WIKI_DIR"
echo "------------------------------------------------------"
lw_print_report
echo "======================================================"
echo ""

if lw_changed_p; then
    echo "Next steps:"
    echo "  Review the changes above, then stage and commit:"
    echo "    git add .cursor/"
    echo "    git commit -m \"cursor: apply Cursor overlay (setup.sh)\""
    echo ""
fi
