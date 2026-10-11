# =============================================================================
# test_plan_reservations.mojo
# =============================================================================
#
# THE RESERVATIONS OF komira.plan.v1: every `reserved` number and name the
# .proto files declare, held to `RESERVED` (end of file), in both
# directions. Byte tests cannot see a `reserved` line: a number nothing
# declares decodes to nothing whether or not it is reserved, so deleting a
# reservation, or reserving a number the design holds for a later field,
# leaves every decode as it was. This test reads the .proto text instead.
#
#   1. Every `reserved` statement of every .proto staged under protos/ (the
#      library's `srcs`, BUCK) is read, inside the message or enum that
#      holds it, and each number (a range `a to b` gives each number in it)
#      and each quoted name becomes a row `<Type> <number>` or
#      `<Type> "<name>"`. That set must equal RESERVED: a deleted `reserved`
#      line (number or name) and a new reservation both fail.
#   2. optimized_plan.proto's HELD table (staged from its census,
#      census/test_optimized_plan_field_numbers.mojo) is held to the same
#      rows: a `reserved` row's number must be reserved in its message, a
#      `held` row's number must not be (a held number stays free for the
#      field the design numbers there), and every number optimized_plan.proto
#      reserves needs a `reserved` row, so `test_held_numbers` writes bytes
#      under each one.
#
# A statement it cannot read (`reserved` with `max`, a bare identifier, a
# malformed number or name, an empty range or one over 1000 numbers, a
# `reserved` outside a message or enum body (in a `oneof`, say), a `/* */`
# comment, a `}` with no `{`) is refused rather than skipped. `reserved` is
# read as the keyword only where a statement starts (after `{`, `}` or `;`),
# so a field named `reserved` is a field. A HELD row that is not four words
# ending `held` or `reserved` is refused. The checks are run over planted
# defects as well (a deleted number, a deleted name, a reserved held number,
# an added reservation, in optimized_plan.proto, and an added and a deleted
# number in plan_vocabulary.proto; each unreadable form, each malformed HELD
# row), and each must be reported; a refusal is matched on its whole message.
# =============================================================================

from std.os import listdir
from std.pathlib import Path
from std.testing import assert_equal, assert_true

comptime _OPTIMIZED = "optimized_plan.proto"
comptime _HELD_SOURCE = "census/test_optimized_plan_field_numbers.mojo"


# ---- the .proto text --------------------------------------------------------------


def _tokens(text: String) raises -> List[String]:
    """The tokens of `text` with `//` comments removed: words, and `{`, `}`,
    `;` and `,` each on their own, split on any whitespace."""
    if text.find("/*") >= 0:
        raise Error("the .proto text holds a /* */ comment, which the reservation scan does not read")
    var out = List[String]()
    for raw in text.split("\n"):
        var line = String(raw)
        var c = line.find("//")
        var code = String(line[byte=0:c]) if c >= 0 else line
        code = code.replace("\t", " ").replace("\r", " ").replace("\f", " ").replace("\v", " ")
        code = code.replace("{", " { ").replace("}", " } ").replace(";", " ; ").replace(",", " , ")
        for w in code.split(" "):
            if w.byte_length() > 0:
                out.append(String(w))
    return out^


def _is_number(w: String) -> Bool:
    var bytes = w.as_bytes()
    if len(bytes) == 0:
        return False
    for i in range(len(bytes)):
        if Int(bytes[i]) < 48 or Int(bytes[i]) > 57:
            return False
    return True


def _is_name(w: String) -> Bool:
    """A double-quoted name with no quote inside."""
    var n = w.byte_length()
    return n >= 3 and w.startswith('"') and w.endswith('"') and String(w[byte = 1 : n - 1]).find('"') < 0


def _item(owner: String, words: List[String], mut out: List[String]) raises:
    """The rows of one comma-separated item of a `reserved` statement."""
    var what = "`reserved` in " + owner
    if len(words) == 1 and _is_name(words[0]):
        out.append(owner + " " + words[0])
        return
    if len(words) == 1 and _is_number(words[0]):
        out.append(owner + " " + words[0])
        return
    if len(words) == 3 and _is_number(words[0]) and words[1] == "to" and _is_number(words[2]):
        var lo = Int(words[0])
        var hi = Int(words[2])
        if hi < lo:
            raise Error(what + ": the range " + words[0] + " to " + words[2] + " is empty")
        if hi - lo >= 1000:
            raise Error(what + ": the range " + words[0] + " to " + words[2] + " is over 1000 numbers")
        for n in range(lo, hi + 1):
            out.append(owner + " " + String(n))
        return
    var text = String("")
    for i in range(len(words)):
        text += (String(" ") if i > 0 else String("")) + words[i]
    raise Error(what + ": an item the reservation scan cannot read: `" + text + "`")


