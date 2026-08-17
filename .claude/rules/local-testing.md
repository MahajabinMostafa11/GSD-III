# Running the test harness locally

Full usage is documented in `scripts/test/README.md`; these are the rules that prevent spurious failures.

## Test harness

Run `./scripts/test/run.sh` with no template-source env vars.
The default exports this working tree's git-visible files into the sandbox, which keeps gitignored artifacts (the dogfooded `wiki/<template>.wiki/`, kg build caches) out.
Never set `MVP_TEMPLATE_LOCAL` to a working tree that contains such artifacts: that path copies the directory verbatim and the smoke tests fail with `init-wiki.sh` "multiple wikis ... name is ambiguous".
`MVP_TEMPLATE_LOCAL` is for clean checkouts, which is how CI uses it.

The `kg-frontmatter-graph` unit test requires the Python modules `yaml`, `rdflib`, and `pyshacl`, and fails rather than skips when they are missing.
Either install them as CI does (venv, see `.github/workflows/test-harness.yml`) or supply them ephemerally:

```bash
uv run --no-project --with pyyaml --with rdflib --with pyshacl -- ./scripts/test/run.sh
```

## Running the CI workflow with act

```bash
act -j test --matrix os:ubuntu-latest --rm
```

Keep act's default copy mode; never pass `-b`/`--bind`.
Bind mode mounts the real working tree, so workflow writes land on the host (root-owned `scripts/kg/build/` and `scripts/kg/.cache/` under rootful Docker) and gitignored artifacts reach `MVP_TEMPLATE_LOCAL=$GITHUB_WORKSPACE`, causing the "multiple wikis" failures above.
Copy mode respects `.gitignore`, so the container sees the equivalent of a clean checkout and all writes stay inside it.
The `macos-latest` matrix leg cannot run under act; filter it out with `--matrix os:ubuntu-latest`.
