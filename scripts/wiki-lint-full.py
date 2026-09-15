#!/usr/bin/env python3
"""Comprehensive mechanical lint checks for the GSD-III wiki. Read-only."""
import re, glob, os, sys
try:
    import yaml
except ImportError:
    yaml = None

wiki_dir = sys.argv[1] if len(sys.argv) > 1 else 'wiki/GSD-III.wiki'
files = glob.glob(f'{wiki_dir}/*.md')
basenames = {os.path.basename(f)[:-3]: f for f in files}

special_files = {'Home_GSD-III', 'Home', 'index_GSD-III', 'log_GSD-III', 'SCHEMA_GSD-III', 'Edge-Types'}

pages = {}
for name, path in basenames.items():
    content = open(path, encoding='utf-8').read()
    fm_raw = None
    body = content
    if content.startswith('---'):
        end = content.find('\n---', 3)
        if end != -1:
            fm_raw = content[3:end]
            body = content[end+4:]
    fm = {}
    fm_error = None
    if fm_raw is not None and yaml:
        try:
            fm = yaml.safe_load(fm_raw) or {}
        except Exception as e:
            fm_error = str(e)
    pages[name] = {'path': path, 'fm': fm, 'fm_raw': fm_raw, 'fm_error': fm_error, 'body': body, 'content': content}

# ---- Missing frontmatter / required fields ----
print("=== Missing/invalid frontmatter ===")
count = 0
for name, p in pages.items():
    if name in special_files and name in ('Home',):
        continue  # Home.md is an intentional redirect stub
    issues = []
    if p['fm_raw'] is None:
        issues.append('NO FRONTMATTER BLOCK')
    elif p['fm_error']:
        issues.append(f'YAML PARSE ERROR: {p["fm_error"]}')
    else:
        for req in ('type', 'up', 'title', 'description', 'tags', 'lifecycle', 'sources', 'updated'):
            if req not in p['fm']:
                issues.append(f'missing `{req}:`')
        t = p['fm'].get('type')
        if t in ('concept','treatment','synthesis','source-summary') and 'evidence' not in p['fm']:
            issues.append('missing `evidence:` (claim-bearing type)')
        if t == 'source-summary' and 'ingestion_depth' not in p['fm']:
            issues.append('missing `ingestion_depth:`')
    if issues:
        count += 1
        print(f'  {name}: {"; ".join(issues)}')
print(f'Total pages with frontmatter issues: {count}')

# ---- type: untyped ----
print("\n=== type: untyped pages ===")
untyped = [n for n,p in pages.items() if p['fm'].get('type') == 'untyped']
for n in untyped: print(' ', n)
print(f'Total: {len(untyped)}')

# ---- Dead links (body [Display](Page-Name) and frontmatter [[Page-Name]]) ----
# Link syntax quoted for documentation purposes (inline `code spans` or fenced
# ```code blocks```) is not a real reference and must not be scanned -- strip
# both before matching, on a throwaway copy used only for this check.
print("\n=== Dead links ===")
fenced_block_re = re.compile(r'```.*?```', re.DOTALL)
inline_code_re = re.compile(r'`[^`\n]+`')
link_re = re.compile(r'\[([^\]]*)\]\(([^)#\s]+)(#[^)]*)?\)')
wikilink_re = re.compile(r'\[\[([^\]|#]+)')
dead = []
for name, p in pages.items():
    scan_text = fenced_block_re.sub('', p['content'])
    scan_text = inline_code_re.sub('', scan_text)
    for m in link_re.finditer(scan_text):
        target = m.group(2)
        if target.startswith('http') or target.startswith('mailto:'):
            continue
        target = target.strip()
        if not target:
            continue
        # relative filesystem paths (leave the wiki dir) are resolved against
        # disk, not against the in-wiki page catalog
        if target.startswith('.') or '/' in target:
            resolved = os.path.normpath(os.path.join(wiki_dir, target))
            if os.path.exists(resolved):
                continue
            dead.append((name, target, 'body-link'))
            continue
        if target not in pages and target not in special_files:
            dead.append((name, target, 'body-link'))
    for m in wikilink_re.finditer(p['fm_raw'] or ''):
        target = m.group(1).strip()
        if target and target not in pages and target not in special_files:
            dead.append((name, target, 'frontmatter-wikilink'))
for src, target, kind in dead:
    print(f'  {src} -> {target}  ({kind})')
print(f'Total dead links: {len(dead)}')

# ---- Orphan pages (no inbound links from any page or index) ----
print("\n=== Orphan pages (no inbound reference found) ===")
index_content = open(f'{wiki_dir}/index_GSD-III.md', encoding='utf-8').read() if os.path.exists(f'{wiki_dir}/index_GSD-III.md') else ''
all_text = index_content + '\n'.join(p['content'] for p in pages.values())
inbound_count = {n: 0 for n in pages}
for name in pages:
    # count occurrences of this page name as a link target elsewhere (exclude self)
    pattern = re.compile(r'\(' + re.escape(name) + r'(#[^)]*)?\)|\[\[' + re.escape(name) + r'(\|[^\]]*)?\]\]')
    hits = 0
    for other_name, p in pages.items():
        if other_name == name:
            continue
        hits += len(pattern.findall(p['content']))
    hits += len(pattern.findall(index_content))
    inbound_count[name] = hits
orphans = [n for n,c in inbound_count.items() if c == 0 and n not in special_files]
for n in sorted(orphans):
    print(' ', n)
print(f'Total orphans: {len(orphans)}')

# ---- Index gaps ----
print("\n=== Index gaps (page exists but not linked from index_GSD-III.md) ===")
gaps = [n for n in pages if n not in special_files and f'({n})' not in index_content and f'[[{n}' not in index_content]
for n in sorted(gaps):
    print(' ', n)
print(f'Total index gaps: {len(gaps)}')

# ---- Special file integrity ----
print("\n=== Special file integrity ===")
for sf in ('Home_GSD-III', 'Home', 'index_GSD-III', 'log_GSD-III', 'SCHEMA_GSD-III'):
    path = f'{wiki_dir}/{sf}.md'
    print(f'  {sf}.md: {"present" if os.path.exists(path) else "MISSING"}')
