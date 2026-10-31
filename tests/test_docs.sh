#!/usr/bin/env bash
# Validate shipped instructions against real help/menu output without networking.
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$ROOT" <<'PY'
from pathlib import Path
from urllib.parse import unquote, urlsplit
import re, subprocess, sys

root = Path(sys.argv[1])
script = root / 'netpilot.sh'
documents = ['README.md', 'README.en.md', 'docs/for-ai.md', 'docs/usage.md']
texts = {name: (root / name).read_text() for name in documents}

def bash_blocks(text):
    return re.findall(r'```bash\n(.*?)```', text, re.S)

def commands(text):
    return [[line.replace(' --lang en', '').strip() for line in block.splitlines()
             if line.strip() and not line.lstrip().startswith('#')] for block in bash_blocks(text)]

assert commands(texts['README.md']) == commands(texts['README.en.md']), 'bilingual examples disagree'
for name, text in texts.items():
    for block in bash_blocks(text):
        result = subprocess.run(['bash', '-n'], input=block, text=True, capture_output=True)
        assert result.returncode == 0, (name, result.stderr)
    assert 'codex-workspace-link.invalid' not in text and '127.0.0.1:8769' not in text, name
    for target in re.findall(r'\]\(([^)]+)\)', text):
        url = urlsplit(target)
        if url.scheme or url.netloc:
            continue
        path = ((root / name).parent / unquote(url.path)).resolve() if url.path else root / name
        assert path.is_file(), (name, 'broken file link', target)
        if url.fragment:
            headings = re.findall(r'^#{1,6} (.+)$', path.read_text(), re.M)
            slugs = {re.sub(r'[^\w\-\s]', '', heading.lower()).replace(' ', '-') for heading in headings}
            assert unquote(url.fragment) in slugs, (name, 'broken anchor', target)
    for target in re.findall(r'<img\b[^>]*src="([^"]+)"', text):
        assert ((root / name).parent / target).is_file(), (name, 'missing image', target)
print('PASS: bilingual examples, Bash syntax and local documentation links')

for lang, name, table in [('zh', 'README.md', '主菜单'), ('en', 'README.en.md', 'Main menu')]:
    help_text = subprocess.check_output(['bash', str(script), '--lang', lang, 'help'], text=True)
    supported = set(re.findall(r'^  ([a-z]+)(?:\s|$)', help_text, re.M))
    options = set(re.findall(r'--[a-z][a-z-]+', help_text))
    for document in [name, 'docs/for-ai.md']:
        text = texts[document]
        documented = set(re.findall(r'\bnetpilot(?: --lang (?:en|zh))? ([a-z]+)\b', text))
        assert supported <= documented, (document, 'undocumented commands', supported - documented)
        assert all(option in text for option in options), (document, 'missing options', options)
    menu = subprocess.check_output(['bash', '-c', 'source "$1"; np_set_language "$2"; show_menu',
                                    '_', str(script), lang], text=True)
    menu = re.sub(r'\x1b\[[0-9;]*m', '', menu)
    actual = re.findall(r'^\s*(\d+|L)\. ', menu, re.M)
    assert actual[:2] == ['9', '10'], 'normal workflow must come first'
    assert re.search(r'^\s*3\. (手动调优|Manual tuning)', menu, re.M), 'manual tuning label is ambiguous'
    match = re.search(r'\| ' + table + r' \|[^\n]*\n\|[^\n]*\n((?:\|[^\n]*\n)+)', texts[name])
    assert match, (name, 'main menu reference missing')
    documented_menu = [key for key in re.findall(r'`([^`]+)`', match[1]) if key in actual]
    assert sorted(actual) == sorted(documented_menu), (name, actual, documented_menu)
print('PASS: documented commands, options and menu actions match actual bilingual CLI output')
PY
