#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/test_timeline.py
python3 scripts/test_transcript.py
python3 scripts/test_contracts.py
python3 scripts/test_pack_budget.py
python3 scripts/test_slicer.py
python3 scripts/test_evidence.py
python3 scripts/test_inspect_gates.py
echo "all linux tests ok"
