"""The program that runs a README's examples, and its line map. Pure: no I/O.

An example is a FRAGMENT, the shape of Rust's doctests. Its column-0
`from`/`import` statements are hoisted to module level, deduplicated across
the README; a statement runs on while a `(` it opened is unclosed or its
line ends with a backslash, and is hoisted and compared whole. So are its
column-0 declarations (`def`, `struct`, `trait`, `comptime`, a decorator),
each running to the next column-0 line. The other lines are the body of
`def _example_<line>() raises:`, `<line>` being the README line of the
example's opening fence. Lines inside a triple-quoted string are copied as
they are (not re-indented).

`main` calls every `_example_<line>()` in README order inside `try`; a
failure prints `<readme>:<line>: FAILED: <error>` and the run continues.
Then it prints `readme_<package> validation: P of E checks passed` (one
check per example: the line kci's read-back already parses) and raises if
any failed.

Every copied line that ends outside a triple-quoted string ends with
`# README.md:<n>`, the README line it came from, so a compile error, which
quotes the offending line, names the README line in the same message.
`map_report` rewrites `<dir>/readme_<package>.mojo:<L>` in a report to
`<readme>:<n>` by reading those tails back.
"""

from .examples import Example
from .text import byte_at, count_of, is_blank, mojo_string_literal, substr, suffix

comptime TAIL = "  # README.md:"


def program_name(package: String) -> String:
    """`readme_<package>.mojo`. Never `<package>.mojo`: a file next to the
    program named like the package would be an import root shadowing it."""
    return "readme_" + package + ".mojo"


def _is_import(line: String) -> Bool:
    return line.startswith("from ") or line.startswith("import ")


def _paren_depth(line: String) -> Int:
    """The `(` minus the `)` of an import line, up to a `#` comment. An
    import holds no string literal, so a `#` always starts a comment."""
    var d = 0
    for i in range(line.byte_length()):
        var c = byte_at(line, i)
        if c == 35:
            break
        if c == 40:
            d += 1
        elif c == 41:
            d -= 1
    return d


def _is_declaration(line: String) -> Bool:
    return (
        line.startswith("def ")
        or line.startswith("struct ")
        or line.startswith("trait ")
        or line.startswith("comptime ")
        or line.startswith("@")
    )


def _tagged(line: String, readme_line: Int, ends_in_string: Bool) -> String:
    if is_blank(line):
        return ""
    if ends_in_string or line.endswith("\\"):
        return line
    return line + TAIL + String(readme_line)


