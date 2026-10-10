# =============================================================================
# `parse_map_one_value` and `parse_struct_one_value` on malformed objects,
# escaped keys and values, blanks, nulls of every child type and missing
# children.
# =============================================================================
#
# Each refusal is checked by its whole message, so a guard that fires for
# the wrong reason (or names the wrong byte) fails. A tape is cut (`_first`)
# or retagged to reach each `t >= len or tag != X` guard both ways.
#
#   * test_map_refusals -- position past the end, a non-`{` tag, an
#     unquoted key, a key's closing quote cut or retagged, no colon (cut
#     and in the text), no value after the colon, a value's closing quote
#     cut or retagged, a string value for INT64, a nested value, an empty
#     scalar, a `null` for an unsupported value type, an unquoted value for
#     STRING, a tape cut after a comma.
#   * test_map_values -- escaped keys and string values are unescaped,
#     blanks around a scalar trimmed, `null` for BOOL, STRING and DATE32
#     values appends a placeholder and a null bit.
#   * test_struct_refusals -- the same guards for the struct parser, plus a
#     missing child of an unsupported type and a string for an INT64 child.
#   * test_struct_values -- missing FLOAT64 and DATE32 children read null; a
#     key of another length than a child's name (`ff` after `f`) is not
#     that child; escaped string
#     values; blanks around a scalar; `null` for FLOAT64, BOOL and DATE32.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType

from komira_json_index.simd_primitives import TAG_CLOSE_BRACE, TAG_COLON
from komira_json_index.structural_index import (
    build_structural_index,
    StructuralIndex,
)
from komira_jsonl.value_parsers.parse_map import parse_map_one_value
from komira_jsonl.value_parsers.parse_struct import parse_struct_one_value


