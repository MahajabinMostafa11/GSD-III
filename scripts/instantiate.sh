#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
#
# instantiate.sh — first-use bootstrap for a project created from llm-wiki-memory-template.
#
# Usage:
#   ./scripts/instantiate.sh "<Project Name>" [--agent=<x>] [--description="..."] [--github-wiki] [--features=<csv>]
#   ./scripts/instantiate.sh --dev-self                  # (template contributor self-dogfood mode)
#
# Positional:
#   <Project Name>   Human-readable project name (e.g. "Data Platform Notes").
#                    Substituted for {{PROJECT_NAME}} in README.md.template.
#                    Not required when --dev-self is set.
#
# Flags:
#   --agent=<x>      Agent overlay to activate. One of:
#                      none         minimal: only llm-wiki core (for OpenCode, Pi, etc.)
#                      claude-code  install Claude Code overlay (default)
#                      cursor       install Cursor overlay
#                      all          install both Claude Code and Cursor overlays
#   --description=   One-sentence description of the project. Substituted for
#                    {{DESCRIPTION}} in README.md.template. If omitted, README.md
#                    is left with a placeholder you can edit by hand.
#   --github-wiki    Use the GitHub Wiki of the project's main repo as the
#                    wiki sub-repo backend (instead of init'ing a local-only
#                    wiki).
#
#                    IMPORTANT: GitHub typically requires the first Wiki
#                    page to be created through the UI before
#                    <repo>.wiki.git materializes as a clonable/pushable
#                    repository. This script attempts a direct push of a
#                    seed Home.md anyway (it costs nothing if it fails)
#                    and falls back with explicit instructions to open
#                    the UI, create one page, and re-run.
#
#                    Requires `origin` to be set on the main repo, an SSH
#                    key registered for github.com, and `gh` (optional,
#                    defensive) for the has_wiki=true PATCH.
#   --dev-self       Self-dogfood mode for template contributors. Installs the
#                    SessionStart + PostToolUse hooks in the template repo
#                    itself (so working in a template clone gives Claude Code
#                    llm-wiki context; the behavioral instructions already ship
#                    as tracked .claude/rules/*.md files). Does NOT clone the
#                    wiki, run init-wiki.sh, modify
#                    .claude/skills, or self-delete. Prerequisite: clone the
#                    template's GitHub Wiki to wiki/llm-wiki-memory-template.wiki/
#                    manually before running this. All resulting artifacts are
#                    gitignored.
#   --features=<csv> Comma-separated list of feature names to enable at
#                    instantiation time (RFC #13). Each name must match a
#                    directory under features/ that contains a feature.json.
#                    Example: --features=kg or --features=kg,socratic-tutor.
#                    Empty (default) means no features; the base template
#                    ships with no real features in Etapa 1. Features can
#                    also be enabled retroactively via scripts/enable-feature.sh
#                    and removed via scripts/disable-feature.sh.
#
# One-shot enforcement: a successful run self-deletes this script. Re-running
# after a partial failure (e.g. the --github-wiki 404 workaround) is safe:
# every step is presence-guarded or idempotent, so completed steps skip.
#

set -euo pipefail

# --- Parse arguments ---
PROJECT_NAME=""
AGENT="claude-code"
DESCRIPTION=""
GITHUB_WIKI=false
FEATURES_CSV=""
DEV_SELF=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --agent=*)        AGENT="${1#*=}"; shift ;;
        --description=*)  DESCRIPTION="${1#*=}"; shift ;;
        --github-wiki)    GITHUB_WIKI=true; shift ;;
        --features=*)     FEATURES_CSV="${1#*=}"; shift ;;
        --dev-self)       DEV_SELF=true; shift ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        --*)
            echo "Unknown option: $1" >&2; exit 1 ;;
        *)
            if [[ -z "$PROJECT_NAME" ]]; then
                PROJECT_NAME="$1"
            else
                echo "Unexpected positional arg: $1" >&2; exit 1
            fi
            shift ;;
    esac