def _reserved(text: String) raises -> List[String]:
    """A row for every number and name a `reserved` statement of `text`
    declares, `<Type> <number>` or `<Type> "<name>"`, where `<Type>` is the
    message or enum whose body holds the statement."""
    var t = _tokens(text)
    var owners = List[String]()  # one per open `{`: the type name, or "" for any other block
    var out = List[String]()
    var i = 0
    while i < len(t):
        var w = t[i].copy()
        if w == "{":
            var named = i >= 2 and (t[i - 2] == "message" or t[i - 2] == "enum")
            owners.append(t[i - 1].copy() if named else String(""))
        elif w == "}":
            if len(owners) == 0:
                raise Error("the .proto text closes a block it never opened")
            _ = owners.pop()
        elif w == "reserved" and (i == 0 or t[i - 1] == "{" or t[i - 1] == "}" or t[i - 1] == ";"):
            var owner = owners[len(owners) - 1].copy() if len(owners) > 0 else String("")
            if owner.byte_length() == 0:
                raise Error("a `reserved` statement outside a message or enum body")
            var words = List[String]()
            i += 1
            while i < len(t) and t[i] != ";":
                if t[i] == ",":
                    _item(owner, words, out)
                    words = List[String]()
                else:
                    words.append(t[i].copy())
                i += 1
            if i == len(t):
                raise Error("`reserved` in " + owner + ": the statement has no `;`")
            _item(owner, words, out)
        i += 1
    if len(owners) != 0:
        raise Error("the .proto text leaves a block open")
    return out^


# ---- the rows -------------------------------------------------------------------


def _rows(block: String) -> List[String]:
    var out = List[String]()
    for raw in block.split("\n"):
        var line = String(String(raw).strip())
        if line.byte_length() > 0:
            out.append(line)
    return out^


def _block(source: String, name: String) raises -> String:
    """The text of `source`'s `comptime <name> = \"\"\"` block."""
    var opener = "comptime " + name + ' = """'
    var at = source.find(opener)
    if at < 0:
        raise Error("no `" + opener + "` block")
    var start = at + opener.byte_length()
    var end = source.find('"""', start)
    if end < 0:
        raise Error("the `" + name + "` block is not closed")
    return String(source[byte=start:end])


def _in(xs: List[String], x: String) -> Bool:
    for i in range(len(xs)):
        if xs[i] == x:
            return True
    return False


def _words(line: String) -> List[String]:
    var out = List[String]()
    for w in line.split(" "):
        if w.byte_length() > 0:
            out.append(String(w))
    return out^


def _has(problems: List[String], needle: String) -> Bool:
    for i in range(len(problems)):
        if problems[i].find(needle) >= 0:
            return True
    return False


def _report(problems: List[String]) -> String:
    var out = String("")
    for i in range(len(problems)):
        out += "\n  " + problems[i]
    return out


# ---- the comparisons ------------------------------------------------------------


def _compare(
    declared: List[String], optimized: List[String], expected: List[String], held: List[String]
) raises -> List[String]:
    """Problems between what the .proto files reserve (`declared`; the
    subset from optimized_plan.proto is `optimized`), RESERVED (`expected`)
    and the HELD rows (`held`)."""
    var problems = List[String]()
    for i in range(len(declared)):
        if not _in(expected, declared[i]):
            problems.append("the .proto reserves `" + declared[i] + "`, which RESERVED does not list")
        for j in range(i):
            if declared[j] == declared[i]:
                problems.append("the .proto reserves `" + declared[i] + "` twice")
    for i in range(len(expected)):
        if not _in(declared, expected[i]):
            problems.append("RESERVED lists `" + expected[i] + "`, which no `reserved` statement declares")
    var held_reserved = List[String]()
    for line in held:
        var w = _words(line)
        if len(w) != 4 or (w[3] != "held" and w[3] != "reserved"):
            raise Error("malformed HELD row: `" + line + "`")
        var row = w[0] + " " + w[1]
        if w[3] == "reserved":
            held_reserved.append(row)
            if not _in(optimized, row):
                problems.append("HELD row `" + line + "`: optimized_plan.proto does not reserve " + row)
        elif _in(optimized, row):
            problems.append("HELD row `" + line + "`: a held number is reserved, so its field can never be added")
    for row in optimized:
        if _is_number(_words(row)[1]) and not _in(held_reserved, row):
            problems.append("optimized_plan.proto reserves " + row + ", which no HELD `reserved` row writes")
    return problems^


