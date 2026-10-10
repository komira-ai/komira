# =============================================================================
# test_held_numbers_are_unused.mojo
# =============================================================================
#
# THE HELD FIELD NUMBERS, DERIVED FROM THE PROTO ITSELF.
#
# Every `.proto` of the package declares its held numbers once, in
# `held-numbers:` lines of its header (a message name, then numbers and `a-b`
# ranges), and its retired numbers in `reserved` statements. This test reads
# the files' text (one after the other, in `_protos()` order: no message is
# declared in two), parses every message's fields, and refuses:
#   * a field whose number is held for its message (so `string x = 101;` in
#     `Resource` fails the build, not only the first number of each range);
#   * a field that reuses a number its own message reserved;
#   * a `held-numbers:` line naming a message the file does not declare (a
#     typo would hold nothing).
# The numbers are never written in this test: change the proto's lines, not
# this file. The mutation checks at the end run the same check over copies of
# the real text with one field added, and each must be refused.
# =============================================================================

from std.pathlib import Path
from std.testing import assert_equal, assert_true

comptime _HELD_PREFIX = "// held-numbers:"


def _code(line: String) -> String:
    var i = line.find("//")
    if i >= 0:
        return String(String(line[byte=0:i]).strip())
    return String(line.strip())


def _expand(tokens: List[String], start: Int) raises -> List[Int]:
    """The numbers of `tokens[start:]`, each `n` or `a-b`."""
    var out = List[Int]()
    for k in range(start, len(tokens)):
        var t = tokens[k]
        var dash = t.find("-")
        if dash < 0:
            out.append(Int(t))
        else:
            var lo = Int(String(t[byte=0:dash]))
            var hi = Int(String(t[byte = dash + 1 : t.byte_length()]))
            for n in range(lo, hi + 1):
                out.append(n)
    return out^


def _words(s: String) -> List[String]:
    var out = List[String]()
    for w in s.split(" "):
        if w.byte_length() > 0:
            out.append(String(w))
    return out^


def _has(xs: List[Int], n: Int) -> Bool:
    for i in range(len(xs)):
        if xs[i] == n:
            return True
    return False


struct _Scope(Copyable, Movable):
    var message: String
    var held: List[Int]
    var reserved: List[Int]
    var declared: Bool

    def __init__(out self, message: String):
        self.message = message.copy()
        self.held = List[Int]()
        self.reserved = List[Int]()
        self.declared = False

    def __init__(out self, *, copy: Self):
        self.message = copy.message.copy()
        self.held = copy.held.copy()
        self.reserved = copy.reserved.copy()
        self.declared = copy.declared


def _scope(mut scopes: List[_Scope], message: String) -> Int:
    for i in range(len(scopes)):
        if scopes[i].message == message:
            return i
    scopes.append(_Scope(message))
    return len(scopes) - 1


def _field_number(code: String) raises -> Int:
    """The number of a field line `type name = N;` / `... = N [..];`, or -1
    when the line is not a field."""
    if not code.endswith(";"):
        return -1
    # Whole words only: `optional string x = 6;` is a field, not an option.
    for p in ["option", "syntax", "package", "import", "reserved", "extensions"]:
        if code.startswith(p + String(" ")) or code.startswith(p + String("(")) or code.startswith(p + String("=")):
            return -1
    var eq = code.rfind("=")
    if eq < 0:
        return -1
    var rest = String(String(code[byte = eq + 1 : code.byte_length()]).strip())
    var end = rest.find("[")
    if end < 0:
        end = rest.find(";")
    var num = String(String(rest[byte=0:end]).strip())
    return Int(num)


