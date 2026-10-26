#!/usr/bin/env python3
"""Validate the static project-site pages and their local references."""
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import urljoin, urlparse, unquote
import json
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1] / 'docs'
BASE = 'https://retsubhtym.github.io/SpaceControl/'
errors = []

class Page(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.titles = 0; self.h1 = 0; self.descriptions = []; self.canonicals = []
        self.meta = {}; self.refs = []; self.in_json = False; self.json = ''; self.blocks = []
    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag == 'title': self.titles += 1
        if tag == 'h1': self.h1 += 1
        if tag == 'meta':
            key = a.get('name', a.get('property', '')).lower()
            if key: self.meta.setdefault(key, []).append(a.get('content', ''))
            if key == 'description': self.descriptions.append(a.get('content', ''))
            if key in ('robots', 'googlebot', 'bingbot') and 'noindex' in a.get('content', '').lower(): errors.append('Unexpected noindex')
        if tag == 'link' and 'canonical' in a.get('rel', '').lower().split(): self.canonicals.append(a.get('href', ''))
        for attr in ('href', 'src', 'poster'):
            if attr in a: self.refs.append(a[attr])
        if tag == 'script' and a.get('type') == 'application/ld+json': self.in_json = True; self.json = ''
    def handle_data(self, data):
        if self.in_json: self.json += data
    def handle_endtag(self, tag):
        if tag == 'script' and self.in_json:
            self.blocks.append(self.json); self.in_json = False

pages = sorted(ROOT.rglob('*.html')); canonicals = set()
for path in pages:
    page = Page(); page.feed(path.read_text(encoding='utf-8'))
    expected = BASE + ('' if path.name == 'index.html' and path.parent == ROOT else path.relative_to(ROOT).as_posix())
    for ok, message in [(page.titles == 1, 'title'), (page.h1 == 1, 'H1'), (len(page.descriptions) == 1 and bool(page.descriptions[0]), 'description'), (page.canonicals == [expected], 'canonical')]:
        if not ok: errors.append(f'{path}: invalid {message}')
    if expected in canonicals: errors.append(f'{path}: duplicate canonical')
    canonicals.add(expected)
    for key, values in page.meta.items():
        if len(values) > 1: errors.append(f'{path}: duplicate metadata {key}')
    for block in page.blocks:
        try: json.loads(block)
        except json.JSONDecodeError as exc: errors.append(f'{path}: JSON-LD: {exc}')
    for ref in page.refs:
        url = urlparse(urljoin(expected, ref))
        if url.scheme not in ('http', 'https') or url.netloc != 'retsubhtym.github.io': continue
        if not url.path.startswith('/SpaceControl/'):
            errors.append(f'{path}: incorrect base path: {ref}'); continue
        target = ROOT / unquote(url.path.removeprefix('/SpaceControl/'))
        if target.is_dir(): target = target / 'index.html'
        if not target.is_file(): errors.append(f'{path}: missing local reference: {ref}')
try:
    tree = ET.parse(ROOT / 'sitemap.xml')
    urls = [e.text for e in tree.findall('{http://www.sitemaps.org/schemas/sitemap/0.9}url/{http://www.sitemaps.org/schemas/sitemap/0.9}loc')]
    if len(urls) != len(set(urls)) or set(urls) != canonicals: errors.append('Sitemap URLs do not match canonical pages')
except ET.ParseError as exc: errors.append(f'Invalid sitemap: {exc}')
if errors:
    print('\n'.join(errors)); raise SystemExit(1)
print(f'Validated {len(pages)} pages, local references, JSON-LD and sitemap.')
