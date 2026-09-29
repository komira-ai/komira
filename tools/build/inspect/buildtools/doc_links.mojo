"""Every relative link in the tracked Markdown resolves.

The rules are the ones tools/build/tests/functional/doc_links.sh documents. The input is
the root (a real path) and the list of paths git tracks under it.
"""

from std.os.path import exists, isfile, lexists, realpath
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


def _lines(text: String) -> List[String]:
    """Lines without their newline (and without a CR before it)."""
    var out = List[String]()
    var n = text.byte_length()
    var start = 0
    for i in range(n + 1):
        if i == n or byte_at(text, i) == 10:
            if i == n and start == n:
                break
            var end = i
            if end > start and byte_at(text, end - 1) == 13:
                end -= 1
            out.append(substr(text, start, end))
            start = i + 1
    return out^


def _is_fence(line: String) -> Bool:
    var i = 0
    var n = line.byte_length()
    while i < n and is_space(byte_at(line, i)):
        i += 1
    var rest = suffix(line, i)
    return rest.startswith("```") or rest.startswith("~~~")


def _mask_code(line: String) -> String:
    """Inline code spans become two backticks."""
    var out = String()
    var n = line.byte_length()
    var i = 0
    var start = 0
    while i < n:
        if byte_at(line, i) == 96:
            var j = i + 1
            while j < n and byte_at(line, j) != 96:
                j += 1
            if j < n:
                out += substr(line, start, i) + "``"
                i = j + 1
                start = i
                continue
            break
        i += 1
    out += suffix(line, start)
    return out^


def _inline_at(line: String, p: Int, mut target: String) -> Int:
    """Matches `!?[text](<?target>? "title"?)` at p; returns the end or -1."""
    var n = line.byte_length()
    var i = p
    if i < n and byte_at(line, i) == 33:
        var r = _inline_at(line, p + 1, target)
        if r >= 0:
            return r
        return -1
    if i >= n or byte_at(line, i) != 91:
        return -1
    i += 1
    while i < n:
        var c = byte_at(line, i)
        if c == 93:
            break
        if c == 91:
            var j = i + 1
            while j < n and byte_at(line, j) != 93:
                j += 1
            if j >= n:
                return -1
            i = j + 1
            continue
        i += 1
    if i >= n or byte_at(line, i) != 93:
        return -1
    i += 1
    if i >= n or byte_at(line, i) != 40:
        return -1
    i += 1
    while i < n and is_space(byte_at(line, i)):
        i += 1
    if i < n and byte_at(line, i) == 60:
        var alt = String()
        var r = _inline_rest(line, i + 1, alt)
        if r >= 0:
            target = alt
            return r
    return _inline_rest(line, i, target)


def _inline_rest(line: String, p: Int, mut target: String) -> Int:
    var n = line.byte_length()
    var i = p
    var start = i
    while i < n:
        var c = byte_at(line, i)
        if c == 41 or c == 62 or is_space(c):
            break
        i += 1
    if i == start:
        return -1
    var t = substr(line, start, i)
    if i < n and byte_at(line, i) == 62:
        i += 1
    # An optional title: whitespace, then "...".
    var j = i
    while j < n and is_space(byte_at(line, j)):
        j += 1
    if j > i and j < n and byte_at(line, j) == 34:
        var k = j + 1
        while k < n and byte_at(line, k) != 34:
            k += 1
        if k < n:
            var m = k + 1
            while m < n and is_space(byte_at(line, m)):
                m += 1
            if m < n and byte_at(line, m) == 41:
                target = t
                return m + 1
    while i < n and is_space(byte_at(line, i)):
        i += 1
    if i < n and byte_at(line, i) == 41:
        target = t
        return i + 1
    return -1


def _inline_targets(line: String) -> List[String]:
    var out = List[String]()
    var n = line.byte_length()
    var p = 0
    while p < n:
        var t = String()
        var r = _inline_at(line, p, t)
        if r >= 0:
            out.append(t)
            p = r
        else:
            p += 1
    return out^


def _refdef_target(line: String, mut target: String) -> Bool:
    """`[id]: target` at the start of a line (up to three spaces before)."""
    var n = line.byte_length()
    var i = 0
    while i < 3 and i < n and is_space(byte_at(line, i)):
        i += 1
    if i >= n or byte_at(line, i) != 91:
        return False
    var j = i + 1
    while j < n and byte_at(line, j) != 93:
        j += 1
    if j >= n or j == i + 1 or j + 1 >= n or byte_at(line, j + 1) != 58:
        return False
    var k = j + 2
    while k < n and is_space(byte_at(line, k)):
        k += 1
    var start = k
    while k < n and not is_space(byte_at(line, k)):
        k += 1
    if k == start:
        return False
    var t = substr(line, start, k)
    if t.startswith("<") and t.byte_length() > 1:
        t = suffix(t, 1)
    if t.endswith(">") and t.byte_length() > 1:
        t = substr(t, 0, t.byte_length() - 1)
    target = t
    return True


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
    var fenced = False
    var lines = _lines(to_string(read_file(path)))
    for li in range(len(lines)):
        var line = lines[li]
        if _is_fence(line):
            fenced = not fenced
            continue
        if fenced:
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


def _external(t: String) -> Bool:
    if t.startswith("//"):
        return True
    var n = t.byte_length()
    if n == 0:
        return False
    var c = byte_at(t, 0)
    if not ((c >= 65 and c <= 90) or (c >= 97 and c <= 122)):
        return False
    for i in range(1, n):
        var d = byte_at(t, i)
        if d == 58:
            return True
        if not (
            (d >= 65 and d <= 90)
            or (d >= 97 and d <= 122)
            or (d >= 48 and d <= 57)
            or d == 43
            or d == 46
            or d == 45
        ):
            return False
    return False


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
        var lines = _lines(to_string(read_file(md)))
        var fenced = False
        for li in range(len(lines)):
            if _is_fence(lines[li]):
                fenced = not fenced
                continue
            if fenced:
                continue
            var line = _mask_code(lines[li])
            var targets = _inline_targets(line)
            var rd = String()
            if _refdef_target(line, rd):
                targets.append(rd)
            for ti in range(len(targets)):
                var t = targets[ti]
                if _external(t):
                    continue
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
