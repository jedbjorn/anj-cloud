#!/usr/bin/env python3
"""Validate the buildless public site without network access or dependencies."""
from html.parser import HTMLParser
from pathlib import Path
import re
import sys
from urllib.parse import unquote, urlsplit
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
SITE = ROOT / "site"
errors = []


class Page(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.ids = set()
        self.links = []
        self.h1s = 0
        self.images = 0

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if "id" in attrs:
            if attrs["id"] in self.ids:
                errors.append(f"Duplicate id: {attrs['id']}")
            self.ids.add(attrs["id"])
        if tag == "html" and attrs.get("lang") != "en":
            errors.append("Missing English document language")
        if tag == "h1":
            self.h1s += 1
        if tag == "img":
            self.images += 1
            if "alt" not in attrs or not all(attrs.get(k) for k in ("width", "height")):
                errors.append(f"Image needs alt and dimensions: {attrs.get('src')}")
        if tag in ("script", "iframe") or any(k.startswith("on") for k in attrs):
            errors.append(f"Unexpected active content: {tag}")
        for key in ("href", "src"):
            if key in attrs:
                self.links.append((tag, key, attrs[key]))


page = Page()
page.feed((SITE / "index.html").read_text())
if page.h1s != 1:
    errors.append(f"Expected one h1, found {page.h1s}")
for tag, attr, link in page.links:
    parsed = urlsplit(link)
    if parsed.scheme or parsed.netloc:
        if parsed.scheme != "https":
            errors.append(f"Non-HTTPS external link: {link}")
        if tag == "img" or (tag == "link" and "github.io" not in parsed.netloc):
            errors.append(f"External asset: {link}")
        prefix = "/jedbjorn/anj-cloud/blob/main/"
        if parsed.netloc == "github.com" and parsed.path.startswith(prefix):
            doc = ROOT / unquote(parsed.path[len(prefix):])
            if not doc.is_file():
                errors.append(f"Missing linked repository document: {doc}")
            elif parsed.fragment and doc.suffix == ".md":
                headings = re.findall(r"^#{1,6}\s+(.+)$", doc.read_text(), re.M)
                anchors = {re.sub(r"[^\w\- ]", "", h.lower()).replace(" ", "-") for h in headings}
                if parsed.fragment not in anchors:
                    errors.append(f"Missing documentation heading: {link}")
        continue
    if parsed.path.startswith("/"):
        errors.append(f"Root-relative link breaks project Pages path: {link}")
    destination = (SITE / unquote(parsed.path)).resolve() if parsed.path else SITE / "index.html"
    if not destination.is_relative_to(SITE.resolve()) or not destination.exists():
        errors.append(f"Missing or escaped site asset: {link}")
    if parsed.fragment and parsed.fragment not in page.ids:
        errors.append(f"Missing section: {link}")

for asset in SITE.rglob("*"):
    if asset.is_symlink():
        errors.append(f"Symlink in published assets: {asset}")
    if asset.is_file() and asset.suffix not in {".html", ".css", ".svg", ".png", ""}:
        errors.append(f"Unexpected published file: {asset}")
    if asset.suffix == ".svg":
        svg = ET.parse(asset)
        for element in svg.iter():
            if element.tag.rsplit("}", 1)[-1] in {"script", "foreignObject"}:
                errors.append(f"Active SVG content: {asset}")
            if any(k.rsplit("}", 1)[-1].startswith("on") for k in element.attrib):
                errors.append(f"SVG event handler: {asset}")
styles = (SITE / "styles.css").read_text()
if "@import" in styles or re.search(r"url\s*\(", styles):
    errors.append("Unexpected CSS asset import")
if errors:
    print("\n".join(errors), file=sys.stderr)
    sys.exit(1)
size = sum(p.stat().st_size for p in SITE.rglob("*") if p.is_file())
print(f"PASS: {len(page.links)} links, {page.images} images, local assets and SVGs; {size:,} bytes published.")
