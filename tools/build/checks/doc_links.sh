#!/usr/bin/env bash
# doc_links.sh -- every relative link in the repository's Markdown resolves.
#
# usage: tools/build/checks/doc_links.sh [<root>]    (default: the repo root)
#
# Reads every *.md under <root> (skipping .git and buck-out) and checks each
# inline link `[text](target)` and reference definition `[id]: target` whose
# target is relative (not `scheme:`, not `//host`):
#   - the target file or directory exists, resolved against the linking
#     file's directory;
#   - it stays inside <root>, so it also resolves in a fresh clone or on a
#     code host;
#   - a `#fragment` on a Markdown target (or a bare `#fragment`) names a
#     heading in that file (GitHub anchor rules: lower case, punctuation
#     other than `-` and `_` dropped, spaces to `-`, `-N` for repeats).
# Fenced code blocks and inline code are not read. Exits 1 naming every dead
# link, and also when it found no relative link at all (a scan that sees
# nothing proves nothing).
set -euo pipefail

root=${1:-"$(cd "$(dirname "$0")/../../.." && pwd)"}
[ -d "$root" ] || { echo "doc_links: no directory $root" >&2; exit 2; }

python3 - "$root" << 'PY'
import os, re, sys

root = os.path.realpath(sys.argv[1])
FENCE = re.compile(r"^\s*(```|~~~)")
INLINE = re.compile(r"!?\[(?:[^\[\]]|\[[^\]]*\])*\]\(\s*<?([^)\s>]+)>?(?:\s+\"[^\"]*\")?\s*\)")
REFDEF = re.compile(r"^\s{0,3}\[[^\]]+\]:\s*<?(\S+?)>?(?:\s+.*)?$")
HEADING = re.compile(r"^\s{0,3}(#{1,6})\s+(.*?)\s*#*\s*$")
EXTERNAL = re.compile(r"^([A-Za-z][A-Za-z0-9+.-]*:|//)")

def md_files():
    for d, dirs, files in os.walk(root):
        dirs[:] = sorted(x for x in dirs if x not in (".git", "buck-out"))
        for f in sorted(files):
            if f.endswith(".md"):
                yield os.path.join(d, f)

def prose_lines(path):
    fenced = False
    with open(path, encoding="utf-8") as fh:
        for n, line in enumerate(fh, 1):
            if FENCE.match(line):
                fenced = not fenced
                continue
            if not fenced:
                yield n, re.sub(r"`[^`]*`", "``", line.rstrip("\n"))

def slug(text):
    text = re.sub(r"`([^`]*)`", r"\1", text)
    text = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", text)
    text = re.sub(r"[^\w\- ]", "", text.lower())
    return text.replace(" ", "-")

# Anchors come from the raw heading text (inline code kept, unlike the
# masked lines links are read from).
def headings(path):
    seen, out, fenced = {}, set(), False
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            if FENCE.match(line):
                fenced = not fenced
                continue
            m = None if fenced else HEADING.match(line.rstrip("\n"))
            if m:
                s = slug(m.group(2))
                k = seen.get(s, 0)
                seen[s] = k + 1
                out.add(s if k == 0 else "%s-%d" % (s, k))
    return out
anchor_cache = {}
def anchors(path):
    if path not in anchor_cache:
        anchor_cache[path] = headings(path)
    return anchor_cache[path]

checked, dead = 0, []
for md in md_files():
    rel_md = os.path.relpath(md, root)
    for n, line in prose_lines(md):
        targets = [m.group(1) for m in INLINE.finditer(line)]
        m = REFDEF.match(line)
        if m:
            targets.append(m.group(1))
        for t in targets:
            if EXTERNAL.match(t):
                continue
            checked += 1
            path, _, frag = t.partition("#")
            dest = md if path == "" else os.path.normpath(os.path.join(os.path.dirname(md), path))
            where = "%s:%d: %s" % (rel_md, n, t)
            if os.path.commonpath([root, os.path.realpath(dest)]) != root:
                dead.append(where + " (leaves the repository)")
            elif not os.path.exists(dest):
                dead.append(where + " (no such file)")
            elif frag and dest.endswith(".md") and os.path.isfile(dest) and frag not in anchors(dest):
                dead.append(where + " (no heading #%s)" % frag)

if dead:
    for d in dead:
        print("dead link: " + d)
    print("FAIL  doc links: %d of %d relative links do not resolve" % (len(dead), checked))
    sys.exit(1)
if checked == 0:
    print("FAIL  doc links: no relative link found under %s; the scan saw nothing" % root)
    sys.exit(1)
print("PASS  doc links: all %d relative links resolve" % checked)
PY
