#!/usr/bin/env bash
# enroll.sh — interactive registration of this repo as a federation agent.
#
# Two idempotent steps:
#   1. Generate wiki/<repo>.wiki/Card_<repo>.md from interactive prompts
#      (refuses to overwrite an existing Card).
#   2. Federation step: noop if repo is already in LA3D-LLM-Agents org
#      (rebuild Action picks it up); otherwise offer to add the
#      'nd-llm-wiki' GitHub topic so the topic-walk discovery path
#      (with trusted-owner allowlist) picks it up cross-org.
#
# Scope (v0.1.0 MVP): the agent-comms feature ships the `ask` primitive
# only. Async `message` and `post` modes require a separate mailbox skill
# (helpers send.sh, check.sh, onboard.sh writing to ~/.llm-agents/). As
# of v0.1.0 the mailbox skill is NOT yet published as a standalone
# artifact — this enroll.sh deliberately does NOT shell out to mailbox
# helpers; it would fail on any machine without them installed.
#
# Flags:
#   --dry-run   print what would happen; do not write Card or invoke
#               `gh repo edit`.
#   -h|--help   show this help.
#
# Testability env vars:
#   LLM_AGENTS_DIR   substrate root (default: $HOME/.llm-agents)
#                    used by ask.sh for wikis-cache/. enroll.sh itself
#                    doesn't write to LLM_AGENTS_DIR in v0.1.0.
#                    (Back-compat: MAILBOX_DIR also honored.)
#
# Exit codes:
#   0   success (including user-aborted prompts)
#   1   fatal: missing required command
#   2   usage error (unknown flag, etc.)
#   9   wiki sub-repo not found at wiki/<repo>.wiki/
#  12   not in a git repository
set -euo pipefail

LLM_AGENTS_DIR="${LLM_AGENTS_DIR:-${MAILBOX_DIR:-$HOME/.llm-agents}}"
DRY_RUN=0

# Trusted-owners allowlist mirrors scripts/build-index.py in
# la3d-llm-agents.github.io. Topic-walk discovery filters to these owners
# (case-insensitive). If your repo's owner isn't here, adding the
# nd-llm-wiki topic alone won't put you in the federation index.
TRUSTED_TOPIC_OWNERS_LC="la3d-llm-agents la3d crcresearch paperanalyticaldevicend chrissweet charlesvardeman psaboia"

usage() {
  cat <<EOF
Usage:
  enroll.sh             interactive registration (creates Card, offers
                        federation topic add)
  enroll.sh --dry-run   print actions without performing them (still prompts)
  enroll.sh -h | --help this help

What it does (v0.1.0 — ask-only MVP):
  1. Generates wiki/<repo>.wiki/Card_<repo>.md if absent (interactive
     prompts for description, optional topics, optional capabilities).
  2. If repo is in LA3D-LLM-Agents org, federation index picks it up
     automatically. Otherwise offers to add the 'nd-llm-wiki' GitHub
     topic so the topic-walk discovery path picks it up cross-org
     (requires repo owner to be on the trusted-owners allowlist).

What it does NOT do (deferred):
  - Mailbox onboarding (async DM / channel setup). Requires the
    separately-installed mailbox skill, not bundled with this feature.

Env vars:
  LLM_AGENTS_DIR  default: \$HOME/.llm-agents
                  used by ask.sh for wikis-cache/.
                  (back-compat: MAILBOX_DIR also honored)
EOF
}

die() { echo "ERROR: $*" >&2; exit "${2:-1}"; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || die "$1 not found on PATH" 1; }

# --- Argument parsing -------------------------------------------------------

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --) shift; break ;;
    -*)
      echo "ERROR: unknown flag: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      echo "ERROR: unexpected positional argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

# --- Phase 1: detection (pre-prompt) ----------------------------------------

require_cmd git

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" \
  || die "not in a git repository" 12

REPO_NAME="$(basename "$REPO_ROOT")"
WIKI_DIR="$REPO_ROOT/wiki/${REPO_NAME}.wiki"

if [[ ! -d "$WIKI_DIR" ]]; then
  echo "ERROR: wiki sub-repo not found at $WIKI_DIR" >&2
  echo "       Run 'bash wiki/init-wiki.sh' first to bootstrap the wiki." >&2
  exit 9
fi

require_cmd gh

OWNER="$(gh api /user --jq .login 2>/dev/null)" \
  || die "gh api /user failed. Run 'gh auth login' first." 1

