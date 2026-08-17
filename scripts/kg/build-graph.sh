#!/usr/bin/env bash
# scripts/kg/build-graph.sh
#
# Thin shell entry point. Delegates to scripts/kg/build-graph.py, which
# runs the full pipeline (fetch spec, extract, materialise, validate)
# in-process using rdflib + pyshacl.
#
# All CLI flags are passed through to the Python script. See
# scripts/kg/build-graph.py --help for the full list.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# pyshacl >=0.30 uses `X | Y` type hints (Python 3.10+ syntax), so plain
# python3 fails on this machine's Python 3.9. Prefer python3.11 when it's
# on PATH; fall back to python3 otherwise.
PYTHON=python3
command -v python3.11 >/dev/null 2>&1 && PYTHON=python3.11

exec "$PYTHON" "$SCRIPT_DIR/build-graph.py" "$@"
