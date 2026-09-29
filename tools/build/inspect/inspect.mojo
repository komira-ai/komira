"""inspect: structured reads for the repository's checks.

    inspect json <file>         JSON as tab-separated leaf lines (buildtools.json)
    inspect json-lines <file>   the same for each line that starts with `{`,
                                every leaf prefixed by the 1-based line number
    inspect json-canon <file>   Python's compact sorted-key form, no newline
    inspect tar <file.tar>      one line per member (uncompressed archive):
                                name (dirs end in /), type f|d|o<flag>, mode
                                (octal), uid, gid, uname, gname, mtime, pax
                                (1 when the name came from a PAX header),
                                sha256 of a file's data (- otherwise)
    inspect macho <file>        header, load, id, rpath and minos lines
    inspect doc-links <root> <list>  checks the Markdown links under <root>;
                                <list> is `git ls-files -z` output (paths
                                relative to <root>)

Exits 2 on bad usage or input it cannot read, printing why.
"""

from std.sys import argv, exit
from buildtools.bytes import octal, read_file
from buildtools.doc_links import doc_links
from buildtools.json import canonical_document, escape_field, flatten_document
from buildtools.macho import macho_listing
from buildtools.sha256 import sha256_hex
from buildtools.tar import read_tar


def _usage():
    print("usage: inspect json|json-lines|json-canon|tar|macho <file> | inspect doc-links <root> <list>")
    exit(2)


def _tar(path: String) raises -> String:
    var b = read_file(path)
    var members = read_tar(b)
    var out = String()
    for i in range(len(members)):
        var m = members[i].copy()
        var kind = String("f")
        var name = m.name
        if m.is_dir():
            kind = "d"
            name += "/"
        elif not m.is_file():
            kind = "o" + String(m.typeflag)
        var digest = String("-")
        if m.is_file():
            digest = sha256_hex(b, m.offset, m.offset + m.size)
        out += escape_field(name) + "\t" + kind + "\t" + octal(m.mode) + "\t" + String(m.uid) + "\t" + String(m.gid)
        out += "\t" + escape_field(m.uname) + "\t" + escape_field(m.gname) + "\t" + m.mtime
        out += "\t" + ("1" if m.pax_path else "0") + "\t" + digest + "\n"
    return out^


def _json_lines(path: String) raises -> String:
    var b = read_file(path)
    var out = String()
    var start = 0
    var line_no = 0
    for i in range(len(b) + 1):
        if i == len(b) or Int(b[i]) == 10:
            line_no += 1
            if i > start and Int(b[start]) == 123:
                var sub = List[UInt8]()
                for k in range(start, i):
                    sub.append(b[k])
                flatten_document(sub^, String(line_no) + "\t", out)
            start = i + 1
    return out^


def main() raises:
    var args = argv()
    if len(args) < 3 or len(args) > 4:
        _usage()
    var cmd = String(args[1])
    var arg = String(args[2])
    try:
        if cmd == "json":
            var out = String()
            flatten_document(read_file(arg), String(""), out)
            print(out, end="")
        elif cmd == "json-lines":
            print(_json_lines(arg), end="")
        elif cmd == "json-canon":
            print(canonical_document(read_file(arg)), end="")
        elif cmd == "tar":
            print(_tar(arg), end="")
        elif cmd == "macho":
            print(macho_listing(read_file(arg)), end="")
        elif cmd == "doc-links":
            if len(args) != 4:
                _usage()
            exit(doc_links(arg, read_file(String(args[3]))))
        else:
            _usage()
    except e:
        print("inspect " + cmd + ": " + arg + ": " + String(e))
        exit(2)
