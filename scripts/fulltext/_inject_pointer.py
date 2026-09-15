#!/usr/bin/env python3
"""Idempotently set fulltext_* pointer fields in a wiki page's YAML frontmatter.

Usage:
  _inject_pointer.py <page.md> key=value [key=value ...]

Only touches the frontmatter block (between the first two `---` lines). Removes
any existing fulltext* keys, then inserts the given ones immediately after the
`source:` line (or at the end of the frontmatter if there's no source:). All
other content, ordering, and comments are preserved. Stdlib only.
"""
import sys, pathlib

def main():
    if len(sys.argv) < 3:
        sys.exit("usage: _inject_pointer.py <page.md> key=value ...")
    path = pathlib.Path(sys.argv[1])
    pairs = []
    for arg in sys.argv[2:]:
        k, _, v = arg.partition("=")
        pairs.append((k.strip(), v))
    lines = path.read_text().splitlines()
    if not lines or lines[0].strip() != "---":
        sys.exit(f"{path}: no YAML frontmatter (must start with ---)")
    # find closing --- of frontmatter
    end = None
    for i in range(1, len(lines)):
        if lines[i].strip() == "---":
            end = i
            break
    if end is None:
        sys.exit(f"{path}: unterminated frontmatter")

    fm = lines[1:end]
    keys = {k for k, _ in pairs}
    # drop any existing instances of the keys we're setting
    fm = [ln for ln in fm if ln.split(":", 1)[0].strip() not in keys]

    block = [f'{k}: "{v}"' if v and not v.startswith(('"', "[")) else f"{k}: {v}"
             for k, v in pairs]

    # insert after the last `source:` line, else append to end of frontmatter
    insert_at = len(fm)
    for i, ln in enumerate(fm):
        if ln.split(":", 1)[0].strip() == "source":
            insert_at = i + 1
            break
    fm = fm[:insert_at] + block + fm[insert_at:]

    out = ["---", *fm, "---", *lines[end + 1:]]
    path.write_text("\n".join(out) + "\n")
    print(f"updated frontmatter: {path.name} ({', '.join(k for k,_ in pairs)})")

if __name__ == "__main__":
    main()
