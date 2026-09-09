---
name: ontology-binding
description: Add or check ontology_id/ontology_label frontmatter on wiki entity pages. Use whenever a page describes a disease, phenotype, gene, or other ontology-indexed entity — including during /wiki-source ingestion when a new entity page is created.
---

# Ontology Binding Skill

## Overview

Wiki entity pages describing a disease, phenotype, gene, or similar concept can
carry an `ontology_id` / `ontology_label` / `ontology_xrefs` frontmatter block
(see `SCHEMA_GSD-III.md`, "Optional ontology binding"). This skill exists so
that block is populated by a reproducible lookup, never typed from memory.

## When to use

- Creating a new `type: entity` page for a disease, phenotype, gene, or other
  ontology-indexed concept (including during `/wiki-source` ingestion).
- Adding an ontology binding to an existing entity page that lacks one.
- Re-checking an existing `ontology_id` / `ontology_label` pair on request.

## Rule

**Never hand-type an `ontology_id` or `ontology_label`.** Always call
`scripts/kg/lookup-ontology-term.py` and use its output verbatim. If the
script returns no result, leave the ontology fields off the page rather than
guessing — a missing binding is recoverable later; a wrong one silently
corrupts the knowledge graph.

## How to look up a term

```bash
python3 scripts/kg/lookup-ontology-term.py lookup --prefix <prefix> --query "<term>" --exact
```

Common prefixes: `mondo` (disease), `hp` (human phenotype), `go` (biological
process), `uberon` (anatomy), `cl` (cell type), `ncit` (treatment/procedure).

Drop `--exact` for a broader/fuzzy search if the exact match returns nothing —
then review the candidates and pick the one that actually matches the
concept; do not pick the first result blindly.

## Writing the result into frontmatter

Use the script's output exactly as returned:

```yaml
ontology_id: MONDO:0009291
ontology_label: glycogen storage disease III
```

If the script's result includes cross-references (xrefs), add them too:

```yaml
ontology_xrefs: [OMIM:232400, MESH:D006010, Orphanet:366]
```

If it doesn't return xrefs, omit `ontology_xrefs` — don't fabricate values.

## Subtype / granularity caution

Some diseases have clinical subtypes (e.g. GSD-III's IIIa/IIIb/IIIc/IIId) that
do **not** necessarily have their own ontology term — check with the lookup
script before assuming a subtype has a distinct ID. If the script returns
nothing for the subtype-specific query, don't force a binding; note in the
page body that the subtype is distinguished clinically/genetically rather
than by a separate ontology term, and bind only the parent disease.

## Failure modes to avoid

- **Guessing an ID because it "looks right."** If you recall an ID from
  training data, treat that as a hypothesis to verify with the script, not
  as ground truth.
- **Reusing an ID from a similar-sounding page** without re-running the
  lookup for the current page's specific term.
- **Silently dropping `ontology_label`** when `ontology_id` is present, or
  vice versa — they're always added together, straight from one script
  call's output.
