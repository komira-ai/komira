"""Every relative link in the tracked Markdown resolves.

A link resolves when its target, relative to the Markdown file, is a listed
file or a directory holding one, stays inside the root, and a `#fragment`
names a heading of the target Markdown file (GitHub's slugs). Links in code
spans and fenced blocks, and URLs with a scheme, are not checked. What is
code, and what is a link, is `readme_examples.markdown`'s CommonMark reading
(tools/build/readme_examples), the one the README examples are read with.
The input is the root (a real path) and the list of paths under it that count as
present: `git ls-files -z` output, or every file of a staged tree (the
markdown_docs validation, tools/build/lint).
"""

from std.os.path import exists, isfile, lexists, realpath
from readme_examples.markdown import code_mask, relative_links
from readme_examples.text import split_lines
from buildtools.bytes import (
    byte_at,
    bytes_less,
    dirname,
    is_space,
    normpath,
    path_join,
    read_file,
    sort_strings,
    substr,
    suffix,
    to_string,
)


def _heading_text(line: String, mut text: String) -> Bool:
    var n = line.byte_length()
    var i = 0
    while i < 3 and i < n and is_space(byte_at(line, i)):
        i += 1
    var h = i
    while h < n and byte_at(line, h) == 35:
        h += 1
    var level = h - i
    if level < 1 or level > 6 or h >= n or not is_space(byte_at(line, h)):
        return False
    var s = h
    while s < n and is_space(byte_at(line, s)):
        s += 1
    var e = n
    while e > s and is_space(byte_at(line, e - 1)):
        e -= 1
    while e > s and byte_at(line, e - 1) == 35:
        e -= 1
    while e > s and is_space(byte_at(line, e - 1)):
        e -= 1
    text = substr(line, s, e)
    return True


def _keep_code_point(cp: Int) -> Bool:
    """Python's `[\\w\\- ]` for a code point: ASCII exactly; above ASCII,
    letters are kept and the punctuation and symbol blocks dropped."""
    if cp < 128:
        return (
            (cp >= 48 and cp <= 57)
            or (cp >= 97 and cp <= 122)
            or (cp >= 65 and cp <= 90)
            or cp == 95
            or cp == 45
            or cp == 32
        )
    if cp < 0xC0 or cp == 0xD7 or cp == 0xF7:
        return False
    if (cp >= 0x2000 and cp < 0x2C00) or (cp >= 0x3000 and cp < 0x3040):
        return False
    if (cp >= 0xFE00 and cp < 0xFE70) or (cp >= 0xFF00 and cp < 0xFF10):
        return False
    return cp < 0x1F000


def slug(text: String) -> String:
    """GitHub's anchor for a heading's text."""
    # `code` -> code
    var a = String()
    var n = text.byte_length()
    var i = 0
    var start = 0
    while i < n:
        if byte_at(text, i) == 96:
            var j = i + 1
            while j < n and byte_at(text, j) != 96:
                j += 1
            if j < n:
                a += substr(text, start, i) + substr(text, i + 1, j)
                i = j + 1
                start = i
                continue
            break
        i += 1
    a += suffix(text, start)
    # [label](url) -> label
    var b = String()
    n = a.byte_length()
    i = 0
    start = 0
    while i < n:
        if byte_at(a, i) == 91:
            var j = i + 1
            while j < n and byte_at(a, j) != 93:
                j += 1
            if j + 1 < n and byte_at(a, j + 1) == 40:
                var k = j + 2
                while k < n and byte_at(a, k) != 41:
                    k += 1
                if k < n:
                    b += substr(a, start, i) + substr(a, i + 1, j)
                    i = k + 1
                    start = i
                    continue
        i += 1
    b += suffix(a, start)
    # Lower case, keep [\w\- ], spaces to dashes.
    var out = List[UInt8]()
    var bytes = b.as_bytes()
    n = len(bytes)
    i = 0
    while i < n:
        var c = Int(bytes[i])
        var width = 1
        var cp = c
        if c >= 0xF0:
            width = 4
            cp = c & 0x07
        elif c >= 0xE0:
            width = 3
            cp = c & 0x0F
        elif c >= 0xC0:
            width = 2
            cp = c & 0x1F
        for k in range(1, width):
            if i + k < n:
                cp = (cp << 6) | (Int(bytes[i + k]) & 0x3F)
        if _keep_code_point(cp):
            if cp >= 65 and cp <= 90:
                out.append(UInt8(cp + 32))
            elif cp == 32:
                out.append(UInt8(45))
            else:
                for k in range(width):
                    if i + k < n:
                        out.append(bytes[i + k])
        i += width
    return to_string(out)


