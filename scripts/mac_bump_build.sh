#!/usr/bin/env bash
# Bump CURRENT_PROJECT_VERSION and CFBundleVersion together.
set -euo pipefail
cd "$(dirname "$0")/.."

CURRENT="$(python3 - <<'PY'
from pathlib import Path
text = Path("ScrumTrace.xcodeproj/project.pbxproj").read_text()
import re
found = re.findall(r"CURRENT_PROJECT_VERSION = (\d+);", text)
print(found[0] if found else "1")
PY
)"
NEXT=$((CURRENT + 1))
python3 - "$CURRENT" "$NEXT" <<'PY'
import sys
from pathlib import Path
old, new = sys.argv[1], sys.argv[2]
pbx = Path("ScrumTrace.xcodeproj/project.pbxproj")
text = pbx.read_text().replace(f"CURRENT_PROJECT_VERSION = {old};", f"CURRENT_PROJECT_VERSION = {new};")
pbx.write_text(text)
info = Path("ScrumTrace/App/Info.plist")
info.write_text(info.read_text().replace(f"<string>{old}</string>", f"<string>{new}</string>", 1))
print(f"build {old} -> {new}")
PY
