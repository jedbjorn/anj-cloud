#!/usr/bin/env python3
"""Print the centre "x y" of the [nth] UI node whose text or content-desc fully matches a regex
(uiautomator dump XML on stdin). Flutter merges a tile's lines into one description, so the
pattern is matched with DOTALL. Adapted from the A1 probe (apps/android-probe/tools/ui.py).
   ui.py <regex> [nth]      ui.py --text   (print every text and description, for evidence)"""
import re, sys, xml.etree.ElementTree as ET
try:
    root = ET.fromstring(sys.stdin.read().split('?>', 1)[-1].strip() or '<x/>')
except ET.ParseError:
    sys.exit(1)
if sys.argv[1] == '--text':
    for n in root.iter('node'):
        for k in ('text', 'content-desc'):
            if n.get(k):
                print(n.get(k).replace('\n', ' | '))
    sys.exit(0)
pat = re.compile(sys.argv[1], re.I | re.S)
nth = int(sys.argv[2]) if len(sys.argv) > 2 else 0
for n in root.iter('node'):
    if pat.fullmatch(n.get('text', '')) or pat.fullmatch(n.get('content-desc', '')):
        if nth:
            nth -= 1
            continue
        x1, y1, x2, y2 = map(int, re.findall(r'\d+', n.get('bounds')))
        print((x1 + x2) // 2, (y1 + y2) // 2)
        sys.exit(0)
sys.exit(1)