DEFAULT_ID="$OWNER/$REPO_NAME"

# --- Phase 2: prompts -------------------------------------------------------

{
  echo ""
  echo "=== Agent onboarding ==="
  echo "Detected GitHub owner: $OWNER"
  echo "Detected repo name:    $REPO_NAME"
  echo "Detected wiki path:    $WIKI_DIR"
  [[ "$DRY_RUN" -eq 1 ]] && echo "(DRY RUN: no files will be written; no gh calls will mutate state)"
  echo ""
} >&2

echo -n "Agent ID will be: $DEFAULT_ID  [enter to accept, or type override]: " >&2
read -r AGENT_ID || AGENT_ID=""
AGENT_ID="$(echo "$AGENT_ID" | tr -d '[:space:]')"
[[ -z "$AGENT_ID" ]] && AGENT_ID="$DEFAULT_ID"

AGENT_NAME="${AGENT_ID##*/}"
CARD_PATH="$WIKI_DIR/Card_${AGENT_NAME}.md"

CARD_WRITE=1
if [[ -f "$CARD_PATH" ]]; then
  echo "" >&2
  echo "NOTE: $CARD_PATH already exists. Skipping Card generation." >&2
  echo "      Edit it directly, or delete and re-run enroll.sh." >&2
  CARD_WRITE=0
fi

DESCRIPTION=""
TOPICS_CSV=""
CAPABILITIES=()

if [[ "$CARD_WRITE" -eq 1 ]]; then
  # Description (required, prompt-until-non-empty)
  while true; do
    echo -n "One-line description (what does this agent do?): " >&2
    read -r DESCRIPTION || DESCRIPTION=""
    [[ -n "${DESCRIPTION// /}" ]] && break
    echo "  (description is required; try again or Ctrl+C to abort)" >&2
  done

  echo -n "Topics, comma-separated (empty to skip): " >&2
  read -r TOPICS_CSV || TOPICS_CSV=""

  echo "Capabilities, one per line. Empty line to finish:" >&2
  while true; do
    echo -n "  > " >&2
    read -r cap || break
    [[ -z "${cap// /}" ]] && break
    CAPABILITIES+=("$cap")
  done
fi

# --- Phase 3: draft + confirm + write ---------------------------------------

# Build the Card content into a variable so we can show + write atomically.
build_card_content() {
  printf -- '---\n'
  printf 'type: agent\n'
  printf 'up: "[[Home_%s]]"\n' "$REPO_NAME"
  printf 'id: %s\n' "$AGENT_ID"
  printf 'description: %s\n' "$DESCRIPTION"

  if [[ "${#CAPABILITIES[@]}" -gt 0 ]]; then
    printf 'capabilities:\n'
    for cap in "${CAPABILITIES[@]}"; do
      printf '  - %s\n' "$cap"
    done
  fi

  # Trim topics CSV: strip spaces around commas
  local topics_clean=""
  if [[ -n "${TOPICS_CSV// /}" ]]; then
    topics_clean="$(echo "$TOPICS_CSV" | tr -d ' ')"
    printf 'x-llm-wiki:\n'
    printf '  topics: [%s]\n' "$topics_clean"
  fi

  printf -- '---\n\n'
  printf '# Agent: %s\n\n' "$AGENT_ID"
  printf '%s\n' "$DESCRIPTION"
}

if [[ "$CARD_WRITE" -eq 1 ]]; then
  CARD_CONTENT="$(build_card_content)"
  {
    echo ""
    echo "=== Draft Card ($CARD_PATH) ==="
    echo ""
    echo "$CARD_CONTENT"
    echo ""
  } >&2

  echo -n "OK to write this Card? [Y/n]: " >&2
  read -r CONFIRM || CONFIRM=""
  CONFIRM_LC="$(echo "$CONFIRM" | tr '[:upper:]' '[:lower:]')"
  case "$CONFIRM_LC" in
    n|no)
      echo "Aborted. Card not written." >&2
      CARD_WRITE=0
      ;;
    *)
      if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "[DRY RUN] would write $CARD_PATH" >&2
      else
        printf '%s' "$CARD_CONTENT" > "$CARD_PATH"
        echo "✓ Card written: $CARD_PATH" >&2
      fi
      ;;
  esac
fi

# --- Phase 4: federation registration ---------------------------------------

REPO_OWNER="$(gh repo view --json owner --jq .owner.login 2>/dev/null || echo "")"

echo "" >&2
echo "=== Federation registration ===" >&2

