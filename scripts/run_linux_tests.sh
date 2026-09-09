#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/test_timeline.py
python3 scripts/test_contracts.py
python3 scripts/test_pack_budget.py
python3 scripts/test_evidence.py
echo "all linux tests ok"
