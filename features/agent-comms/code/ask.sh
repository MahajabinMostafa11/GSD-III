#!/usr/bin/env bash
# ask.sh — federation discovery + clone-and-invoke.
#
# Modes (distinguished by arg count):
#   ask.sh "<question>"             discovery mode (1-arg)
#   ask.sh <agent> "<question>"     direct mode (2-arg)
#
# Discovery mode: fetch federation index, show candidate table, user picks,
# clone-and-invoke each pick.
#
# Direct mode: skip the picker. Resolve <agent> against the federation
# index (matching id, owner_repo, or repo basename), then clone-and-invoke
# that single agent.
#
# Testability env vars:
#   LLM_CLI               default: claude -p
#   FEDERATION_INDEX_URL  default: https://la3d-llm-agents.github.io/index.json
#   LLM_AGENTS_DIR        default: $HOME/.llm-agents
#                         clone cache goes to $LLM_AGENTS_DIR/wikis-cache/.
#                         Back-compat: legacy MAILBOX_DIR also honored.
#
# Exit codes:
#   0  success (including user-aborted selection)
#   1  fatal: missing required command, network failure, etc.
#   2  usage error
#   5  question is empty
#   6  invalid selection (discovery mode)
#   7  agent not found (direct mode)
#   8  agent query ambiguous (direct mode, multiple matches at one tier)
set -euo pipefail

LLM_CLI="${LLM_CLI:-claude -p}"
FEDERATION_INDEX_URL="${FEDERATION_INDEX_URL:-https://la3d-llm-agents.github.io/index.json}"
# Substrate dir. Env var name follows the agent-comms convention; back-compat
# fallback honors the legacy MAILBOX_DIR (used before v0.1.0 scope was set).
LLM_AGENTS_DIR="${LLM_AGENTS_DIR:-${MAILBOX_DIR:-$HOME/.llm-agents}}"

usage() {
  cat <<EOF
Usage:
  ask.sh "<question>"              discovery mode: federation + user-picks
  ask.sh <agent-id> "<question>"   direct mode: skip discovery
  ask.sh -h | --help               this help

Direct mode matches <agent-id> against the federation index by, in order:
  1. exact id            (e.g. chrissweet/agent-comms)
  2. exact owner_repo    (e.g. LA3D-LLM-Agents/agent-comms)
  3. repo basename       (e.g. agent-comms — last slash segment)

Env vars (testability hooks):
  LLM_CLI               default: claude -p
  FEDERATION_INDEX_URL  default: https://la3d-llm-agents.github.io/index.json
  LLM_AGENTS_DIR        default: \$HOME/.llm-agents
                        (back-compat: MAILBOX_DIR also honored if set)

Examples:
  ask.sh "what does chrissweet/agent-comms do?"                  # discovery
  ask.sh chrissweet/agent-comms "follow up: how does X work?"    # direct, full id
  ask.sh agent-comms "follow up"                                 # direct, basename
EOF
}

die() { echo "ERROR: $*" >&2; exit 1; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || die "$1 not found on PATH"; }

# --- Shared helpers ----------------------------------------------------------

# Echo the federation index JSON. Dies on fetch failure.
fetch_index() {
  curl -sLf "$FEDERATION_INDEX_URL" \
    || die "failed to fetch federation index from $FEDERATION_INDEX_URL"
}

# Resolve an agent query against the index. Tiered matching:
# 1. exact id, 2. exact owner_repo, 3. repo basename. A tier returns
# exactly one match -> echo that JSON; multiple at one tier -> exit 8;
# no matches at any tier -> exit 7 with the list of available agents.
resolve_agent() {
  local index="$1" query="$2"
  local matches n

  for jq_filter in \
      '[.agents[] | select(.id == $q)]' \
      '[.agents[] | select(.owner_repo == $q)]' \
      '[.agents[] | select((.owner_repo // "" | split("/") | .[-1]) == $q)]'
  do
    matches=$(jq -c --arg q "$query" "$jq_filter" <<<"$index")
    n=$(jq 'length' <<<"$matches")
    if [[ "$n" -eq 1 ]]; then
      jq -c '.[0]' <<<"$matches"
      return 0
    elif [[ "$n" -gt 1 ]]; then
      echo "ERROR: query '$query' matches multiple agents:" >&2
      jq -r '.[] | "  - " + .id + " (" + .owner_repo + ")"' <<<"$matches" >&2
      exit 8
    fi
  done

  echo "ERROR: agent '$query' not found in federation index." >&2
  echo "Available agents:" >&2
  jq -r '.agents[] | "  - " + .id + " (" + .owner_repo + ")"' <<<"$index" >&2
  exit 7
}

# Ensure <owner_repo>'s wiki is cached at $LLM_AGENTS_DIR/wikis-cache/<owner_repo>/.
# On success, echo the local path. On clone failure, return 1 (caller skips).
clone_or_pull() {
  local owner_repo="$1" wiki_url="$2"
  local target="$LLM_AGENTS_DIR/wikis-cache/$owner_repo"

  if [[ -d "$target/.git" ]]; then
    git -C "$target" pull --ff-only --quiet 2>/dev/null \
      || echo "WARN: pull failed for $owner_repo; using cached copy" >&2
  else
    mkdir -p "$(dirname "$target")"
    if ! git clone --depth 1 --quiet "$wiki_url" "$target" 2>/dev/null; then
      echo "SKIP: clone failed for $wiki_url" >&2
      return 1
    fi
  fi

  echo "$target"
}

