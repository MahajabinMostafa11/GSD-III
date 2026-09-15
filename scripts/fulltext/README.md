# Full-text store (`scripts/fulltext/`)

Papers/articles referenced by the wiki are often large PDFs and frequently
copyrighted — they do **not** belong in git. This toolkit keeps the wiki
text-only and stores the actual files in a **shared private Google Drive**,
linked back to each wiki page by a text pointer. rclone (Drive API) is the
storage backbone; an authenticated browser (institutional library access) is
used only to *acquire* paywalled PDFs, which are then handed to
`fulltext-add.sh --file`.

This toolkit is designed to be **identical across every disease-wiki project**
built from this pattern. They share one Drive account and one parent folder;
each project writes to its own subfolder — so future projects (e.g. a second
disease wiki) can adopt this unchanged.

## Drive layout (shared parent, one subfolder per project)

```
<RCLONE_REMOTE>:LLM-Wiki-FullText/          <- shared parent (FULLTEXT_ROOT)
  GSD-III/                                  <- this project's files
    <page-slug>.pdf
    fulltext-manifest.csv
  <Next-Disease-Project>/                   <- future projects land here automatically
```

The per-project subfolder label is **derived automatically** from the repo
directory name (e.g. a repo named `GSD-III` writes to `GSD-III/`; a repo
named `SomeDisease-Memory` would write to `SomeDisease/`), so `fulltext.env`
is the same in every project — you never edit a folder name by hand.

## How it fits together

- **Wiki page (git):** gains pointer fields in frontmatter — nothing binary.
  ```yaml
  source: "https://doi.org/10.1101/gad.1553207"   # already present
  fulltext: "gdrive:LLM-Wiki-FullText/GSD-III/Cheng-2007-AGL-Ubiquitination-Cori-Lafora.pdf"
  fulltext_url: "https://drive.google.com/file/d/<id>/view"   # opens only for people with folder access
  fulltext_sha256: "<hash>"
  fulltext_fetched: 2026-09-13
  fulltext_access: open-access      # open-access | nd-library | publisher
  fulltext_by: "<contributor name>" # whose Drive/auth this pointer resolves for
  ```
- **Google Drive (private):** the bytes, named by wiki page **slug**
  (`<slug>.pdf`), plus a per-project `fulltext-manifest.csv` (the index:
  `slug,doi,drive_file,share_url,sha256,bytes,fetched,access,source_url`).
- **Reconciliation:** `fulltext-status.sh` shows pages still missing a copy and
  manifest rows whose Drive file has gone missing.

## One-time setup (per machine)

1. **rclone binary** — ships at `scripts/fulltext/bin/rclone` (gitignored). To
   reinstall:
   ```bash
   brew install rclone
   ln -s $(which rclone) scripts/fulltext/bin/rclone
   ```
2. **Authorize Google Drive** (interactive, once per machine — shared by every
   project using this toolkit):
   ```bash
   scripts/fulltext/bin/rclone config
   #  n) new remote   →  name: gdrive   →  storage: drive
   #  leave client_id/secret blank (uses rclone's default)
   #  scope: 1  (full)  →  auto config: Y  (opens a browser; sign in with your account)
   #  configure as team drive? N   →  y) yes this is OK
   ```
   The OAuth token is saved to `~/.config/rclone/rclone.conf` (per-machine, not in git).
3. **Config file:**
   ```bash
   cp scripts/fulltext/fulltext.env.example scripts/fulltext/fulltext.env
   ```
   Then set:
   ```
   RCLONE_REMOTE=gdrive
   FULLTEXT_ROOT=LLM-Wiki-FullText
   ```
   This same file (unedited) can be copied verbatim into any future
   disease-wiki project — the subfolder always auto-derives from that
   project's own repo name.
4. **(optional) PDF text extraction** for `fulltext-get.sh`:
   ```bash
   .venv/bin/pip install pypdf
   ```

## Usage

```bash
# Store an open-access paper (auto-download):
scripts/fulltext/fulltext-add.sh Cheng-2007-AGL-Ubiquitination-Cori-Lafora \
  --url https://doi.org/10.1101/gad.1553207

# Store a paywalled paper you downloaded via institutional library access in your browser:
scripts/fulltext/fulltext-add.sh Some-Paywalled-Paper-2024 --file ~/Downloads/paper.pdf --access nd-library

# Pull a stored paper down to read it (extracts text if PDF):
scripts/fulltext/fulltext-get.sh Cheng-2007-AGL-Ubiquitination-Cori-Lafora   # -> .fulltext-cache/<slug>.pdf + .txt

# See what's stored vs missing:
scripts/fulltext/fulltext-status.sh

# Backfill every paper page that still lacks full text (auto-fetch, paywalled reported):
scripts/fulltext/fulltext-backfill.sh           # add --dry-run to preview first

# Capture web-article pages (news/gov/org, no PDF) as text snapshots:
scripts/fulltext/fulltext-webcapture.sh         # add --dry-run to preview first
```

`--access` must be one of `open-access`, `nd-library`, `publisher` (validated).
After `fulltext-add.sh`, commit the wiki page (the pointer); push the wiki.
The PDF itself never enters git.

## Acquisition & copyright policy

- **Scope — three source classes** (`source_kind` in `lib.sh`):
  - **paper** — a citable PDF (DOI / PMID / academic-publisher). Fetched by
    `fulltext-add` / `fulltext-backfill` and stored as `<slug>.pdf`.
  - **tool** — a software tool whose `source:` is a code repo or docs site. The
    curated wiki page is the reference; **no full text**, and not a gap.
  - **web** — a news / gov / general-org web article (no PDF). Captured as a text
    snapshot `<slug>.txt` by `fulltext-webcapture.sh` (`fulltext_access: web`);
    counted separately, **not** a paper gap.
  A citable source (DOI/PMID/.pdf) always wins, so a tool or news page that also
  has a DOI is treated as a paper.
- **Open access** (PMC, bioRxiv, medRxiv, CC-BY journals): auto-download
  with `--url` is fine; mark `--access open-access`.
- **Paywalled:** fetch through your **institutional library access in an
  authenticated browser**, then `--file` it in with `--access nd-library` (or
  `publisher`). The toolkit does **not** scrape paywalled PDFs headlessly.
- Keep the Drive folder **private** — this is a personal/institutional
  research-use cache, not redistribution. `fulltext_access` records provenance so
  CC-BY (shareable) is distinguishable from publisher-PDF (personal use only).
- `fulltext_url` is built from the Drive file ID and respects the folder's
  existing permissions; it does **not** make the file public.

## Contributor-local pointers

`fulltext`/`fulltext_url` values resolve only for the contributor whose Drive +
authentication they reference (recorded in `fulltext_by`). The portable,
machine-independent re-acquisition key is the page's `source:` (DOI/URL/PMID).
Another contributor keeps their own store (or omits the `fulltext_*` fields);
they should not expect someone else's `fulltext_*` to work. Never commit PDFs,
the rclone binary, `fulltext.env`, or the `.fulltext-cache/` to git.