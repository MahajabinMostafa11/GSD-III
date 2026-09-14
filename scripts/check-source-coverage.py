#!/usr/bin/env python3
"""
check-source-coverage.py

Compares the publication corpus against the wiki's existing source-summary
pages, reporting which papers (by PMID/DOI) still lack a page. Read-only --
makes no changes, safe to re-run anytime as ingestion progresses.

Usage:
  python3 check-source-coverage.py \
      --corpus "raw sources/publications_gsd.json" \
      --wiki wiki/GSD-III.wiki \
      --out missing-source-summaries.csv
"""

import argparse
import csv
import glob
import json
import re
from pathlib import Path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--corpus", required=True)
    parser.add_argument("--wiki", required=True)
    parser.add_argument("--out", default="missing-source-summaries.csv")
    args = parser.parse_args()

    with open(args.corpus) as f:
        papers = json.load(f)
    papers_with_pmid = [p for p in papers if p.get("pubmed_id")]

    existing_sources = set()
    for fname in glob.glob(str(Path(args.wiki) / "*.md")):
        with open(fname) as f:
            content = f.read()
        if "type: source-summary" not in content:
            continue
        m = re.search(r'^source:\s*"([^"]+)"', content, re.MULTILINE)
        if m:
            existing_sources.add(m.group(1).strip())

    missing = []
    for p in papers_with_pmid:
        doi = p.get("doi")
        doi_url = f"https://doi.org/{doi}" if doi else None
        if doi_url and doi_url in existing_sources:
            continue
        missing.append(p)

    print(f"Papers with PMID in corpus: {len(papers_with_pmid)}")
    print(f"Existing source-summary pages (with source:): {len(existing_sources)}")
    print(f"Papers NOT YET ingested: {len(missing)}")

    with open(args.out, "w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(["pmid", "doi", "year", "title"])
        for p in missing:
            writer.writerow([
                p.get("pubmed_id"),
                p.get("doi"),
                p.get("publication_year"),
                p.get("title"),
            ])
    print(f"Wrote {args.out}")


if __name__ == "__main__":
    main()
