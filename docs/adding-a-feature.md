# Adding a feature

This document is the canonical guide for authoring a new opt-in feature
in `llm-wiki-memory-template`. It covers the `feature.json` schema, the
install/uninstall lifecycle, a walkthrough, and the pitfalls worth
flagging up front.

If you have not read it yet, start with the rationale in RFC #13 and the
short overview in [`../features/README.md`](../features/README.md).

## What a feature is

A feature is a self-contained extension that a derived project can
choose to enable, independently of the base template. Examples (none
shipped yet in the template, all candidates for future PRs):

- a knowledge-graph pipeline that rebuilds RDF from wiki frontmatter
- a Socratic tutor behavior overlay (issue #7)
- agent-memory tooling that lets sessions read/write claims via SPARQL

A feature is the right shape when:

- the capability is **optional**: not every derived project wants it
- the capability is **substantial**: ships code, may have its own CI,
  installs a rule file to teach the agent how to use it
- the capability is **removable**: a project may turn it off later
  without leaving wreckage behind

If a thing is needed by every project unconditionally, it belongs in
the base template, not in `features/`.

## Directory layout

```
features/<name>/
├── feature.json          required: metadata
├── rule.md               optional: agent context, installed as a .claude/rules/ file
├── code/                 optional: copied into scripts/<name>/
├── tests/                optional: copied into scripts/test/tests/...
├── fixtures/             optional: test data your tests reference
└── ci/
    └── test-<name>.yml   optional: GitHub Actions workflow
```

Only `feature.json` is required. Each of the other pieces is processed
if (and only if) declared in `feature.json`.

## The `feature.json` schema

```json
{
  "name": "your-feature",
  "version": "0.0.1",
  "description": "One sentence on what this feature gives a derived project.",
  "status": "experimental",

  "files":     { "source": "code/",      "destination": "scripts/your-feature/" },
  "tests":     { "source": "tests/",     "destination": "scripts/test/tests/unit/your-feature/" },
  "ci":        { "workflow_file": "ci/test-your-feature.yml" },
  "rule":      { "source": "rule.md" },

  "system_deps": [
    {
      "name": "jq",
      "version": ">=1.6",
      "install": {
        "ubuntu": "sudo apt-get install jq",
        "macos":  "brew install jq"
      }
    }
  ],

  "depends_on": []
}
```

Field reference:

| Field | Required | Meaning |
|---|---|---|
| `name` | yes | Must match the directory name under `features/`. |
| `version` | yes | Free-form string (semver suggested but not enforced). |
| `description` | yes | One sentence. Shown by `enable-feature.sh --list`. |
| `status` | yes | One of `experimental`, `stable`, `deprecated`. Free-form for now; meant to set expectations. |
| `files.source` / `files.destination` | optional | Copy a directory of code from the feature into the derived project. Refuses to overwrite an existing destination. |
| `tests.source` / `tests.destination` | optional | Same shape as `files`, for harness tests. Skipped silently if the source directory does not exist. |
| `ci.workflow_file` | optional | Path to a YAML file under the feature directory. Copied into `.github/workflows/` at install time. Use one workflow per feature, do not patch the template's main workflow. |
| `rule.source` | optional | Prose file copied to `.claude/rules/feature-<name>.md` at install time. Conventionally `rule.md`. Skipped loudly when the project has no `.claude/` directory. |
| `system_deps[]` | optional | Each entry has `name`, `version`, and an `install` object with `ubuntu`, `macos`, or `manual` keys. Printed at install time, never executed. |
| `depends_on[]` | optional | Declared but **not enforced** in Etapa 1. Add it for documentation; future versions may validate. |

## The two entry points

A derived project enables a feature in one of two ways. Both call the
same `install_feature` function in `scripts/lib/install-feature.sh`.

**Declarative (at instantiation):**

```bash
./scripts/instantiate.sh "Project Name" --agent=claude-code --features=your-feature
```

`--features=` accepts a comma-separated list: `--features=kg,socratic-tutor`.
Fail-fast: if any named feature does not exist, instantiation aborts
before bootstrap so the project is never left half-built.

**Retroactive (any time later):**

```bash
./scripts/enable-feature.sh your-feature
./scripts/enable-feature.sh --list      # show available + enabled
```

**Removal:**

```bash
./scripts/disable-feature.sh your-feature
```

## What `install_feature` does, step by step

For a feature named `<name>` with `feature.json` declaring every
optional field, install runs six steps in order:

1. **Copy code.** `cp -R features/<name>/<files.source>` to
   `<files.destination>`. Refuses to overwrite.
2. **Copy tests.** Same pattern, scoped to the harness layout.
3. **Copy CI workflow.** `cp features/<name>/<ci.workflow_file>` to
   `.github/workflows/`.
4. **Install the rule file.** Copies `features/<name>/<rule.source>` to
   `.claude/rules/feature-<name>.md`. The host's `CLAUDE.md` is never
   touched. If the project has no `.claude/` directory (e.g.
   `--agent=none`), the step skips loudly and points at the source file
   instead of creating `.claude/` behind the user's back.
5. **Record.** Append `<name>` to `.features-enabled` at the project
   root.
6. **Print `system_deps`.** Lists each dependency with the matching
   install command for the host OS. **Never executes** them; the user
   installs system deps themselves.

Idempotency: install is a no-op if `<name>` is already in
`.features-enabled` (skips with a message). The rule install also
skips if the destination file is already present.

## What `uninstall_feature` does

Symmetric removal:

1. Remove `<files.destination>`.
2. Remove `<tests.destination>`.
3. Remove `.github/workflows/<ci.workflow_file basename>`.
4. Remove `.claude/rules/feature-<name>.md`, and the `.claude/rules/`
   directory too if the feature's rule was the only thing in it.
5. Remove `<name>` from `.features-enabled`. If the file becomes empty,
   it is deleted.

Uninstall is itself idempotent: re-running on a non-enabled feature is
a no-op with a friendly message.

If `feature.json` has been deleted from `features/<name>/` since
install (rare, but possible if the template was updated mid-stream),
uninstall does minimal cleanup: removes the rule file and the
`.features-enabled` entry (both derivable from the name alone), and
warns that the remaining installed files need manual cleanup.

## The rule.md conventions

The rule file is plain Markdown, copied verbatim to
`.claude/rules/feature-<name>.md`. Two practical guidelines:

- **It is a standalone document.** Start with a `#` title; it does not
  nest inside anything else.
- **Tell the agent how to use the feature, not how the feature was
  built.** Implementation details belong in the feature's own README
  or in `code/`. This file shapes session behavior.

Example minimal rule (`features/kg/rule.md`):

```markdown
# Knowledge Graph

The wiki's frontmatter feeds a knowledge graph at
`scripts/kg/`. Rebuild after edits with `./scripts/kg/build-graph.sh`.
Query the SPARQL endpoint at `http://localhost:3030/wiki/sparql` when
Fuseki is running.
```

## The CI workflow conventions

One workflow file per feature, named `test-<name>.yml`. Scope its
triggers narrowly so the feature's CI does not run on every PR:

```yaml
on:
  push:
    paths:
      - 'features/your-feature/**'
      - 'scripts/your-feature/**'
  pull_request:
    paths:
      - 'features/your-feature/**'
      - 'scripts/your-feature/**'
```

Do **not** modify the template's main `test-harness.yml`. Each feature
ships its workflow as a separate file so enabling or disabling a
feature does not require YAML surgery on shared infra.

## Writing tests for your feature

The template uses a small bash harness under `scripts/test/`. A
feature's tests live in its own subtree and are copied into the
derived project at install time:

```
features/your-feature/tests/
├── unit/
│   └── your-feature-thing/
│       ├── patch.sh        sets up sandbox state
│       └── assertions.sh   the actual asserts
└── integration/
    └── ...
```

The harness contract:

- `patch.sh` runs in a subshell with `$SANDBOX` set to a tmpdir. Make
  whatever fixture state your assertions need under `$SANDBOX`.
- `assertions.sh` is **sourced**, not invoked. Use `assert` and
  `assert_eq` from `scripts/test/lib/assertions.sh`. Path-relative
  navigation in a sourced file: `$HERE` resolves to
  `scripts/test/`, not your test directory.
- Both should be idempotent. The harness re-runs them on every CI run
  and on every local invocation.

Run the harness locally with:

```bash
MVP_TEMPLATE_LOCAL=$(pwd) ./scripts/test/run.sh
```

The `MVP_TEMPLATE_LOCAL` env var matters: the smoke test
`template-bootstrap` clones a template repo to verify bootstrap, and
without this var it clones the canonical default which may not yet
include your in-progress changes.

## Walkthrough: a hello-world feature

This walkthrough builds a feature called `hello-world` that prints a
greeting from a shell script. It exercises every machine path
(`feature.json`, files, rule file, CI, system_deps).

**1. Create the directory.**

```bash
mkdir -p features/hello-world/{code,ci}
```

**2. Write the code.**

```bash
cat > features/hello-world/code/greet.sh <<'EOF'
#!/usr/bin/env bash
echo "Hello from the hello-world feature."
EOF
chmod +x features/hello-world/code/greet.sh
```

**3. Write the rule file.**

```bash
cat > features/hello-world/rule.md <<'EOF'
# Hello World

This project has the hello-world feature enabled. Run
`./scripts/hello-world/greet.sh` to see the greeting.
EOF
```

**4. Write the CI workflow.**

```bash
cat > features/hello-world/ci/test-hello-world.yml <<'EOF'
name: hello-world

on:
  push:
    paths:
      - 'features/hello-world/**'
      - 'scripts/hello-world/**'
  pull_request:
    paths:
      - 'features/hello-world/**'
      - 'scripts/hello-world/**'

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Run the greeting
        run: ./scripts/hello-world/greet.sh
EOF
```

**5. Write `feature.json`.**

```bash
cat > features/hello-world/feature.json <<'EOF'
{
  "name": "hello-world",
  "version": "0.1.0",
  "description": "Minimal feature that prints a greeting.",
  "status": "experimental",

  "files":     { "source": "code/", "destination": "scripts/hello-world/" },
  "ci":        { "workflow_file": "ci/test-hello-world.yml" },
  "rule":      { "source": "rule.md" },

  "system_deps": [],
  "depends_on": []
}
EOF
```

**6. Try it in a derived project.** From a fresh derived project
(a tempdir with `git archive` of the template plus a one-time
`./scripts/instantiate.sh "Test" --agent=none` works fine), run:

```bash
./scripts/enable-feature.sh hello-world
./scripts/hello-world/greet.sh
cat .claude/rules/feature-hello-world.md
```

Expected: the greeting prints, and the rule file shows the content.

**7. Remove it cleanly.**

```bash
./scripts/disable-feature.sh hello-world
ls scripts/hello-world 2>&1                        # not found
ls .claude/rules/feature-hello-world.md 2>&1       # not found
cat .features-enabled 2>&1                         # absent or empty
```

## Pitfalls

- **The rule step needs a `.claude/` directory.** A project
  instantiated with `--agent=none` has none, so the rule install skips
  with a message pointing at the source file. The rest of the install
  proceeds normally.
- **`FEATURES_DIR` env var is test-only.** It exists so the unit test
  can point at a fixture outside `features/`. Derived projects must
  not set it; production reads `./features/` relative to cwd.
- **`jq` is required on the host.** It is not a per-feature
  system_dep; it is a template-wide requirement because
  `install-feature.sh` itself parses JSON.
- **Refuses to overwrite.** If the destination of `files` or `tests`
  already exists, install errors out. This is deliberate: silently
  clobbering a derived project's local edits is worse than failing
  loud. Resolve the conflict yourself, then re-run.
- **`depends_on` is declarative only.** The Etapa 1 install logic does
  not check or enforce dependencies. List them anyway for the next
  human; future enforcement may use the field.
- **One CI workflow per feature.** Do not patch
  `.github/workflows/test-harness.yml`. Workflow-per-feature lets
  enable/disable stay symmetric.

## Lifecycle: what the user sees

Install (declarative or retroactive) prints each step it takes, then a
final "Feature '<name>' installed." line. It also prints
`system_deps` install instructions for the host OS, with an explicit
note that nothing was executed automatically.

Uninstall prints each removal step and ends with "Feature '<name>'
uninstalled."

Both refuse to operate on unknown feature names, listing available
features in the error message. `enable-feature.sh --list` shows the
same list annotated with `[available]` or `[enabled]`.

`.features-enabled` is the source of truth for "what is on in this
project." It is plain text, one name per line, safe to read and edit
by hand if necessary (though prefer the scripts).

## What is NOT in scope of a feature

- **Base-template files.** Do not ship modified versions of
  `scripts/instantiate.sh`, `scripts/update-from-template.sh`, or the
  `wiki/` core. A feature extends; it does not fork.
- **The wiki sub-repo.** `wiki/<repo>.wiki/` is the derived project's
  content. Features do not write into it. Features can prompt the
  agent to update the wiki via `rule.md`, but they do not
  ship wiki pages.
- **Project-specific configuration.** A feature is for code and
  conventions that any derived project might want. Anything specific
  to one project belongs in that project's own scripts, not in
  `features/`.

## Still out of scope (post-Etapa 1)

These are deliberately deferred and tracked as future Etapas in
RFC #13:

- **Etapa 3:** `update-from-template.sh` does not yet read
  `.features-enabled` to sync per-feature code on template updates.
  When the template's `features/<name>/code/` changes, derived
  projects must manually re-run `disable-feature.sh` + `enable-feature.sh`
  for that feature.
- **Etapa 4:** No `migrate-to-feature-flags.sh` exists yet. Projects
  derived before the feature-flag architecture landed (pre-PR #17)
  must adopt features by hand, not via migration.
- **`depends_on` enforcement.** See the schema note above.
