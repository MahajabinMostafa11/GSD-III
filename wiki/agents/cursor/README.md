# Cursor overlay for llm-wiki

Cursor-specific layer on top of the agent-agnostic llm-wiki core. Parallel to `wiki/agents/claude-code/`, both can be active in the same project.

> **⚠ Status: shipped but not yet validated in a live Cursor session.**
>
> Only the Claude Code overlay (`wiki/agents/claude-code/`) has been exercised end-to-end against a real agent. This overlay's `.cursor/rules/*.mdc` format, `@`-mention invocation, and `alwaysApply` / Agent Requested semantics are derived from Cursor's published documentation, not from observed behavior in a running Cursor IDE.
>
> If you are the first to try the Cursor path, please [open an issue](https://github.com/crcresearch/llm-wiki-memory-template/issues/new) reporting:
>
> - Cursor version (Cursor → About)
> - Whether `@wiki-experiment`, `@wiki-source`, `@wiki-lint` appear in the chat autocomplete
> - Whether the `wiki-as-memory.mdc` rule (alwaysApply) is being injected into the agent's prompt
> - Whether the agent honors the read/write/commit loop
> - Anything that does not match this README's "First-session walkthrough" further down
>
> Honest reports of failures are at least as useful as confirmations. The README content here is a hypothesis; your run is the test.

## What's here

| File | Purpose |
|---|---|
| `setup.sh` | Idempotent installer. Verifies the wiki and the `.cursor/rules/*.mdc` set. Never touches `CLAUDE.md`. |
| `templates/` | Reserved for future Cursor-specific template content. The `.cursor/rules/*.mdc` files ship directly at the project root, not under `templates/`, because Cursor reads them from there. |

The actual Cursor configuration lives at the project root:

| Location | Purpose |
|---|---|
| `.cursor/rules/wiki-as-memory.mdc` | `alwaysApply: true`. Codifies the read/write/commit loop for the wiki. Equivalent to `.claude/rules/wiki-as-memory.md` in the Claude Code overlay. |
| `.cursor/rules/memory-boundary.mdc` | `alwaysApply: true`. Where a fact belongs: agent memory vs the wiki. Equivalent to `.claude/rules/memory-boundary.md` in the Claude Code overlay. |
| `.cursor/rules/wiki-experiment.mdc` | Agent Requested. Procedure for filing an experiment result. Invoke explicitly with `@wiki-experiment` or let Cursor pull it in when intent matches. |
| `.cursor/rules/wiki-source.mdc` | Agent Requested. Procedure for ingesting a new source document. `@wiki-source`. |
| `.cursor/rules/wiki-lint.mdc` | Agent Requested. Procedure for health-checking the wiki. `@wiki-lint`. |

There is no single-file `.cursorrules` fallback: Cursor has read `.cursor/rules/*.mdc` since 0.45 (January 2025) and marks `.cursorrules` legacy, so the overlay ships only the `.mdc` form.

## Flags

| Flag | What it does |
|---|---|
| (none) | Base mode: wiki verification + rules check |
| `-h`, `--help` | Prints the script's header comment |

## Note on Cursor capabilities

Cursor has no SessionStart hook equivalent and no IDE-managed per-user memory directory, so the Claude Code overlay's `--hook` and `--seed-memory` flags have no analog here. The `wiki-as-memory.mdc` rule has `alwaysApply: true` so it is injected into every Cursor agent prompt for the project; that is the closest equivalent to the Claude Code SessionStart hook.

## Verify the install

```bash
ls .cursor/rules/                   # wiki-as-memory.mdc, memory-boundary.mdc, wiki-{experiment,source,lint}.mdc
```

## First-session walkthrough

Open Cursor in the project root, start a chat session, and try the following.

### 0. Sanity — `@`-mention autocomplete

In the Cursor chat, type `@wiki` and confirm the autocomplete offers `@wiki-experiment`, `@wiki-source`, `@wiki-lint`, `@wiki-as-memory`. If they don't appear, Cursor is not reading `.cursor/rules/`. Check the Cursor version: `.mdc` rules require 0.45 (January 2025) or later.

### 1. Read path — Query

Ask Cursor (in chat) a project-knowledge question without mentioning the wiki. Example: *"Summarize what we know about <topic central to the project>."*

**Expected:** the `wiki-as-memory` rule is always applied, so Cursor opens `index_{{REPO_NAME}}.md`, drills into named pages, and cites them. No `@` invocation needed.

### 2. Write path — Ingest with auto-commit

Tell Cursor about a new finding from a script run, with the result path or command. Example: *"My new run produced X = 42 on the Y benchmark. Record it in the wiki. Output is at `experiments/results/run-NNN.json`."*

**Expected:** Cursor pulls in `wiki-experiment` automatically (its description matches the intent), reads existing pages to integrate, writes a synthesis page, updates index and log, and runs `git -C wiki/{{REPO_NAME}}.wiki add ... && git -C ... commit -m "..."` without an approval prompt. If your number is not backed by a real script output, the honest-reporting rule should make Cursor refuse to file it and ask for the evidence.

### 3. Explicit invocation — `@wiki-experiment`

Same scenario, but type `@wiki-experiment` to force the procedure even if the description match is uncertain.

### 4. Lint — `@wiki-lint`

Type `@wiki-lint` and confirm Cursor scans the wiki, reports findings grouped by check type, and asks which to fix. Run this every few sessions or after a large ingest.

## What you've learned

| Trigger | When to use |
|---|---|
| `@wiki-experiment` | A run finished. File metrics, config, and the diff against prior runs. |
| `@wiki-source` | A new external document entered the project and you want it integrated. |
| `@wiki-lint` | Periodic health check. Every few sessions or after a large ingest. |
| *(default)* | The `wiki-as-memory` rule is always applied; Cursor proactively reads and writes without needing an `@` mention. |

## CLAUDE.md is yours

The overlay never creates or edits `CLAUDE.md`. All behavioral instructions ship as `.cursor/rules/*.mdc` files (the Claude Code overlay's parallel is `.claude/rules/*.md`). Note that Cursor also reads a project-root `CLAUDE.md` natively, so whatever you write there reaches Cursor too; the template just never touches it.

## Updating after pulling template improvements

When `scripts/update-from-template.sh` syncs improvements from the template repo, it refreshes the template-owned `.cursor/rules/*.mdc` files (those listed in `scripts/lib/template-manifest.sh`), `wiki/agents/cursor/setup.sh`, and `wiki/agents/cursor/templates/` (when present). It does not touch your own project-specific rules in `.cursor/rules/`.