def _check(
    proto_texts: List[String], optimized_text: String, expected: List[String], held: List[String]
) raises -> List[String]:
    var declared = List[String]()
    for text in proto_texts:
        var rows = _reserved(text)
        for row in rows:
            declared.append(row)
    return _compare(declared, _reserved(optimized_text), expected, held)


def _run(text: String, others: List[String], expected: List[String], held: List[String]) raises -> List[String]:
    """`_check` with `text` standing for optimized_plan.proto."""
    var texts = others.copy()
    texts.append(text)
    return _check(texts, text, expected, held)


def _refuses(text: String, message: String) -> Bool:
    """`_reserved` raises on `text` with exactly `message`."""
    try:
        _ = _reserved(text)
    except e:
        return String(e) == message
    return False


def _unreadable(item: String) -> String:
    """The message `_item` raises for an item of message `A` it cannot read."""
    return "`reserved` in A: an item the reservation scan cannot read: `" + item + "`"


def _held_refused(row: String) -> Bool:
    """`_compare` raises on the HELD row `row` with exactly the malformed-row message."""
    var held: List[String] = [row]
    try:
        _ = _compare(List[String](), List[String](), List[String](), held)
    except e:
        return String(e) == "malformed HELD row: `" + row + "`"
    return False


def _without(text: String, line: String) raises -> String:
    var at = text.find(line + "\n")
    if at < 0:
        raise Error("planted defect: the .proto has no line `" + line + "`")
    return String(text[byte=0:at]) + String(text[byte = at + line.byte_length() + 1 : text.byte_length()])


def _with_after(text: String, anchor: String, added: String) raises -> String:
    var at = text.find(anchor)
    if at < 0:
        raise Error("planted defect: the .proto has no `" + anchor + "`")
    var cut = at + anchor.byte_length()
    return String(text[byte=0:cut]) + added + String(text[byte=cut : text.byte_length()])


# ---- the test --------------------------------------------------------------------


