# GSD-III

A knowledge base tracking glycogen storage disease type III (GSD III)- an autosomal recessive glycogen storage disorder caused by deficiency of the glycogen debranching enzyme (AGL). Covers molecular genetics, clinical manifestations (hepatic, cardiac, myopathic), and treatment literature.

<!--
  This README was generated from README.md.template by
  scripts/instantiate.sh when the project was created from
  crcresearch/llm-wiki-memory-template. Placeholders substituted at
  instantiation time:
    GSD-III   Human-readable project name.
    GSD-III      Repository slug (used for the wiki path).
    MahajabinMostafa11          GitHub owner / org (derived from origin URL).
    One sentence about this disease project    Project description; default text below until edited.

  Edit this file freely once the project is up. The structure below is a
  suggestion, not a requirement; sections "This repository uses LLM wiki
  memory", "Quick start for collaborators", and "About the template" are
  what make this project legible to future contributors and to any AI
  coding assistant they bring along, so consider keeping them.
-->

## This repository uses LLM wiki memory

GSD-III keeps a persistent, LLM-maintained knowledge base under `wiki/GSD-III.wiki/` (a separate git repo), following the [llm-wiki pattern](https://github.com/tobi/llm-wiki). It is the project's durable memory: findings, decisions, experiment results, and intermediate insights belong in the wiki and accumulate over time. Three operations, **Query** (read it), **Ingest** (write to it), and **Lint** (health-check it), are codified in `wiki/GSD-III.wiki/SCHEMA_GSD-III.md`, in the `.claude/rules/` files, and in the `.claude/skills/` skills (`/wiki-source`, `/wiki-experiment`, `/wiki-lint`).

See also [llm-wiki.md](llm-wiki.md) in this repo for the underlying pattern.

## Quick start for collaborators

New to GSD-III? Clone the project repo, clone the wiki as a sibling sub-repo, then seed your local Claude Code memory:

```bash
git clone https://github.com/MahajabinMostafa11/GSD-III.git
cd GSD-III
[ -d wiki/GSD-III.wiki ] || \
    git clone https://github.com/MahajabinMostafa11/GSD-III.wiki.git wiki/GSD-III.wiki
./wiki/agents/claude-code/setup.sh --seed-memory
```

The wiki clone is guarded with `[ -d … ] ||` because the Claude Code overlay's `SessionStart` hook (`ensure-wiki.py`, installed by `setup.sh --hook`) auto-clones the wiki on first session start. If you opened Claude Code before running these commands, the wiki is already in place and the inner `git clone` is a no-op; teammates on other agents (or no agent) still get the clone as before.

After this, open Claude Code inside the repo. It will automatically pick up the project's slash commands (`/wiki-source` to ingest an external document, `/wiki-experiment` to file experiment results, `/wiki-lint` to health-check the wiki) along with the read/write/commit conventions in `.claude/rules/`.

The wiki at `wiki/GSD-III.wiki/` is a separate git repo with its own history and its own remote. After any wiki edit, commit in the wiki repo (not the project repo):

```bash
git -C wiki/GSD-III.wiki add <files>
git -C wiki/GSD-III.wiki commit -m "..."
```

Push the wiki only when you intend to publish the changes:

```bash
git -C wiki/GSD-III.wiki push origin master
```

## About the template

This project was instantiated from [crcresearch/llm-wiki-memory-template](https://github.com/crcresearch/llm-wiki-memory-template). Maintainers who need to pull template updates, add a new agent overlay (Cursor, OpenCode, etc.), or understand the instantiate/update scripts should read the template repo's documentation.