if [[ "$REPO_OWNER" == "LA3D-LLM-Agents" ]]; then
  echo "✓ Repo is in LA3D-LLM-Agents. The federation index will pick it up" >&2
  echo "  on the next daily rebuild (12:00 UTC) or via repository_dispatch" >&2
  echo "  if FEDERATION_DISPATCH_TOKEN is configured." >&2
else
  echo "Repo lives at ${REPO_OWNER:-<unknown>}/$REPO_NAME (not in LA3D-LLM-Agents)." >&2

  # Allowlist owner-check: warn UP-FRONT if owner isn't on the trusted list,
  # so user knows the topic add alone won't make them discoverable.
  REPO_OWNER_LC="$(echo "${REPO_OWNER:-}" | tr '[:upper:]' '[:lower:]')"
  OWNER_TRUSTED=0
  for trusted in $TRUSTED_TOPIC_OWNERS_LC; do
    [[ "$REPO_OWNER_LC" == "$trusted" ]] && { OWNER_TRUSTED=1; break; }
  done

  if [[ "$OWNER_TRUSTED" -eq 1 ]]; then
    echo "" >&2
    echo "Owner '$REPO_OWNER' IS on the federation's trusted-owners allowlist." >&2
    echo "Adding the 'nd-llm-wiki' topic will let the daily rebuild Action pick" >&2
    echo "up this repo (provided wiki/<repo>.wiki/Card_<repo>.md exists)." >&2
  else
    echo "" >&2
    echo "WARN: owner '${REPO_OWNER:-<unknown>}' is NOT on the federation's" >&2
    echo "      trusted-owners allowlist (LA3D-LLM-Agents, LA3D, crcresearch," >&2
    echo "      PaperAnalyticalDeviceND, chrissweet, charlesvardeman, psaboia)." >&2
    echo "" >&2
    echo "      Adding the 'nd-llm-wiki' topic will NOT make this repo appear" >&2
    echo "      in the federation index — topic-walk skips non-allowlisted owners." >&2
    echo "      To join: request membership in LA3D-LLM-Agents (or have an" >&2
    echo "      admin add your owner to the allowlist in la3d-llm-agents.github.io/" >&2
    echo "      scripts/build-index.py)." >&2
  fi
  echo "" >&2
  echo -n "Add 'nd-llm-wiki' topic to this repo now? [y/N]: " >&2
  read -r TOPIC_CONFIRM || TOPIC_CONFIRM=""
  TOPIC_LC="$(echo "$TOPIC_CONFIRM" | tr '[:upper:]' '[:lower:]')"
  case "$TOPIC_LC" in
    y|yes)
      if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "[DRY RUN] would run: gh repo edit --add-topic nd-llm-wiki" >&2
      else
        if gh repo edit --add-topic nd-llm-wiki 2>/dev/null; then
          if [[ "$OWNER_TRUSTED" -eq 1 ]]; then
            echo "✓ Topic 'nd-llm-wiki' added. Federation index will pick this up on next rebuild." >&2
          else
            echo "✓ Topic 'nd-llm-wiki' added — but per warning above, owner isn't on" >&2
            echo "  the allowlist so the topic alone won't make you appear in the index." >&2
          fi
        else
          echo "WARN: 'gh repo edit --add-topic' failed; add manually via the GitHub UI." >&2
        fi
      fi
      ;;
    *)
      echo "Skipped. To add later: gh repo edit --add-topic nd-llm-wiki" >&2
      ;;
  esac
fi

# --- Phase 5: next steps ----------------------------------------------------

{
  echo ""
  echo "=== Enrollment complete ==="
  echo ""
  echo "Next steps:"
  if [[ "$CARD_WRITE" -eq 1 ]] && [[ "$DRY_RUN" -eq 0 ]]; then
    echo "  • Commit the Card to the wiki sub-repo:"
    echo "      cd $WIKI_DIR"
    echo "      git add Card_${AGENT_NAME}.md"
    echo "      git commit -m \"Add agent Card via enroll.sh\""
    echo "      git push"
    echo ""
  fi
  echo "  • For richer Card content: edit the Card directly in your editor,"
  echo "      or use your LLM CLI's session in the wiki-sub-repo directory to"
  echo "      have it propose updates (e.g. \`cd $WIKI_DIR && claude\`)."
  echo "  • Test the federation:"
  echo "      bash scripts/agent-comms/ask.sh ${AGENT_NAME:-agent} \"what do you do?\""
} >&2

exit 0
