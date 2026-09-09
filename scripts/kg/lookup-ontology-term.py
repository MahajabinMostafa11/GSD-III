#!/usr/bin/env python3
# Looks up ontology terms (MONDO, HP, GO, etc.) via OAK's OLS adapter (live
# query against EBI's Ontology Lookup Service, no local ontology download).
# Never hand-type an ontology ID into wiki frontmatter -- run this and use
# its output verbatim.
#
# Requires: pip3 install oaklib --break-system-packages
#
# Usage:
#   ./lookup-ontology-term.py lookup --prefix mondo --query "glycogen storage disease III" --exact

import argparse
import json
import sys
from dataclasses import dataclass, asdict


@dataclass
class OntologyTerm:
    id: str
    label: str


def get_adapter(prefix: str):
    try:
        from oaklib import get_adapter as oak_get_adapter
    except ImportError:
        sys.exit("oaklib not installed. Run: pip3 install oaklib --break-system-packages")

    try:
        return oak_get_adapter(f"ols:{prefix}")
    except Exception as exc:
        sys.exit(f"Failed to load ontology '{prefix}' via OLS: {exc}")


def lookup_term(query: str, prefix: str, exact: bool = False) -> list[OntologyTerm]:
    adapter = get_adapter(prefix)
    results = []
    for curie in adapter.basic_search(query):
        label = adapter.label(curie)
        if not label:
            continue
        if exact and label.strip().lower() != query.strip().lower():
            continue
        results.append(OntologyTerm(id=curie, label=label))
    return results


def main():
    parser = argparse.ArgumentParser(description="Look up ontology terms via OAK's OLS adapter.")
    subparsers = parser.add_subparsers(dest="command", required=True)

    lookup_parser = subparsers.add_parser("lookup")
    lookup_parser.add_argument("--prefix", required=True, help="e.g. mondo, hp, go")
    lookup_parser.add_argument("--query", required=True)
    lookup_parser.add_argument("--exact", action="store_true")

    args = parser.parse_args()

    if args.command == "lookup":
        results = lookup_term(args.query, args.prefix, exact=args.exact)
        print(json.dumps({
            "query": args.query,
            "prefix": args.prefix,
            "exact": args.exact,
            "results": [asdict(r) for r in results],
        }, indent=2))
        if not results:
            sys.exit(1)


if __name__ == "__main__":
    main()
