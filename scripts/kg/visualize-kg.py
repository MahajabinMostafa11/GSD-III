#!/usr/bin/env python3
# Render the wiki's knowledge graph (scripts/kg/build/graph-full.ttl) as an
# interactive HTML visualization using pyvis.
#
# Requires: pip3 install pyvis rdflib
#
# Usage:
#   python3 scripts/kg/visualize-kg.py
#   python3 scripts/kg/visualize-kg.py --output my-graph.html
#   python3 scripts/kg/visualize-kg.py --exclude mentions  # hide noisy edges

import argparse
from pathlib import Path
from rdflib import Graph
from pyvis.network import Network

# Predicates that are structural noise at a glance -- excluded by default,
# can be re-included with --include-all.
DEFAULT_EXCLUDE = {"mentions", "isHub"}

TYPE_COLORS = {
    "Entity": "#e74c3c",
    "Concept": "#3498db",
    "SourceSummary": "#95a5a6",
    "Synthesis": "#2ecc71",
    "Reference": "#f39c12",
    "Index": "#bdc3c7",
    "UntypedNote": "#7f8c8d",
}


def local_name(uri: str) -> str:
    """Shorten a full URI down to its page/predicate name for display."""
    return uri.rstrip("/").split("/")[-1].split("#")[-1]


def main():
    parser = argparse.ArgumentParser(description="Visualize the wiki KG as interactive HTML.")
    parser.add_argument("--input", default="scripts/kg/build/graph-full.ttl")
    parser.add_argument("--output", default="scripts/kg/build/graph-viz.html")
    parser.add_argument(
        "--exclude", nargs="*", default=list(DEFAULT_EXCLUDE),
        help="Predicate local names to exclude as edges (default: mentions, isHub)",
    )
    parser.add_argument("--include-all", action="store_true", help="Don't exclude anything")
    args = parser.parse_args()

    exclude = set() if args.include_all else set(args.exclude)

    g = Graph()
    g.parse(args.input, format="turtle")

    net = Network(height="900px", width="100%", directed=True, notebook=False)
    net.barnes_hut(gravity=-3000, spring_length=150)

    node_types = {}
    for s, p, o in g:
        if local_name(p) == "type":
            node_types[str(s)] = local_name(str(o))

    added = set()

    def ensure_node(uri: str):
        if uri in added:
            return
        added.add(uri)
        label = local_name(uri)
        node_type = node_types.get(uri, "")
        color = TYPE_COLORS.get(node_type, "#cccccc")
        title = f"{label}\ntype: {node_type or 'unknown'}"
        net.add_node(uri, label=label, title=title, color=color)

    for s, p, o in g:
        pred_name = local_name(str(p))
        if pred_name in exclude or pred_name == "type":
            continue
        if str(o).startswith("http"):
            ensure_node(str(s))
            ensure_node(str(o))
            net.add_edge(str(s), str(o), label=pred_name, title=pred_name)

    Path(args.output).parent.mkdir(parents=True, exist_ok=True)
    net.write_html(args.output, open_browser=False)
    print(f"Wrote {args.output} ({len(added)} nodes)")
    print(f"Open it with: open {args.output}")


if __name__ == "__main__":
    main()