done

if [[ -z "$PROJECT_NAME" ]] && ! $DEV_SELF; then
    echo "Error: <Project Name> is required (positional arg)." >&2
    echo "Run with --help for usage." >&2
    exit 1
fi

case "$AGENT" in
    none|claude-code|cursor|all) ;;
    *) echo "Error: --agent must be one of: none, claude-code, cursor, all" >&2; exit 1 ;;
esac

# Forward the agent identity to init-wiki.sh so the "create" log entry is
# attributed (- by: <user> via <agent>). Only a single concrete agent is
# forwarded; "none" and "all" leave the entry's by: line human-only.
INIT_AGENT_ARGS=()
case "$AGENT" in
    claude-code|cursor) INIT_AGENT_ARGS=(--agent "$AGENT") ;;
esac

# --- Parse --features= CSV into FEATURES_LIST (RFC #13, Etapa 1) ---
# Validation happens after the project layout is detected so the error
# message can refer to the resolved features/ directory. Empty CSV means
# no features; bootstrap proceeds with the base template only.
FEATURES_LIST=()
if [[ -n "$FEATURES_CSV" ]]; then
    # Bash 3.2 compatible CSV split (no IFS=, read -a trick portability)
    _csv="$FEATURES_CSV"
    while [[ -n "$_csv" ]]; do
        case "$_csv" in
            *,*) _name="${_csv%%,*}"; _csv="${_csv#*,}" ;;
            *)   _name="$_csv";       _csv="" ;;
        esac
        # Trim whitespace
        _name="${_name#"${_name%%[![:space:]]*}"}"
        _name="${_name%"${_name##*[![:space:]]}"}"
        [[ -n "$_name" ]] && FEATURES_LIST+=("$_name")
    done
fi

# --- Load shared library ---
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh"

# --- Detect project layout ---
# At first-use the wiki does not exist yet, so the canonical name is resolved
# from the origin repo (lw_name_from_origin; the clone-directory basename is
# only a last-resort fallback when no origin is set). This name is resolved
# ONCE here and handed to init-wiki.sh via --repo-name, so the namespace is
# derived in exactly one place (F1).
REPO_ROOT=$(lw_repo_root)
REPO_NAME=$(lw_name_from_origin "$REPO_ROOT")
README_MD="$REPO_ROOT/README.md"
README_MD_TEMPLATE="$REPO_ROOT/README.md.template"

# --- Validate --features= names early (fail fast before bootstrap) ---
# Each requested feature must have a feature.json at features/<name>/.
# This runs BEFORE rendering README.md or invoking init-wiki.sh so a typo
# in --features= does not leave a partially-bootstrapped project behind.
if [[ "${#FEATURES_LIST[@]}" -gt 0 ]]; then
    _missing=()
    for _f in "${FEATURES_LIST[@]}"; do
        if [[ ! -f "$REPO_ROOT/features/$_f/feature.json" ]]; then
            _missing+=("$_f")
        fi
    done
    if [[ "${#_missing[@]}" -gt 0 ]]; then
        echo "Error: requested feature(s) not found in $REPO_ROOT/features/:" >&2
        for _f in "${_missing[@]}"; do
            echo "  - $_f" >&2
        done
        echo "" >&2
        echo "Available features:" >&2
        _found=0
        if [[ -d "$REPO_ROOT/features" ]]; then
            for _d in "$REPO_ROOT/features"/*/; do
                [[ -d "$_d" ]] || continue
                [[ -f "$_d/feature.json" ]] || continue
                echo "  - $(basename "$_d")" >&2
                _found=1
            done
        fi
        [[ "$_found" -eq 0 ]] && echo "  (none)" >&2
        exit 1
    fi
fi

# Derive OWNER (org or user) from the origin URL, so the generated README's
# clone commands use the real owner instead of a literal <owner> placeholder.
# lw_owner_from_url is host-agnostic (https / scp-style ssh / ssh:// with
# port), replacing the github.com-only strip this used to do. Falls back to a
# literal "<owner>" if origin is not set yet (e.g. the user cloned somewhere
# private and has not pushed).
ORIGIN_URL=$(lw_origin_url "$REPO_ROOT" 2>/dev/null) || ORIGIN_URL=""
if [[ -n "$ORIGIN_URL" ]]; then
    OWNER=$(lw_owner_from_url "$ORIGIN_URL")
else
    OWNER="<owner>"
fi

# No "already instantiated" guard is needed here: a successful run
# self-deletes this script (one-shot pattern, end of file), and every step
# below is presence-guarded or idempotent, so re-running after a partial
# failure completes the remaining steps instead of erroring.

# --- Dev-self path: template contributor self-dogfooding ---
# Installs the claude-code SessionStart + PostToolUse hooks in the
# template clone, so a contributor opens Claude Code in the template repo
# and gets the same wiki-discipline context any derived project gets (the
# behavioral instructions themselves already ship as tracked
# .claude/rules/*.md files, live in every checkout). Diverges from the
# normal flow in four ways:
#   1. No PROJECT_NAME required.
#   2. Does NOT delete the .template files (the template must stay intact
#      so future instantiations of derived projects work).
#   3. Does NOT call init-wiki.sh; the contributor clones the template's
#      own GitHub Wiki manually to wiki/llm-wiki-memory-template.wiki/
#      (one-time, documented in README).
#   4. Does NOT touch .claude/skills (avoids
#      dirtying tracked template files with REPO_NAME substitution).
# All resulting artifacts (.claude/settings.json, .claude/hooks/, the
# wiki clone) are excluded locally via .git/info/exclude, which this
# --dev-self branch writes below. They are deliberately NOT in the
# tracked .gitignore: leading-slash anchors there would resolve to a
# derived repo's root after update-from-template.sh synced the file,
# shadowing the derived project's real files.
if $DEV_SELF; then
    # Pre-flight: ensure the template's own wiki has been cloned manually.
    DEV_SELF_WIKI="$REPO_ROOT/wiki/llm-wiki-memory-template.wiki"
    if [[ ! -d "$DEV_SELF_WIKI" ]]; then
        echo "Error: --dev-self requires the template's GitHub Wiki cloned at" >&2
        echo "       $DEV_SELF_WIKI" >&2
        echo "" >&2
        echo "Run this one-time, then re-invoke --dev-self:" >&2
        echo "  git clone https://github.com/crcresearch/llm-wiki-memory-template.wiki.git \\" >&2
        echo "    wiki/llm-wiki-memory-template.wiki" >&2
        exit 1
    fi

    # Write dev-self ignore entries to .git/info/exclude (per-clone, not
    # tracked, so they cannot propagate to derived projects). These used to
    # live in the tracked .gitignore but their leading-slash anchors resolved
    # to a derived repo's own root after update-from-template.sh synced the
    # file, silently shadowing the derived project's real CLAUDE.md and
    # .claude/ paths. Idempotent: a marked block is replaced atomically; an
    # unmarked file gets the block appended.
    mkdir -p "$REPO_ROOT/.git/info"
    EXCLUDE_FILE="$REPO_ROOT/.git/info/exclude"
    BEGIN_MARK="# BEGIN llm-wiki-memory-template dev-self"
    DEV_SELF_BLOCK=$(cat <<'EOF'
# BEGIN llm-wiki-memory-template dev-self
# Written by scripts/instantiate.sh --dev-self. Local-only; never propagates.
/wiki/llm-wiki-memory-template.wiki/
/.claude/settings.json
/.claude/hooks/
# END llm-wiki-memory-template dev-self
EOF
)
    if [[ -f "$EXCLUDE_FILE" ]] && grep -qF "$BEGIN_MARK" "$EXCLUDE_FILE"; then
        # Replace existing marked block in place.
        python3 - "$EXCLUDE_FILE" "$DEV_SELF_BLOCK" <<'PYEOF'
import sys, pathlib, re
path, block = sys.argv[1], sys.argv[2]
text = pathlib.Path(path).read_text()
pattern = re.compile(
    r"# BEGIN llm-wiki-memory-template dev-self.*?# END llm-wiki-memory-template dev-self",
    re.DOTALL,
)
pathlib.Path(path).write_text(pattern.sub(block, text))
PYEOF
        echo "✓ Updated dev-self block in .git/info/exclude"
    else
        # Append the block. Ensure exactly one blank line between any prior
        # content and the new block.
        if [[ -s "$EXCLUDE_FILE" ]]; then
            [[ -n "$(tail -c 1 "$EXCLUDE_FILE")" ]] && printf '\n' >> "$EXCLUDE_FILE"
            printf '\n' >> "$EXCLUDE_FILE"
        fi
        printf '%s\n' "$DEV_SELF_BLOCK" >> "$EXCLUDE_FILE"
        echo "✓ Wrote dev-self block to .git/info/exclude"
    fi

    # Install the SessionStart + PostToolUse hooks via the existing overlay
    # setup. setup.sh handles .claude/settings.json create-or-merge and
    # copies the hook scripts from wiki/agents/claude-code/templates/ to
    # .claude/hooks/ with ${REPO_NAME} substituted to the right value at
    # install time.
    "$REPO_ROOT/wiki/agents/claude-code/setup.sh" --hook --posttooluse-hook

    echo ""
    echo "================ Dev-self instance ready ================"
    echo "  .claude/hooks/session-start.sh:     installed"
    echo "  .claude/hooks/posttooluse-hook.sh:  installed"
    echo "  .claude/settings.json:              created/merged with hooks block"
    echo "  Template wiki:                      $DEV_SELF_WIKI"
    echo ""
    echo "All three artifacts are gitignored — they will not be committed"
    echo "and they will not propagate to derived projects."
    echo ""
    echo "Claude Code in this directory now has llm-wiki context. Open it"
    echo "here and the SessionStart hook will fire on next session start."
    echo "========================================================="
    exit 0
fi

# CLAUDE.md is not rendered here: it is host-owned from the start. The
# behavioral instructions ship with the agent overlays (.claude/rules/*.md,
# .cursor/rules/*.mdc); the project's own narrative CLAUDE.md is the
# host's to write (e.g. via claude /init).

# --- Substitute placeholders in README.md.template -> README.md ---
# Overwrites the README that arrived from the template repo (which describes
# the template itself, not your new project). The new README is a starting
# point with three suggested sections: usage of LLM wiki memory, quick-start
# for collaborators, pointer back to the template. Edit it freely.
if [[ -f "$README_MD_TEMPLATE" ]]; then
    sed \
        -e "s|{{PROJECT_NAME}}|$PROJECT_NAME|g" \
        -e "s|{{REPO_NAME}}|$REPO_NAME|g" \
        -e "s|{{OWNER}}|$OWNER|g" \
        -e "s|{{DESCRIPTION}}|${DESCRIPTION:-<one-sentence description, edit me>}|g" \
        "$README_MD_TEMPLATE" > "$README_MD"
    rm -f "$README_MD_TEMPLATE"
    echo "Wrote README.md (project-specific; the template's own README was replaced)"
fi

# --- Strip template-development-only rules ---
# .claude/rules/ holds guidance for contributors working ON the template
# itself (e.g. observe-the-failure.md), not behavior a derived project needs.
# Remove only the named dev-only rules, never the whole directory, so any
# consumer-facing rule a project adds under .claude/rules/ survives and this
# list stays easy to extend later. The manifest sync arrays consumed by
# update-from-template.sh do not re-add these.
CLAUDE_RULES_DIR="$REPO_ROOT/.claude/rules"
DEV_ONLY_RULES=(observe-the-failure.md local-testing.md)
for _rule in "${DEV_ONLY_RULES[@]}"; do
    if [[ -f "$CLAUDE_RULES_DIR/$_rule" ]]; then
        rm -f "$CLAUDE_RULES_DIR/$_rule"
        echo "Removed .claude/rules/$_rule (template-development-only; not propagated to derived projects)"
    fi
done
# Tidy up only if our removals emptied the directory; leave it in place when a
# consumer-facing rule is present.
if [[ -d "$CLAUDE_RULES_DIR" ]] && [[ -z "$(ls -A "$CLAUDE_RULES_DIR" 2>/dev/null)" ]]; then
    rmdir "$CLAUDE_RULES_DIR"
fi

# --- Bootstrap the wiki ---
if [[ -d "$REPO_ROOT/wiki/${REPO_NAME}.wiki" ]]; then
    echo "Wiki sub-repo already present at wiki/${REPO_NAME}.wiki/, skipping init-wiki.sh"
else
    if $GITHUB_WIKI; then
        # --- Pre-step: ensure the GitHub Wiki is initialized ---
        # The GitHub Wiki at <repo>.wiki.git is materialized only after a first
        # page is created. Without that, `git clone <repo>.wiki.git` (which
        # init-wiki.sh --github relies on) fails. To avoid forcing the user
        # through the GitHub UI, this block:
        #   1. Derives <repo>.wiki.git from the main repo's origin URL.
        #   2. Checks if the wiki remote is already initialized.
        #   3. If not, pushes a one-commit seed (Home.md) directly to it.
        #      init-wiki.sh will then patch its namespaced files on top.

        ORIGIN_URL=$(lw_origin_url "$REPO_ROOT" 2>/dev/null) || ORIGIN_URL=""
        if [[ -z "$ORIGIN_URL" ]]; then
            echo "Error: --github-wiki requires a git remote 'origin' on the main repo." >&2
            echo "       Push the project repo to GitHub first, then re-run." >&2
            exit 1
        fi
        # lw_wiki_url strips/appends the suffix correctly for both the .git and
        # suffix-less forms (the old case-on-suffix did this inline), and fails
        # loud on a non-GitHub host rather than emitting a wrong URL (D1).
        WIKI_REMOTE_URL=$(lw_wiki_url "$ORIGIN_URL")

        # Use the main repo's own origin protocol for the seed push, so it
        # reuses whatever auth already cloned the main repo: an SSH key if
        # origin is SSH, or gh's HTTPS credential helper if origin is HTTPS
        # (which is what `gh repo create --clone` sets up). An earlier
        # version forced an HTTPS-to-SSH conversion here, which broke users
        # who clone over HTTPS via gh and have no SSH key configured.
        WIKI_PUSH_URL="$WIKI_REMOTE_URL"

        # The wiki does not exist yet, so there is no remote default branch to
        # detect; this seed push CREATES it. GitHub renders a wiki from its
        # default branch, which it initializes as 'master' for wikis, so we
        # bootstrap onto that name deliberately (one variable, not a literal
        # repeated across init + push). init-wiki.sh then clones the now-real
        # wiki and detects this same branch via lw_default_branch (F5).
        WIKI_SEED_BRANCH="master"

        if ! git ls-remote "$WIKI_PUSH_URL" >/dev/null 2>&1; then
            echo "GitHub Wiki not initialized yet at $WIKI_REMOTE_URL"
            echo "Bootstrapping with a seed Home.md via direct push (over SSH) ..."

            # Best-effort: ensure has_wiki=true on the main repo (idempotent;
            # default is already true, so this is just defensive). lw_repo_slug
            # yields owner/repo host-agnostically, replacing the inline strip.
            if command -v gh >/dev/null 2>&1; then
                REPO_SLUG=$(lw_repo_slug "$ORIGIN_URL")
                gh api "repos/$REPO_SLUG" -X PATCH -F has_wiki=true >/dev/null 2>&1 || true
            fi

            # Note: `set -e` is disabled by bash inside the (subshell) of an
            # `if (...); then`, so we use a `&&` chain to short-circuit on
            # any failure. The chain's exit code is what `if` evaluates,
            # which gives us correct error propagation.
            #
            # Also note: GitHub typically REQUIRES that the first Wiki page
            # be created through the UI before <repo>.wiki.git materializes.
            # The push below may therefore fail with "Repository not found"
            # even with valid auth and has_wiki=true. That is not a bug in
            # this script — it is a GitHub Wiki architecture constraint.
            # The fallback message below points the user at the UI URL.
            # `git init -q` + `symbolic-ref` sets the initial branch portably;
            # `git init -b <branch>` needs git >= 2.28, which we do not assume.
            if (
                TMP=$(mktemp -d) \
                && cd "$TMP" \
                && git init -q \
                && git symbolic-ref HEAD "refs/heads/$WIKI_SEED_BRANCH" \
                && printf '# Home\n\nBootstrapped by llm-wiki-memory-template/scripts/instantiate.sh.\n' > Home.md \
                && git add Home.md \
                && git \
                    -c user.email=instantiate@llm-wiki-memory-template \
                    -c user.name="instantiate.sh" \
                    commit -m "Initialize wiki" -q \
                && git push -q "$WIKI_PUSH_URL" "$WIKI_SEED_BRANCH:$WIKI_SEED_BRANCH" \
                && cd / \
                && rm -rf "$TMP"
            ); then
                echo "Wiki bootstrapped at $WIKI_PUSH_URL"
            else
                # URL the user can open to bootstrap manually.
                # Bash parameter expansion (portable; avoids sed -E variants).
                WIKI_UI_URL="${ORIGIN_URL%.git}"
                WIKI_UI_URL="${WIKI_UI_URL/git@github.com:/https://github.com/}"
                WIKI_UI_URL="${WIKI_UI_URL}/wiki"
                echo "" >&2
                echo "Wiki bootstrap via direct push failed." >&2
                echo "This is the most common outcome on the first --github-wiki" >&2
                echo "run for a project: GitHub requires the first Wiki page to be" >&2
                echo "created through the UI before <repo>.wiki.git becomes a" >&2
                echo "clonable/pushable repository. Until then, push returns 404." >&2
                echo "" >&2
                echo "Workaround:" >&2
                echo "  1. Open $WIKI_UI_URL in a browser." >&2
                echo "  2. Click \"Create the first page\", title \"Home\", any content, save." >&2
                echo "  3. Re-run: ./scripts/instantiate.sh \"$PROJECT_NAME\" --agent=$AGENT --github-wiki" >&2
                echo "" >&2
                echo "Or, to skip GitHub Wiki entirely and use a local-only wiki:" >&2
                echo "  ./scripts/instantiate.sh \"$PROJECT_NAME\" --agent=$AGENT" >&2
                exit 1
            fi
        fi

        # Hand the once-resolved name to init-wiki via --repo-name so the
        # namespace is derived in exactly one place (F1); without it init-wiki
        # would re-derive from origin and could disagree on a fork/rename.
        "$REPO_ROOT/wiki/init-wiki.sh" --repo-name "$REPO_NAME" --github ${INIT_AGENT_ARGS[@]+"${INIT_AGENT_ARGS[@]}"}
    else
        "$REPO_ROOT/wiki/init-wiki.sh" --repo-name "$REPO_NAME" ${INIT_AGENT_ARGS[@]+"${INIT_AGENT_ARGS[@]}"}
    fi
fi

# --- Activate the chosen agent overlay(s) and prune the others ---
keep_claude_code=false
keep_cursor=false
case "$AGENT" in
    none)         ;;
    claude-code)  keep_claude_code=true ;;
    cursor)       keep_cursor=true ;;
    all)          keep_claude_code=true; keep_cursor=true ;;
esac

# Claude Code
if $keep_claude_code; then
    # Substitute {{REPO_NAME}} in shipped .claude/ files (one-shot at instantiate).
    # Skills are directory-per-skill (<name>/SKILL.md); flat .claude/skills/*.md
    # files are not discovered by Claude Code.
    for f in "$REPO_ROOT/.claude/skills/"wiki-*/SKILL.md; do
        [[ -f "$f" ]] || continue
        sed -i.bak "s|{{REPO_NAME}}|$REPO_NAME|g" "$f"
        rm -f "${f}.bak"
    done
    # settings.json.template -> settings.json with substitution
    if [[ -f "$REPO_ROOT/.claude/settings.json.template" ]]; then
        sed "s|{{REPO_NAME}}|$REPO_NAME|g" "$REPO_ROOT/.claude/settings.json.template" \
            > "$REPO_ROOT/.claude/settings.json"
        rm -f "$REPO_ROOT/.claude/settings.json.template"
    fi
    # Run the overlay's setup.sh (base mode; user can re-run with --hook/--seed-memory)
    "$REPO_ROOT/wiki/agents/claude-code/setup.sh"
else
    rm -rf "$REPO_ROOT/.claude"
    rm -rf "$REPO_ROOT/wiki/agents/claude-code"
fi

# Cursor
if $keep_cursor; then
    # Substitute {{REPO_NAME}} in shipped .cursor/ files
    for f in "$REPO_ROOT/.cursor/rules/"wiki-*.mdc; do
        [[ -f "$f" ]] || continue
        sed -i.bak "s|{{REPO_NAME}}|$REPO_NAME|g" "$f"
        rm -f "${f}.bak"
    done
    # Run the overlay's setup.sh
    "$REPO_ROOT/wiki/agents/cursor/setup.sh"
else
    rm -rf "$REPO_ROOT/.cursor"
    rm -rf "$REPO_ROOT/wiki/agents/cursor"
fi

# --- Install requested features (RFC #13, Etapa 1) ---
# After the base bootstrap and any agent overlay have been set up, install
# each feature listed in --features=. Validation already happened above;
# this section just executes the installs through the shared library.
if [[ "${#FEATURES_LIST[@]}" -gt 0 ]]; then
    # shellcheck source=lib/install-feature.sh
    source "$REPO_ROOT/scripts/lib/install-feature.sh"
    echo ""
    echo "--------------------------------------------------------"
    echo "Installing features: ${FEATURES_LIST[*]}"
    echo "--------------------------------------------------------"
    cd "$REPO_ROOT"
    for _f in "${FEATURES_LIST[@]}"; do
        install_feature "$_f" || {
            echo "Error: install_feature '$_f' failed." >&2
            exit 1
        }
    done
fi

# --- Final checklist ---
echo ""
echo "================ Instantiation complete ================"
echo "Project:  $PROJECT_NAME"
echo "Repo:     $REPO_NAME"
echo "Agent:    $AGENT"
echo "--------------------------------------------------------"
echo "Next steps:"
echo "  1. Edit README.md: replace the template's README with one for THIS project."
case "$AGENT" in
    claude-code|all)
        echo "  2. (Optional) Add the SessionStart hook and personal memory seed:"
        echo "       ./wiki/agents/claude-code/setup.sh --all"
        ;;
esac
echo "  3. Stage and commit the generated files:"
echo "       git add -A && git commit -m \"chore: instantiate from llm-wiki-memory-template\""
echo "  4. Open your AI assistant in the project root and start working."
echo "========================================================"

# --- Self-delete (one-shot pattern) ---
# instantiate.sh exists only to bootstrap a new project. After a successful
# run, remove it from the project so:
#   1. It cannot be re-executed accidentally; its absence is what marks an
#      instantiated project (tests and clone_template use it as the
#      template-vs-derived discriminator).
#   2. update-from-template.sh and check-template-version.sh do not have to
#      special-case its presence (it is excluded from their sync lists).
# The canonical version of this script lives in the template repo. To
# re-instantiate, clone the template again.
echo ""
echo "(instantiate.sh is one-shot. Removing it from the project."
echo " The canonical version lives in the template repo.)"
rm -f "$0"