def held_violations(text: String) raises -> List[String]:
    """Every held-number use, reserved-number reuse and dangling held line of
    the proto `text`."""
    var scopes = List[_Scope]()
    var out = List[String]()
    var lines = text.split("\n")
    # pass 1: the held lines
    for i in range(len(lines)):
        var raw = String(String(lines[i]).strip())
        if raw.startswith(_HELD_PREFIX):
            var w = _words(String(raw[byte = _HELD_PREFIX.byte_length() : raw.byte_length()]))
            if len(w) < 2:
                out.append(String("malformed held-numbers line: ") + raw)
                continue
            var s = _scope(scopes, w[0])
            var nums = _expand(w, 1)
            for k in range(len(nums)):
                scopes[s].held.append(nums[k])
    # pass 2: messages, reserved numbers and fields
    var stack = List[String]()  # "m:<name>", "oneof", "enum", "extend", "other"
    var fields_msg = List[String]()
    var fields_num = List[Int]()
    for i in range(len(lines)):
        var code = _code(String(lines[i]))
        if code.byte_length() == 0:
            continue
        var opens = code.count("{")
        var closes = code.count("}")
        if opens > 0:
            var kind = String("other")
            var ws = _words(code)
            if code.startswith("message ") and len(ws) >= 2:
                kind = String("m:") + ws[1]
                var s = _scope(scopes, ws[1])
                scopes[s].declared = True
            elif code.startswith("oneof "):
                kind = String("oneof")
            elif code.startswith("enum "):
                kind = String("enum")
            elif code.startswith("extend "):
                kind = String("extend")
            stack.append(kind)
            for _ in range(closes):
                _ = stack.pop()
            continue
        if closes > 0:
            for _ in range(closes):
                _ = stack.pop()
            continue
        # the innermost message, when no enum/extend block is inside it
        var msg = String("")
        var skip = False
        for k in range(len(stack) - 1, -1, -1):
            if stack[k] == "enum" or stack[k] == "extend":
                skip = True
                break
            if stack[k].startswith("m:"):
                msg = String(stack[k][byte=2 : stack[k].byte_length()])
                break
        if skip or msg.byte_length() == 0:
            continue
        if code.startswith("reserved ") and code.find('"') < 0:
            var body = String(code[byte=9 : code.byte_length() - 1])
            var toks = _words(body.replace(",", " "))
            var s = _scope(scopes, msg)
            var k = 0
            while k < len(toks):
                var lo = Int(toks[k])
                var hi = lo
                if k + 2 < len(toks) and toks[k + 1] == "to":
                    hi = Int(toks[k + 2])
                    k += 2
                for n in range(lo, hi + 1):
                    scopes[s].reserved.append(n)
                k += 1
            continue
        var n = _field_number(code)
        if n >= 0:
            fields_msg.append(msg.copy())
            fields_num.append(n)
    for k in range(len(fields_msg)):
        var s = _scope(scopes, fields_msg[k])
        if _has(scopes[s].held, fields_num[k]):
            out.append(
                fields_msg[k] + String(" uses held number ") + String(fields_num[k])
            )
        if _has(scopes[s].reserved, fields_num[k]):
            out.append(
                fields_msg[k] + String(" reuses reserved number ") + String(fields_num[k])
            )
    for s in range(len(scopes)):
        if not scopes[s].declared:
            out.append(
                String("held-numbers names message ") + scopes[s].message + String(", which the file does not declare")
            )
    return out^


def _protos() -> List[String]:
    """Every `.proto` of the package (BUCK's `_PROTOS`), in its order."""
    var l = List[String]()
    for name in [
        String("resource.proto"),
        String("refs.proto"),
        String("compute.proto"),
        String("data.proto"),
        String("identity.proto"),
        String("messaging.proto"),
        String("secrets.proto"),
        String("names.proto"),
        String("triggers.proto"),
        String("networks.proto"),
        String("artifacts.proto"),
        String("composite.proto"),
    ]:
        l.append(name)
    return l^


def _real() raises -> String:
    var text = String("")
    var names = _protos()
    for i in range(len(names)):
        text += Path(names[i]).read_text() + String("\n")
    return text^


