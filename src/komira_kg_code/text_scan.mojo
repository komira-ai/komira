"""Line scans of Mojo sources and Markdown documents: the packages a Mojo
file imports, the line a declaration starts on, and a document's front
matter.

These read lines, not a parse tree; what each one accepts is stated on it.
Declarations themselves come from `mojo doc` JSON (deriver.mojo); a source
is read here only for its imports and for the line numbers the JSON does
not carry.
"""


def split_lines(text: String) -> List[String]:
    """The lines of `text`, without their `\\n` (and a `\\r` before it). A
    final line with no newline is a line; a text ending in a newline has no
    empty last line."""
    var out = List[String]()
    var b = text.as_bytes()
    var start = 0
    for i in range(len(b)):
        if b[i] == UInt8(ord("\n")):
            var end = i
            if end > start and b[end - 1] == UInt8(ord("\r")):
                end -= 1
            out.append(String(text[byte=start:end]))
            start = i + 1
    if start < len(b):
        out.append(String(text[byte = start : len(b)]))
    return out^


def _is_ident_byte(c: UInt8) -> Bool:
    return (
        (c >= UInt8(ord("a")) and c <= UInt8(ord("z")))
        or (c >= UInt8(ord("A")) and c <= UInt8(ord("Z")))
        or (c >= UInt8(ord("0")) and c <= UInt8(ord("9")))
        or c == UInt8(ord("_"))
    )


def _skip_spaces(b: Span[UInt8, _], var i: Int) -> Int:
    while i < len(b) and (b[i] == UInt8(ord(" ")) or b[i] == UInt8(ord("\t"))):
        i += 1
    return i


def _dotted_name_end(b: Span[UInt8, _], var i: Int) -> Int:
    """The end of the dotted name (`.`, `..`, identifiers and dots) at `i`."""
    while i < len(b) and (_is_ident_byte(b[i]) or b[i] == UInt8(ord("."))):
        i += 1
    return i


def _triple_quotes(line: String) -> Int:
    """How many `\"\"\"` the line holds."""
    var n = 0
    var at = line.find('"""')
    while at >= 0:
        n += 1
        at = line.find('"""', at + 3)
    return n


def imported_modules(text: String) -> List[String]:
    """The module names the Mojo source `text` imports, in source order,
    repeats kept.

    An import is a line that, after leading white space, is
    `from <name> import ...` or `import <name>[ as x][, <name>...]`, where
    `<name>` is dotted (a relative one starts with `.`). A parenthesised
    import continued on the next lines is read from its first line, which
    holds the module. Lines inside a triple-quoted string (a docstring
    showing an import) and comment lines are not imports.
    """
    var out = List[String]()
    var lines = split_lines(text)
    var in_string = False
    for li in range(len(lines)):
        ref line = lines[li]
        var quotes = _triple_quotes(line)
        if in_string:
            if quotes % 2 == 1:
                in_string = False
            continue
        if quotes % 2 == 1:
            in_string = True
            continue
        var b = line.as_bytes()
        var i = _skip_spaces(b, 0)
        if line.find("from ", i) == i:
            var s = _skip_spaces(b, i + 5)
            var e = _dotted_name_end(b, s)
            # No name (e == s): `after` is `e` (`s` is past the spaces
            # already), so the line is not taken.
            var after = _skip_spaces(b, e)
            if after > e and line.find("import", after) == after:
                out.append(String(line[byte=s:e]))
        elif line.find("import ", i) == i:
            var s = _skip_spaces(b, i + 7)
            while True:
                var e = _dotted_name_end(b, s)
                if e == s:
                    break
                out.append(String(line[byte=s:e]))
                var j = _skip_spaces(b, e)
                if line.find("as ", j) == j:
                    j = _skip_spaces(b, j + 3)
                    while j < len(b) and _is_ident_byte(b[j]):
                        j += 1
                    j = _skip_spaces(b, j)
                if j < len(b) and b[j] == UInt8(ord(",")):
                    s = _skip_spaces(b, j + 1)
                else:
                    break
    return out^


def _header_matches(line: String, indent: Int, keyword: String, name: String) -> Bool:
    """Whether `line` is `<indent spaces><keyword> <name>` followed by a
    byte that ends the name (`[`, `(`, `:`, `=`, a space, or the end)."""
    var b = line.as_bytes()
    for i in range(indent):
        if i >= len(b) or b[i] != UInt8(ord(" ")):
            return False
    var head = keyword + " " + name
    if line.find(head, indent) != indent:
        return False
    var end = indent + head.byte_length()
    if end == len(b):
        return True
    var c = b[end]
    return (
        c == UInt8(ord("["))
        or c == UInt8(ord("("))
        or c == UInt8(ord(":"))
        or c == UInt8(ord("="))
        or c == UInt8(ord(" "))
    )


