#!/usr/bin/env python3
"""Keep offline renderer fallbacks identical to the bundled presentation assets."""
from pathlib import Path
import argparse
import re

ROOT = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--check', action='store_true')
args = parser.parse_args()
renderer = ROOT / 'ScrumTrace/Export/SessionBriefRenderer.swift'
source = renderer.read_text()
for name, asset in [('Shell', 'brief.shell.html'), ('CSS', 'brief.css'), ('JS', 'brief.js')]:
    content = (ROOT / 'ScrumTrace/Export/Resources' / asset).read_text().rstrip('\n')
    replacement = f'    private static let fallback{name} = #"""\n' + '\n'.join(('    ' + line if line else '') for line in content.split('\n')) + '\n    """#'
    pattern = rf'    private static let fallback{name} = #?"""\n.*?\n    """#?'
    source, count = re.subn(pattern, lambda _: replacement, source, count=1, flags=re.S)
    if count != 1:
        raise SystemExit(f'Missing fallback{name}')
if args.check:
    if source != renderer.read_text():
        raise SystemExit('Brief fallbacks differ. Run scripts/sync_brief_fallbacks.py')
    print('Brief fallback parity ok')
else:
    renderer.write_text(source)