def _anchors(path: String) raises -> List[String]:
    var seen_slug = List[String]()
    var seen_count = List[Int]()
    var out = List[String]()
    var lines = split_lines(to_string(read_file(path)))
    var code = code_mask(lines)
    for li in range(len(lines)):
        var line = lines[li]
        if code[li]:
            continue
        var text = String()
        if _heading_text(line, text):
            var s = slug(text)
            var k = 0
            var found = -1
            for m in range(len(seen_slug)):
                if seen_slug[m] == s:
                    found = m
            if found >= 0:
                k = seen_count[found]
                seen_count[found] = k + 1
            else:
                seen_slug.append(s)
                seen_count.append(1)
            if k == 0:
                out.append(s)
            else:
                out.append(s + "-" + String(k))
    return out^


def _contains(xs: List[String], x: String) -> Bool:
    # xs is sorted: binary search.
    var lo = 0
    var hi = len(xs)
    while lo < hi:
        var mid = (lo + hi) // 2
        if xs[mid] == x:
            return True
        if bytes_less(xs[mid], x):
            lo = mid + 1
        else:
            hi = mid
    return False


def _inside(root: String, p: String) -> Bool:
    return p == root or p.startswith(root + "/")


def doc_links(root: String, tracked_z: List[UInt8]) raises -> Int:
    """Prints the verdict; returns the exit status."""
    var tracked = List[String]()
    var dirs = List[String]()
    dirs.append(root)
    var start = 0
    for i in range(len(tracked_z) + 1):
        if i == len(tracked_z) or Int(tracked_z[i]) == 0:
            if i > start:
                var sub = List[UInt8]()
                for k in range(start, i):
                    sub.append(tracked_z[k])
                var full = path_join(root, to_string(sub))
                if lexists(full):
                    tracked.append(full)
                    var d = dirname(full)
                    while _inside(root, d) and d != root:
                        dirs.append(d)
                        d = dirname(d)
            start = i + 1
    sort_strings(tracked)
    sort_strings(dirs)
    var md_files = List[String]()
    for i in range(len(tracked)):
        if tracked[i].endswith(".md"):
            md_files.append(tracked[i])
    var anchor_paths = List[String]()
    var anchor_sets = List[List[String]]()
    var checked = 0
    var dead = List[String]()
    for f in range(len(md_files)):
        var md = md_files[f]
        var rel_md = suffix(md, root.byte_length() + 1)
        var links = relative_links(split_lines(to_string(read_file(md))))
        for k in range(len(links)):
            var li = links[k].line
            var t = links[k].target
            checked += 1
            var hash = t.find("#")
            var path = t if hash < 0 else substr(t, 0, hash)
            var frag = String("") if hash < 0 else suffix(t, hash + 1)
            var dest = md if path.byte_length() == 0 else normpath(path_join(dirname(md), path))
            var where = rel_md + ":" + String(li + 1) + ": " + t
            var real = dest
            if exists(dest):
                real = realpath(dest)
            if not _inside(root, real) or not _inside(root, dest):
                dead.append(where + " (leaves the repository)")
            elif not exists(dest):
                dead.append(where + " (no such file)")
            elif not _contains(tracked, dest) and not _contains(dirs, dest):
                dead.append(where + " (not tracked by git)")
            elif frag.byte_length() > 0 and dest.endswith(".md") and isfile(dest):
                var idx = -1
                for a in range(len(anchor_paths)):
                    if anchor_paths[a] == dest:
                        idx = a
                if idx < 0:
                    anchor_paths.append(dest)
                    var got = _anchors(dest)
                    sort_strings(got)
                    anchor_sets.append(got^)
                    idx = len(anchor_paths) - 1
                if not _contains(anchor_sets[idx], frag):
                    dead.append(where + " (no heading #" + frag + ")")
    if len(dead) > 0:
        for i in range(len(dead)):
            print("dead link: " + dead[i])
        print("FAIL  doc links: " + String(len(dead)) + " of " + String(checked) + " relative links do not resolve")
        return 1
    if checked == 0:
        print("FAIL  doc links: no relative link found under " + root + "; the scan saw nothing")
        return 1
    print("PASS  doc links: all " + String(checked) + " relative links resolve")
    return 0