def declaration_line(lines: List[String], keyword: String, name: String, indent: Int, after: Int) -> Int:
    """The 1-based number of the first line after line `after` (1-based; 0
    searches from the top) that starts a `<keyword> <name>` declaration at
    exactly `indent` spaces; 0 if there is none. `keyword` is `struct`,
    `trait`, `def` or `comptime`. Only the header's first line is read: it
    holds the keyword and the name however many lines the header spans.
    With `indent` above 0 (a method) the search stops at the next line
    that starts a module-level statement (a letter, `_` or `@` in column
    0), so a method is looked for only in its own struct or trait."""
    for i in range(after, len(lines)):
        if _header_matches(lines[i], indent, keyword, name):
            return i + 1
        if indent > 0 and i > after and _starts_top_level(lines[i]):
            return 0
    return 0


def _starts_top_level(line: String) -> Bool:
    var b = line.as_bytes()
    if len(b) == 0:
        return False
    var c = b[0]
    return c == UInt8(ord("@")) or c == UInt8(ord("_")) or (c >= UInt8(ord("a")) and c <= UInt8(ord("z"))) or (c >= UInt8(ord("A")) and c <= UInt8(ord("Z")))


@fieldwise_init
struct FrontMatter(Copyable, Movable):
    """What the code graph reads from a Markdown document's front matter:
    its `title` (empty when absent) and its `governs:` entries, in order."""

    var title: String
    var governs: List[String]


def _strip(s: String) -> String:
    var b = s.as_bytes()
    var i = 0
    var j = len(b)
    while i < j and (b[i] == UInt8(ord(" ")) or b[i] == UInt8(ord("\t"))):
        i += 1
    while j > i and (b[j - 1] == UInt8(ord(" ")) or b[j - 1] == UInt8(ord("\t"))):
        j -= 1
    return String(s[byte=i:j])


def _unquote(s: String) -> String:
    var b = s.as_bytes()
    if len(b) >= 2 and b[0] == b[len(b) - 1] and (b[0] == UInt8(ord('"')) or b[0] == UInt8(ord("'"))):
        return String(s[byte = 1 : len(b) - 1])
    return s


def read_front_matter(path: String, text: String) raises -> FrontMatter:
    """The front matter of the Markdown document `text` (named `path` in
    errors): the lines between a first line `---` and the next `---`.

    Read keys: `title: <text>`, and `governs:` given either inline
    (`governs: [a, b]`) or as the indented `- <entry>` lines under it.
    Other keys are ignored. A document with no front matter has an empty
    title and governs nothing. Raises when the front matter is not closed.
    """
    var lines = split_lines(text)
    var fm = FrontMatter(String(""), List[String]())
    if len(lines) == 0 or lines[0] != "---":
        return fm^
    var in_governs = False
    for i in range(1, len(lines)):
        ref line = lines[i]
        if line == "---":
            return fm^
        var b = line.as_bytes()
        var indented = len(b) > 0 and (b[0] == UInt8(ord(" ")) or b[0] == UInt8(ord("\t")))
        var s = _strip(line)
        if in_governs and (indented or s.startswith("- ")):
            if s.startswith("- "):
                fm.governs.append(_unquote(_strip(String(s[byte = 2 : s.byte_length()]))))
                continue
            if s.byte_length() == 0:
                continue
        in_governs = False
        if line.startswith("title:"):
            fm.title = _unquote(_strip(String(line[byte = 6 : line.byte_length()])))
        elif line.startswith("governs:"):
            var rest = _strip(String(line[byte = 8 : line.byte_length()]))
            if rest.byte_length() == 0:
                in_governs = True
            elif rest.startswith("[") and rest.endswith("]"):
                var inner = String(rest[byte = 1 : rest.byte_length() - 1])
                var parts = inner.split(",")
                for p in range(len(parts)):
                    var v = _unquote(_strip(String(parts[p])))
                    if v.byte_length() > 0:
                        fm.governs.append(v)
            else:
                fm.governs.append(_unquote(rest))
    raise Error("komira_kg_code: " + path + ": the front matter opened on line 1 is not closed by a `---` line")