# Invoke $LLM_CLI in <target> with <question>. Word-splits LLM_CLI so
# "claude -p" becomes argv [claude, -p].
invoke_llm() {
  local target="$1" question="$2"
  local llm_cmd preamble
  read -ra llm_cmd <<<"$LLM_CLI"
  # Grounded in the wiki SCHEMA's Query procedure (index -> pages -> synthesize).
  preamble="You are answering a question from a project's llm-wiki, a cross-linked \
Markdown knowledge base. Follow its Query procedure: read index_*.md to find the \
relevant pages, read those pages, and synthesize an answer. Cite the page names you \
draw from. Defer to SCHEMA_*.md for the wiki's conventions. This is a read-only \
consultation: do not modify files."
  ( cd "$target" && "${llm_cmd[@]}" "$preamble"$'\n\n'"Question: $question" )
}

# Header + clone + invoke for one agent. Per-agent failures are isolated
# (printed, but do not kill the script — important for discovery mode's loop).
ask_one() {
  local agent_json="$1" question="$2"
  local id owner_repo wiki_url target
  id=$(jq -r '.id'                         <<<"$agent_json")
  owner_repo=$(jq -r '.owner_repo // ""'   <<<"$agent_json")
  wiki_url=$(jq -r '.wiki_clone_url // ""' <<<"$agent_json")

  echo ""
  echo "=== $id ==="

  if [[ -z "$owner_repo" || -z "$wiki_url" ]]; then
    echo "SKIP: index entry missing owner_repo or wiki_clone_url" >&2
    return
  fi

  if ! target=$(clone_or_pull "$owner_repo" "$wiki_url"); then
    return
  fi

  invoke_llm "$target" "$question" \
    || echo "(LLM CLI '$LLM_CLI' failed for $id; no answer)" >&2
}

# --- Argument dispatch ------------------------------------------------------

if [[ $# -eq 0 ]]; then
  usage >&2
  exit 2
fi

case "$1" in
  -h|--help) usage; exit 0 ;;
esac

if [[ $# -gt 2 ]]; then
  echo "ERROR: too many arguments" >&2
  usage >&2
  exit 2
fi

# --- Direct mode (2 args) ---------------------------------------------------

if [[ $# -eq 2 ]]; then
  AGENT_QUERY="$1"
  QUESTION="$2"

  if [[ -z "${QUESTION//[[:space:]]/}" ]]; then
    echo "ERROR: question is empty" >&2
    exit 5
  fi

  require_cmd curl
  require_cmd jq
  require_cmd git

  INDEX_JSON=$(fetch_index)
  AGENT_JSON=$(resolve_agent "$INDEX_JSON" "$AGENT_QUERY")
  ask_one "$AGENT_JSON" "$QUESTION"
  exit 0
fi

# --- Discovery mode (1 arg) -------------------------------------------------

QUESTION="$1"
if [[ -z "${QUESTION//[[:space:]]/}" ]]; then
  echo "ERROR: question is empty" >&2
  exit 5
fi

require_cmd curl
require_cmd jq
require_cmd git

INDEX_JSON=$(fetch_index)

N_AGENTS=$(jq -r '.agents | length' <<<"$INDEX_JSON")
if [[ "$N_AGENTS" -eq 0 ]]; then
  echo "No agents in federation index. Nothing to ask." >&2
  exit 0
fi

{
  echo ""
  echo "Federation index ($FEDERATION_INDEX_URL): $N_AGENTS agent(s)"
  echo ""
  jq -r '.agents | to_entries[] |
         "  \(.key + 1)) \(.value.id)\n" +
         "     \(.value.description // "(no description)")\n" +
         "     topics: \(.value.topics // [] | join(", "))\n"' <<<"$INDEX_JSON"
} >&2

echo -n "Pick agents to ask (e.g. \"1\", \"1,2\", \"all\", \"none\"): " >&2
read -r SELECTION || SELECTION=""

NORM="$(echo "$SELECTION" | tr 'A-Z' 'a-z' | tr -d '[:space:]')"
case "$NORM" in
  ""|n|none|q|quit)
    echo "No selection. Nothing asked." >&2
    exit 0
    ;;
  a|all)
    PICKS=$(seq 1 "$N_AGENTS")
    ;;
  *)
    PICKS=$(echo "$SELECTION" | tr ',' ' ' | tr -s '[:space:]' ' ' | tr ' ' '\n' | grep -v '^$' || true)
    ;;
esac

for p in $PICKS; do
  if ! [[ "$p" =~ ^[0-9]+$ ]] || [[ "$p" -lt 1 || "$p" -gt "$N_AGENTS" ]]; then
    echo "ERROR: invalid pick '$p' (must be integer in 1..$N_AGENTS)" >&2
    exit 6
  fi
done

for p in $PICKS; do
  idx=$((p - 1))
  AGENT_JSON=$(jq -c ".agents[$idx]" <<<"$INDEX_JSON")
  ask_one "$AGENT_JSON" "$QUESTION"
done