def main() raises:
    var others = List[String]()
    var optimized = String("")
    var protos = 0
    for name in listdir("protos"):
        var f = String(name)
        assert_true(f.endswith(".proto"), "protos/ holds only the library's .proto srcs: " + f)
        var text = Path("protos/" + f).read_text()
        if f == _OPTIMIZED:
            optimized = text
        else:
            others.append(text)
        protos += 1
    assert_true(optimized.byte_length() > 0, _OPTIMIZED + " is staged under protos/")
    var expected = _rows(String(RESERVED))
    var held = _rows(_block(Path(_HELD_SOURCE).read_text(), "HELD"))
    assert_true(len(held) > 0, "HELD has rows")

    var all_texts = others.copy()
    all_texts.append(optimized)
    var problems = _check(all_texts, optimized, expected, held)
    assert_equal(len(problems), 0, "the komira.plan.v1 reservations disagree:" + _report(problems))

    # Planted defects, each of which must be reported.
    var no_numbers = String(optimized)
    var number_lines: List[String] = ["  reserved 4;", "  reserved 3;", "  reserved 6, 7;", "  reserved 11;"]
    for line in number_lines:
        no_numbers = _without(no_numbers, line)
    var p = _run(no_numbers, others, expected, held)
    assert_true(_has(p, "RESERVED lists `ProducerStamp 4`"), "a deleted reserved number is reported" + _report(p))
    assert_true(_has(p, "RESERVED lists `DeclaredNeeds 7`"), "one number of a list is reported" + _report(p))
    assert_true(
        _has(p, "HELD row `OptimizedSegment 11 len reserved`: optimized_plan.proto does not reserve"),
        "a HELD reserved row whose number is free is reported" + _report(p),
    )
    var no_name = _without(optimized, '  reserved "physical";')
    p = _run(no_name, others, expected, held)
    assert_true(_has(p, 'RESERVED lists `OptimizedSegment "physical"`'), "a deleted reserved name is reported" + _report(p))
    assert_equal(len(p), 1, "a name-only deletion is the only problem" + _report(p))
    var held_reserved = _with_after(optimized, "message ScanPin {", "\n  reserved 3 to 12;")
    held_reserved = _with_after(held_reserved, "message ExchangeEdge {", "\n  reserved 3, 5;")
    p = _run(held_reserved, others, expected, held)
    assert_true(
        _has(p, "HELD row `ScanPin 12 varint held`: a held number is reserved"), "a reserved held range is reported" + _report(p)
    )
    assert_true(
        _has(p, "HELD row `ExchangeEdge 5 varint held`: a held number is reserved"),
        "a reserved held number is reported" + _report(p),
    )
    assert_true(_has(p, "the .proto reserves `ScanPin 3`, which RESERVED"), "an added reservation is reported" + _report(p))
    var unlisted = _with_after(optimized, "message PinGroup {", '\n  reserved 13;\n  reserved "lineage_v0";')
    p = _run(unlisted, others, expected, held)
    assert_true(
        _has(p, "optimized_plan.proto reserves PinGroup 13, which no HELD"),
        "a reserved number with no HELD row is reported" + _report(p),
    )
    assert_true(_has(p, 'the .proto reserves `PinGroup "lineage_v0"`'), "an added reserved name is reported" + _report(p))
    var twice = _with_after(optimized, "message PinGroup {", "\n  reserved 13;\n  reserved 13;")
    p = _run(twice, others, expected, held)
    assert_true(_has(p, "`PinGroup 13` twice"), "a number reserved twice is reported" + _report(p))
    # The same two directions in a .proto other than optimized_plan.proto
    # (plan_vocabulary.proto's PlanTag), with optimized_plan.proto as staged.
    var vocab = -1
    for i in range(len(others)):
        if others[i].find("enum PlanTag {") >= 0:
            vocab = i
    assert_true(vocab >= 0, "a .proto under protos/ declares `enum PlanTag {`")
    var others_added = others.copy()
    others_added[vocab] = _with_after(others[vocab], "enum PlanTag {", "\n  reserved 99;")
    p = _run(optimized, others_added, expected, held)
    assert_equal(len(p), 1, "a reservation added outside optimized_plan.proto is the only problem" + _report(p))
    assert_equal(
        p[0], "the .proto reserves `PlanTag 99`, which RESERVED does not list", "an added PlanTag reservation is reported"
    )
    var others_deleted = others.copy()
    others_deleted[vocab] = _without(others[vocab], "  reserved 17;  // PLAN_CONVERT_COLUMN_TO_ROW")
    p = _run(optimized, others_deleted, expected, held)
    assert_equal(len(p), 1, "a reservation deleted outside optimized_plan.proto is the only problem" + _report(p))
    assert_equal(
        p[0],
        "RESERVED lists `PlanTag 17`, which no `reserved` statement declares",
        "a deleted PlanTag reservation is reported",
    )
    var bad_held = held.copy()
    bad_held.append("ScanPin 13 len reserved")
    p = _compare(_reserved(optimized), _reserved(optimized), expected, bad_held)
    assert_true(_has(p, "HELD row `ScanPin 13 len reserved`"), "a HELD reserved row with no reservation is reported")
    assert_true(_held_refused("ScanPin 12 varint hold"), "a HELD row whose last word is neither held nor reserved is refused")
    assert_true(_held_refused("ScanPin 12 varint"), "a HELD row of three words is refused")
    assert_true(_held_refused("ScanPin 12 varint held x"), "a HELD row of five words is refused")

    # The scanner, one case per branch and per side of each bound.
    assert_true(_refuses("message A {\n  reserved 5 to max;\n}\n", _unreadable("5 to max")), "`max` is refused")
    assert_true(_refuses("message A {\n  reserved foo;\n}\n", _unreadable("foo")), "a bare identifier is refused")
    assert_true(
        _refuses("message A {\n  reserved 1 to 5000;\n}\n", "`reserved` in A: the range 1 to 5000 is over 1000 numbers"),
        "a huge range is refused",
    )
    assert_true(
        _refuses("message A {\n  reserved 1 to 1001;\n}\n", "`reserved` in A: the range 1 to 1001 is over 1000 numbers"),
        "1001 numbers is over the limit",
    )
    var thousand = _reserved("message A {\n  reserved 1 to 1000;\n}\n")
    assert_equal(len(thousand), 1000, "a range of exactly 1000 numbers is read in full")
    assert_equal(thousand[999], "A 1000", "the 1000-number range ends at its last number")
    assert_true(
        _refuses("message A {\n  reserved 5 to 3;\n}\n", "`reserved` in A: the range 5 to 3 is empty"),
        "an inverted range is refused, not read as nothing",
    )
    assert_true(
        _refuses("message A {\n  reserved 5 to 4;\n}\n", "`reserved` in A: the range 5 to 4 is empty"),
        "a range whose end is one below its start is refused",
    )
    var single = _reserved("message A {\n  reserved 4 to 4;\n}\n")
    assert_equal(len(single), 1, "a one-number range `4 to 4` is not empty")
    var field = _reserved("message A {\n  int32 reserved = 1;\n  reserved 2;\n}\n")
    assert_equal(len(field), 1, "a field named `reserved` is not a reserved statement")
    assert_equal(field[0], "A 2", "the statement after a `;` is read")
    var packed = _reserved('message A{reserved 2;}enum E{reserved "X";}')
    assert_equal(len(packed), 2, "`{`, `}` and `;` split tokens with no spaces round them")
    assert_equal(packed[1], 'E "X"', "a `{` with no space before it still opens the named type's body")
    assert_true(
        _refuses("A {\n  reserved 1;\n} message\n", "a `reserved` statement outside a message or enum body"),
        "a `{` second in the text has no `message` or `enum` before its name, whatever the last token is",
    )
    var spaced = _reserved("message A {\n  reserved 1\t,2\r,3\f,4\v,5;\n}\n")
    assert_equal(len(spaced), 5, "tab, carriage return, form feed and vertical tab separate tokens")
    var commented = _reserved("message A {\n  // reserved 9;\n  reserved 2; // reserved 8;\n}\n")
    assert_equal(len(commented), 1, "a `//` comment is not read")
    assert_equal(commented[0], "A 2", "the code before a `//` comment is read")
    var column0 = _reserved("message A {\n// note; reserved 9;\n// }\n  reserved 2;\n}\n")
    assert_equal(len(column0), 1, "a `//` comment that starts its line is not read")
    assert_equal(column0[0], "A 2", "the statement after column-0 comments is read")
    var digits = _reserved("message A {\n  reserved 0, 9, 90;\n}\n")
    assert_equal(len(digits), 3, "the digits 0 and 9 are read as numbers")
    assert_equal(digits[2], "A 90", "a number of the digits 9 and 0 is read")
    assert_true(_refuses("message A {\n  reserved 1/;\n}\n", _unreadable("1/")), "`/`, the byte below `0`, is not a digit")
    assert_true(_refuses("message A {\n  reserved 1:;\n}\n", _unreadable("1:")), "`:`, the byte above `9`, is not a digit")
    assert_true(_refuses("message A {\n  reserved -1;\n}\n", _unreadable("-1")), "a signed number is refused")
    assert_true(_refuses('message A {\n  reserved "";\n}\n', _unreadable('""')), "an empty name is refused")
    assert_true(_refuses('message A {\n  reserved "ab;\n}\n', _unreadable('"ab')), "a name with no closing quote is refused")
    assert_true(_refuses('message A {\n  reserved ab";\n}\n', _unreadable('ab"')), "a name with no opening quote is refused")
    assert_true(_refuses('message A {\n  reserved "a"b";\n}\n', _unreadable('"a"b"')), "a name with a quote inside is refused")
    assert_true(_refuses('message A {\n  reserved ""a";\n}\n', _unreadable('""a"')), "a quote just after the opening quote is refused")
    assert_true(_refuses('message A {\n  reserved "a"";\n}\n', _unreadable('"a""')), "a quote just before the closing quote is refused")
    assert_true(_refuses("message A {\n  reserved 1 2;\n}\n", _unreadable("1 2")), "two numbers with no comma are refused")
    assert_true(_refuses("message A {\n  reserved 1 too 5;\n}\n", _unreadable("1 too 5")), "a range without `to` is refused")
    assert_true(_refuses("message A {\n  reserved 1,,2;\n}\n", _unreadable("")), "an empty item is refused")
    assert_true(_refuses("}\n", "the .proto text closes a block it never opened"), "a `}` with no `{` is refused")
    assert_true(_refuses("reserved 1;\n", "a `reserved` statement outside a message or enum body"), "a top-level reserved is refused")
    assert_true(
        _refuses("message A {\n  oneof c {\n    reserved 1;\n  }\n}\n", "a `reserved` statement outside a message or enum body"),
        "a reserved inside a oneof is refused, not credited to the oneof",
    )
    assert_true(
        _refuses("message A {\n  reserved 1\n}\n", "`reserved` in A: the statement has no `;`"), "an unterminated statement is refused"
    )
    assert_true(
        _refuses("/* x */ message A {\n}\n", "the .proto text holds a /* */ comment, which the reservation scan does not read"),
        "a block comment at the start of the text is refused",
    )
    assert_true(
        _refuses("message A {\n}\n/* x */\n", "the .proto text holds a /* */ comment, which the reservation scan does not read"),
        "a block comment later in the text is refused",
    )
    assert_true(_refuses("message A {\n", "the .proto text leaves a block open"), "an open block is refused")
    var nested = _reserved("message A {\n  message B {\n    reserved 2;\n  }\n  oneof c {\n    int32 x = 1;\n  }\n  reserved 3;\n}\n")
    assert_equal(len(nested), 2, "a nested message and a oneof are read")
    assert_equal(nested[0], "B 2", "a nested message's reservation is its own")
    assert_equal(nested[1], "A 3", "the outer message's reservation after a nested block is its own")
    var spread = _reserved('enum E {\n  reserved\n    9 to 10 ,\n    "OLD" ;\n}\n')
    assert_equal(len(spread), 3, "a statement over lines with a range and a name")
    assert_equal(spread[1], "E 10", "a range's last number is reserved")
    assert_equal(spread[2], 'E "OLD"', "a name after a range")

    # The helpers that read this file and plant the defects above.
    var rows = _rows("\n x \n\n  \nab\n")
    assert_equal(len(rows), 2, "_rows drops blank lines and keeps a one-character line")
    assert_equal(rows[0], "x", "_rows strips a row")
    assert_equal(_block('comptime X = """a"""', "X"), "a", "_block reads a block at the start of the source")
    var missing = False
    try:
        _ = _block('comptime X = """a"""', "Y")
    except e:
        missing = String(e) == 'no `comptime Y = """` block'
    assert_true(missing, "_block refuses a source with no such block")
    var unclosed = False
    try:
        _ = _block('comptime X = """a', "X")
    except e:
        unclosed = String(e) == "the `X` block is not closed"
    assert_true(unclosed, "_block refuses a block with no closing quotes")
    assert_equal(_without("x\ny\n", "x"), "y\n", "_without removes the first line and its newline")
    assert_equal(_with_after("ab", "a", "X"), "aXb", "_with_after inserts right after an anchor at the start")
    var no_line = False
    try:
        _ = _without("x\n", "z")
    except e:
        no_line = String(e) == "planted defect: the .proto has no line `z`"
    assert_true(no_line, "_without refuses a line the text does not hold")
    var no_anchor = False
    try:
        _ = _with_after("x", "z", "y")
    except e:
        no_anchor = String(e) == "planted defect: the .proto has no `z`"
    assert_true(no_anchor, "_with_after refuses an anchor the text does not hold")

    print("THE komira.plan.v1 RESERVATIONS ARE PINNED:", len(expected), "rows,", len(held), "HELD rows,", protos, ".proto files")


# ---- RESERVED: `<Type> <number>` or `<Type> "<name>"` --------------------------
# Every number and name a `reserved` statement of the library's .proto files
# declares, under the message or enum that declares it. A reservation is
# permanent: remove a row only with its `reserved` line, and never for a
# number a released format carried.

comptime RESERVED = """
WireScalar 20
WireScalar "error_code"
WireExpr 1
WireExpr "tag"
WirePlan 1
WirePlan "tag"
WirePlan 3
WirePlan "orientation_plus_one"
PlanTag 17
PlanTag 18
ExprTag 11
ExprTag 12
SourceVariantTag 1
SourceVariantTag 2
ArrowType 51
ArrowType "ARROW_TYPE_ERROR"
ScalarKind 11
ScalarKind "SCALAR_KIND_ERROR"
ProducerStamp 4
DeclaredNeeds 3
DeclaredNeeds "images"
DeclaredNeeds 6
DeclaredNeeds 7
DeclaredNeeds "python_abi"
DeclaredNeeds "node_abi"
OptimizedSegment 11
OptimizedSegment "physical"
"""