def _b(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


def _first(idx: StructuralIndex, k: Int) -> StructuralIndex:
    var o = List[UInt32]()
    var t = List[UInt8]()
    for i in range(k):
        o.append(idx.offsets[i])
        t.append(idx.tags[i])
    return StructuralIndex(o^, t^)


def _retag(idx: StructuralIndex, i: Int, tag: UInt8) -> StructuralIndex:
    var r = idx.copy()
    r.tags[i] = tag
    return r^


def _tape(text: String) raises -> StructuralIndex:
    return build_structural_index(text.as_bytes())


def _tid(at: ArrowType) -> String:
    return String(Int(at.type_id))


# --- map ---------------------------------------------------------------------


@fieldwise_init
struct _MapOut(Movable):
    var n: Int
    var keys: List[String]
    var ints: List[Int64]
    var floats: List[Float64]
    var bools: List[Bool]
    var strs: List[String]
    var dates: List[Int32]
    var nulls: List[Bool]


def _map_at(
    text: String, idx: StructuralIndex, at: ArrowType, pos: Int
) raises -> _MapOut:
    var b = _b(text)
    var out = _MapOut(
        0, List[String](), List[Int64](), List[Float64](), List[Bool](),
        List[String](), List[Int32](), List[Bool](),
    )
    var p = pos
    out.n = Int(
        parse_map_one_value(
            Span(b), idx, p, at, out.keys, out.ints, out.floats, out.bools,
            out.strs, out.dates, out.nulls, 0,
        )
    )
    return out^


def _map_err_at(
    text: String, idx: StructuralIndex, at: ArrowType, pos: Int
) raises -> String:
    try:
        _ = _map_at(text, idx, at, pos)
    except e:
        return String(e)
    raise Error("parse_map_one_value accepted " + text)


def _map_err(text: String, at: ArrowType) raises -> String:
    return _map_err_at(text, _tape(text), at, 0)


def test_map_refusals() raises:
    var w = String("parse_map_one_value: ")
    var I = ArrowType.INT64
    assert_equal(_map_err_at("{}", _tape("{}"), I, 2), w + "tape position out of range")
    assert_equal(_map_err("[]", I), w + "expected TAG_OPEN_BRACE at tape pos 0")
    assert_equal(
        _map_err("{1:2}", I), w + "expected TAG_QUOTE_OPEN for key at tape pos 1"
    )
    # `{"k":"v"}`: { " " : " " } at 0 1 3 4 5 7 8.
    var kv = String('{"k":"v"}')
    var t = _tape(kv)
    var S = ArrowType.STRING
    var key_q = w + "missing TAG_QUOTE_CLOSE for key at byte 1"
    assert_equal(_map_err_at(kv, _first(t, 2), S, 0), key_q)
    assert_equal(_map_err_at(kv, _retag(t, 2, TAG_COLON), S, 0), key_q)
    var colon = w + "expected TAG_COLON after key at byte 1"
    assert_equal(_map_err_at(kv, _first(t, 3), S, 0), colon)
    assert_equal(_map_err('{"k" 1}', I), colon)
    assert_equal(
        _map_err_at(kv, _first(t, 4), S, 0),
        w + "truncated input (expected value after key)",
    )
    var val_q = w + "missing TAG_QUOTE_CLOSE for value at byte 5"
    assert_equal(_map_err_at(kv, _first(t, 5), S, 0), val_q)
    assert_equal(_map_err_at(kv, _retag(t, 5, TAG_CLOSE_BRACE), S, 0), val_q)
    assert_equal(
        _map_err(kv, I),
        w + "value arrow_type " + _tid(I) + " does not accept a JSON string value",
    )
    var nested = w + (
        "nested LIST/STRUCT/MAP map values are not supported (single-level"
        " nesting only)"
    )
    assert_equal(_map_err('{"k":[1]}', I), nested)
    assert_equal(_map_err('{"k":{}}', I), nested)
    assert_equal(
        _map_err('{"k": }', I), w + "empty scalar value after key at byte 1"
    )
    assert_equal(
        _map_err('{"k":null}', ArrowType.INT32),
        w + "value arrow_type " + _tid(ArrowType.INT32) + " not supported",
    )
    assert_equal(
        _map_err('{"k":abc}', S),
        w + "value arrow_type " + _tid(S)
        + " expects quoted form but got unquoted scalar at byte 5",
    )
    # `{"k":1,"j":2}`: cut after the comma at byte 6.
    var two = String('{"k":1,"j":2}')
    assert_equal(
        _map_err_at(two, _first(_tape(two), 5), I, 0),
        w + "unterminated object — no matching TAG_CLOSE_BRACE for"
        " TAG_OPEN_BRACE at byte 0",
    )


def test_map_values() raises:
    var s = _map_at(
        '{"k\\"1":"a\\tb", "k2" : "plain"}',
        _tape('{"k\\"1":"a\\tb", "k2" : "plain"}'),
        ArrowType.STRING,
        0,
    )
    assert_equal(s.n, 2)
    assert_equal(s.keys[0], 'k"1')
    assert_equal(s.keys[1], "k2")
    assert_equal(s.strs[0], "a\tb")
    assert_equal(s.strs[1], "plain")
    var i = _map_at('{"a": 7 ,"b":\t-1\n}', _tape('{"a": 7 ,"b":\t-1\n}'), ArrowType.INT64, 0)
    assert_equal(i.n, 2)
    assert_equal(i.ints[0], Int64(7))
    assert_equal(i.ints[1], Int64(-1))
    var nb = _map_at('{"a":null}', _tape('{"a":null}'), ArrowType.BOOL, 0)
    assert_equal(len(nb.bools), 1)
    assert_false(nb.bools[0])
    assert_true(nb.nulls[0])
    var ns = _map_at('{"a":null}', _tape('{"a":null}'), ArrowType.STRING, 0)
    assert_equal(len(ns.strs), 1)
    assert_equal(ns.strs[0], "")
    assert_true(ns.nulls[0])
    var nd = _map_at('{"a":null}', _tape('{"a":null}'), ArrowType.DATE32, 0)
    assert_equal(len(nd.dates), 1)
    assert_true(nd.nulls[0])


# --- struct ------------------------------------------------------------------


@fieldwise_init
struct _StructOut(Movable):
    var any: Bool
    var ints: List[List[Int64]]
    var floats: List[List[Float64]]
    var bools: List[List[Bool]]
    var strs: List[List[String]]
    var dates: List[List[Int32]]
    var nulls: List[List[Bool]]
    var pos: Int


def _struct_at(
    text: String,
    idx: StructuralIndex,
    names: List[String],
    types: List[ArrowType],
    pos: Int,
) raises -> _StructOut:
    var b = _b(text)
    var out = _StructOut(
        False, List[List[Int64]](), List[List[Float64]](), List[List[Bool]](),
        List[List[String]](), List[List[Int32]](), List[List[Bool]](), pos,
    )
    for _ in range(len(names)):
        out.ints.append(List[Int64]())
        out.floats.append(List[Float64]())
        out.bools.append(List[Bool]())
        out.strs.append(List[String]())
        out.dates.append(List[Int32]())
        out.nulls.append(List[Bool]())
    out.any = parse_struct_one_value(
        Span(b), idx, out.pos, names, types, out.ints, out.floats, out.bools,
        out.strs, out.dates, out.nulls, 0,
    )
    return out^


def _one_child(name: String) -> List[String]:
    var n = List[String]()
    n.append(name)
    return n^


def _one_type(at: ArrowType) -> List[ArrowType]:
    var t = List[ArrowType]()
    t.append(at)
    return t^


def _struct_err_at(
    text: String, idx: StructuralIndex, at: ArrowType, pos: Int
) raises -> String:
    try:
        _ = _struct_at(text, idx, _one_child("a"), _one_type(at), pos)
    except e:
        return String(e)
    raise Error("parse_struct_one_value accepted " + text)


def _struct_err(text: String, at: ArrowType) raises -> String:
    return _struct_err_at(text, _tape(text), at, 0)


def test_struct_refusals() raises:
    var w = String("parse_struct_one_value: ")
    var I = ArrowType.INT64
    var S = ArrowType.STRING
    assert_equal(
        _struct_err_at("{}", _tape("{}"), I, 2), w + "tape position out of range"
    )
    assert_equal(_struct_err("[]", I), w + "expected TAG_OPEN_BRACE at tape pos 0")
    assert_equal(
        _struct_err("{1:2}", I),
        w + "expected TAG_QUOTE_OPEN at tape pos 1, got tag=5",
    )
    # `{"a":"v"}`: { " " : " " } at 0 1 3 4 5 7 8.
    var kv = String('{"a":"v"}')
    var t = _tape(kv)
    var key_q = w + "missing TAG_QUOTE_CLOSE for key at byte 1"
    assert_equal(_struct_err_at(kv, _first(t, 2), S, 0), key_q)
    assert_equal(_struct_err_at(kv, _retag(t, 2, TAG_COLON), S, 0), key_q)
    var colon = w + "expected TAG_COLON after key at byte 1"
    assert_equal(_struct_err_at(kv, _first(t, 3), S, 0), colon)
    assert_equal(_struct_err('{"a" 1}', I), colon)
    assert_equal(
        _struct_err_at(kv, _first(t, 4), S, 0),
        w + "truncated input (expected value after key at byte 1)",
    )
    var val_q = w + "missing TAG_QUOTE_CLOSE for value at byte 5"
    assert_equal(_struct_err_at(kv, _first(t, 5), S, 0), val_q)
    assert_equal(_struct_err_at(kv, _retag(t, 5, TAG_CLOSE_BRACE), S, 0), val_q)
    assert_equal(
        _struct_err(kv, I),
        w + "child 'a' has non-string arrow_type but JSON value is a string",
    )
    assert_equal(
        _struct_err('{"a":\t}', I), w + "empty scalar value after key at byte 1"
    )
    assert_equal(
        _struct_err('{"a":null}', ArrowType.INT32),
        w + "child 'a' has unsupported arrow_type " + _tid(ArrowType.INT32),
    )
    assert_equal(
        _struct_err("{}", ArrowType.INT32),
        w + "child field a has unsupported arrow_type " + _tid(ArrowType.INT32),
    )
    assert_equal(
        _struct_err('{"a":abc}', S),
        w + "child 'a' expects quoted form but got unquoted scalar at byte 5",
    )
    var two = String('{"a":1,"b":2}')
    assert_equal(
        _struct_err_at(two, _first(_tape(two), 5), I, 0),
        w + "unterminated object — no matching TAG_CLOSE_BRACE for"
        " TAG_OPEN_BRACE at byte 0",
    )


def _names() -> List[String]:
    var n = List[String]()
    n.append("f")
    n.append("d")
    n.append("bb")
    n.append("s")
    return n^


def _types() -> List[ArrowType]:
    var t = List[ArrowType]()
    t.append(ArrowType.FLOAT64)
    t.append(ArrowType.DATE32)
    t.append(ArrowType.BOOL)
    t.append(ArrowType.STRING)
    return t^


def test_struct_values() raises:
    # Only "bb" (a key longer than "f" and "d") and "s": f and d are
    # missing. "ff" starts with the child name "f" but is another key.
    var text = String('{"bb": true ,"ff":9,"s":"x\\ny","zz":1}')
    var r = _struct_at(text, _tape(text), _names(), _types(), 0)
    assert_true(r.any)
    assert_equal(len(r.floats[0]), 1)
    assert_true(r.nulls[0][0])
    assert_equal(len(r.dates[1]), 1)
    assert_true(r.nulls[1][0])
    assert_true(r.bools[2][0])
    assert_false(r.nulls[2][0])
    assert_equal(r.strs[3][0], "x\ny")
    assert_false(r.nulls[3][0])
    # Explicit nulls for FLOAT64, DATE32, BOOL; s missing.
    var n = String('{"f":null,"d":null,"bb":null}')
    var rn = _struct_at(n, _tape(n), _names(), _types(), 0)
    assert_true(rn.any)
    assert_equal(len(rn.floats[0]), 1)
    assert_true(rn.nulls[0][0])
    assert_equal(len(rn.dates[1]), 1)
    assert_true(rn.nulls[1][0])
    assert_equal(len(rn.bools[2]), 1)
    assert_false(rn.bools[2][0])
    assert_true(rn.nulls[2][0])
    assert_equal(rn.strs[3][0], "")
    assert_true(rn.nulls[3][0])
    # Values: a float with blanks around it and a date.
    var v = String('{"f":\n 2.5 \t,"d":"1970-01-02"}')
    var rv = _struct_at(v, _tape(v), _names(), _types(), 0)
    assert_equal(rv.floats[0][0], 2.5)
    assert_false(rv.nulls[0][0])
    assert_equal(Int(rv.dates[1][0]), 1)


def main() raises:
    test_map_refusals()
    test_map_values()
    test_struct_refusals()
    test_struct_values()
    print("test_map_struct_parsers: all passed")