def _insert_after(text: String, anchor: String, line: String) raises -> String:
    assert_equal(text.count(anchor), 1, String("anchor must be unique: ") + anchor)
    return text.replace(anchor, anchor + String("\n") + line)


def _joined(v: List[String]) -> String:
    var s = String("")
    for i in range(len(v)):
        s += v[i] + String("\n")
    return s^


def _held_total(text: String) raises -> Int:
    var total = 0
    var lines = text.split("\n")
    for i in range(len(lines)):
        var raw = String(String(lines[i]).strip())
        if raw.startswith(_HELD_PREFIX):
            var w = _words(String(raw[byte = _HELD_PREFIX.byte_length() : raw.byte_length()]))
            total += len(_expand(w, 1))
    return total


def test_the_proto_uses_no_held_or_reserved_number() raises:
    var v = held_violations(_real())
    assert_equal(len(v), 0, _joined(v))
    # The parser read the declarations: a parser that found none would pass
    # the line above vacuously.
    assert_true(_held_total(_real()) > 600, "the held lines expand to the documented ranges")
    # composite.proto's own line is read too: a number it holds is refused.
    var c = held_violations(
        _insert_after(_real(), String("  repeated Resource component = 4;"), String("  string variant = 8;"))
    )
    assert_equal(len(c), 1, _joined(c))
    assert_true(c[0].find("CompositeDefinition uses held number 8") >= 0, c[0])
    print("  test_the_proto_uses_no_held_or_reserved_number: PASS")


def test_a_held_number_or_a_reserved_number_is_refused() raises:
    var t = _real()
    var anchor = String("  string id = 1;")
    # inside a held range, not its first number
    var v = held_violations(_insert_after(t, anchor, String("  string x = 101;")))
    assert_equal(len(v), 1, _joined(v))
    assert_true(v[0].find("Resource uses held number 101") >= 0, v[0])
    # the last number of a range, and a single held number
    assert_equal(len(held_violations(_insert_after(t, anchor, String("  string x = 699;")))), 1)
    assert_equal(len(held_violations(_insert_after(t, anchor, String("  string x = 5;")))), 1)
    # a proto3 `optional` field is a field (its line starts with "option")
    var o = held_violations(_insert_after(t, anchor, String("  optional string x = 5;")))
    assert_equal(len(o), 1, String("an optional field at a held number: ") + _joined(o))
    # a number the message reserved
    var r = held_violations(_insert_after(t, anchor, String("  string x = 4;")))
    assert_equal(len(r), 1, _joined(r))
    assert_true(r[0].find("reuses reserved number 4") >= 0, r[0])
    # a held number of a primitive's own extension range
    var j = held_violations(_insert_after(t, String("  Image image = 1;\n  repeated string args = 2;"), String("  string x = 51;")))
    assert_equal(len(j), 1, _joined(j))
    # 9 is reserved on `Resource` (the deletable flag `Adoption` replaces)
    var nine = held_violations(_insert_after(t, anchor, String("  bool x = 9;")))
    assert_equal(len(nine), 1, _joined(nine))
    assert_true(nine[0].find("reuses reserved number 9") >= 0, nine[0])
    # a free number is fine, and so is the same number in another message
    assert_equal(len(held_violations(_insert_after(t, anchor, String("  string x = 38;")))), 0)
    assert_equal(len(held_violations(_insert_after(t, anchor, String("  string x = 37;")))), 0)
    # a held line for a message the file does not declare
    var d = held_violations(t + String("\n// held-numbers: NoSuchMessage 1-3\n"))
    assert_equal(len(d), 1, _joined(d))
    print("  test_a_held_number_or_a_reserved_number_is_refused: PASS")


def main() raises:
    print("test_held_numbers_are_unused: the held numbers, derived from every .proto of the package")
    test_the_proto_uses_no_held_or_reserved_number()
    test_a_held_number_or_a_reserved_number_is_refused()
    print("ALL HELD-NUMBER TESTS PASSED")