def generate_program(examples: List[Example], package: String, display: String) raises -> String:
    """The program for `examples` (at least one) of package `package`'s
    README, named `display` in its messages."""
    if len(examples) == 0:
        raise Error(display + ": holds no ```mojo example; there is nothing to run")
    var imports = List[String]()
    var import_keys = List[String]()
    var decls = List[String]()
    var bodies = List[String]()
    for e in range(len(examples)):
        ref ex = examples[e]
        var body = List[String]()
        var in_decl = False
        var in_string = False
        # The import statement being read: its lines (tagged), its text (the
        # deduplication key), its open parentheses, whether it goes on.
        var in_import = False
        var import_lines = List[String]()
        var import_key = String()
        var import_depth = 0
        for k in range(len(ex.code)):
            var line = ex.code[k]
            var n = ex.code_lines[k]
            var col0 = not is_blank(line) and byte_at(line, 0) != 32 and byte_at(line, 0) != 9
            if not in_string and not in_import and col0 and _is_import(line):
                in_import = True
                in_decl = False
                import_lines = List[String]()
                import_key = String()
                import_depth = 0
            if in_import:
                import_depth += _paren_depth(line)
                import_lines.append(_tagged(line, n, False))
                if import_key.byte_length() > 0:
                    import_key += "\n"
                import_key += line
                if import_depth > 0 or line.endswith("\\"):
                    continue
                in_import = False
                var seen = False
                for i in range(len(import_keys)):
                    if import_keys[i] == import_key:
                        seen = True
                if not seen:
                    import_keys.append(import_key)
                    for i in range(len(import_lines)):
                        imports.append(import_lines[i])
                continue
            var continuation = in_string
            if count_of(line, "\"\"\"") % 2 == 1:
                in_string = not in_string
            if continuation:
                # Inside a triple-quoted string: copied as it is.
                var t = _tagged(line, n, in_string)
                if in_decl:
                    decls.append(t)
                else:
                    body.append(t)
                continue
            if col0:
                in_decl = _is_declaration(line)
            if in_decl:
                decls.append(_tagged(line, n, in_string))
            elif is_blank(line):
                body.append("")
            else:
                body.append("    " + _tagged(line, n, in_string))
        if in_string:
            raise Error(display + ":" + String(ex.line) + ": the example ends inside a triple-quoted string")
        if in_import:
            raise Error(display + ":" + String(ex.line) + ": the example ends inside an import statement")
        var fn_text = "def _example_" + String(ex.line) + "() raises:\n"
        var any_stmt = False
        for i in range(len(body)):
            if not is_blank(body[i]):
                any_stmt = True
        if not any_stmt:
            fn_text += "    pass\n"
        else:
            # Trim blank lines at both ends.
            var a = 0
            var z = len(body)
            while is_blank(body[a]):
                a += 1
            while is_blank(body[z - 1]):
                z -= 1
            for i in range(a, z):
                fn_text += body[i] + "\n"
        bodies.append(fn_text)
    while len(decls) > 0 and is_blank(decls[len(decls) - 1]):
        _ = decls.pop()
    var stem = "readme_" + package
    var out = String("# Generated by //tools/build/readme_examples from ") + display + ". Do not edit:\n"
    out += "# each line copied from the README ends with the README line it came from.\n"
    if len(imports) > 0:
        out += "\n"
        for i in range(len(imports)):
            out += imports[i] + "\n"
    if len(decls) > 0:
        out += "\n\n"
        for i in range(len(decls)):
            out += decls[i] + "\n"
    for i in range(len(bodies)):
        out += "\n\n" + bodies[i]
    out += "\n\ndef main() raises:\n    var failed = 0\n"
    for e in range(len(examples)):
        var ln = String(examples[e].line)
        out += "    try:\n        _example_" + ln + "()\n    except e:\n        failed += 1\n"
        out += "        print(" + mojo_string_literal(display + ":" + ln + ": FAILED: ") + " + String(e))\n"
    var total = String(len(examples))
    out += "    print(" + mojo_string_literal(stem + " validation: ") + " + String(" + total + " - failed) + "
    out += mojo_string_literal(" of " + total + " checks passed") + ")\n"
    out += "    if failed > 0:\n"
    out += "        raise Error(String(failed) + " + mojo_string_literal(" of " + total + " README examples failed") + ")\n"
    return out^


def readme_line_of(program: String, program_line: Int) -> Int:
    """The README line program line `program_line` (1-based) was copied from,
    or 0 for a generated line."""
    var n = program.byte_length()
    var line = 1
    var start = 0
    for i in range(n + 1):
        if i == n or byte_at(program, i) == 10:
            if line == program_line:
                var text = substr(program, start, i)
                var at = text.rfind(TAIL)
                if at < 0:
                    return 0
                var digits = suffix(text, at + TAIL.byte_length())
                var v = 0
                for k in range(digits.byte_length()):
                    var c = byte_at(digits, k)
                    if c < 48 or c > 57:
                        return 0
                    v = v * 10 + c - 48
                return v
            line += 1
            start = i + 1
    return 0


def map_report(report: String, program: String, package: String, display: String) -> String:
    """`report` with every `[<dir>/]readme_<package>.mojo:<L>` naming a copied
    line rewritten to `<display>:<n>`; a generated line is left as it is."""
    var name = program_name(package)
    var out = String()
    var n = report.byte_length()
    var i = 0
    var start = 0
    while i < n:
        var at = report.find(name, i)
        if at < 0:
            break
        var j = at + name.byte_length()
        var k = j + 1
        var v = 0
        while k < n and byte_at(report, k) >= 48 and byte_at(report, k) <= 57:
            v = v * 10 + byte_at(report, k) - 48
            k += 1
        if j >= n or byte_at(report, j) != 58 or k == j + 1:
            i = j
            continue
        var readme_line = readme_line_of(program, v)
        if readme_line == 0:
            i = k
            continue
        # The whole path token: back to whitespace, a quote or the line start.
        var p = at
        while p > 0:
            var c = byte_at(report, p - 1)
            if c == 32 or c == 9 or c == 10 or c == 34 or c == 39 or c == 40:
                break
            p -= 1
        out += substr(report, start, p) + display + ":" + String(readme_line)
        start = k
        i = k
    out += suffix(report, start)
    return out^
