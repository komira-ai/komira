# =============================================================================
# The scalar value parsers' refusals and edge arms, and `parse_list_one_value`
# on malformed or unusual arrays.
# =============================================================================
#
#   * test_bool_refusals -- a 5-byte literal other than `false`, a 4-byte one
#     other than `true`, another length.
#   * test_date_refusals_and_leap_rule -- each separator position, a
#     non-digit in year, month and day (naming the position), month 0 and 13,
#     Feb 29 in 1900 (century, not leap), 2000 (400, leap) and 2023; year
#     0 January / February (the negative era of `_days_from_civil`) read
#     to their day numbers.
#   * test_int_refusals -- lone `-` and `+`, `+5`, a non-digit after the
#     first digit, 2^64 and 20 nines (UInt64 overflow, naming the digit),
#     Int64 max + 1 and min - 1, Int64 min.
#   * test_decimal_refusals_and_quotes -- precision 0 and 39, scale -1 and
#     scale > precision, a leading `+`, a quoted value (both quotes, and a
#     trailing quote only, the form the columnar materializer passes), a
#     value starting with `.`.
#   * test_list_refusals -- tape position past the end, a non-`[` tag, a
#     `null` element for an unsupported child type, an unquoted element for
#     a STRING child, a string element for an INT64 child, a `:` inside the
#     array, a tape cut before its `]`, a string whose closing quote is cut
#     or retagged.
#   * test_list_whitespace_and_escapes -- blanks after an element are
#     trimmed; escaped string elements are unescaped.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType

from komira_json_index.simd_primitives import TAG_COMMA
from komira_json_index.structural_index import (
    build_structural_index,
    StructuralIndex,
)
from komira_jsonl.value_parsers.parse_bool import parse_bool
from komira_jsonl.value_parsers.parse_date import parse_date32
from komira_jsonl.value_parsers.parse_decimal import parse_decimal128_unscaled
from komira_jsonl.value_parsers.parse_int import parse_int_i64
from komira_jsonl.value_parsers.parse_list import parse_list_one_value


def _b(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


def _bool_err(s: String) raises -> String:
    var b = _b(s)
    try:
        _ = parse_bool(Span(b), 0, len(b))
    except e:
        return String(e)
    raise Error("parse_bool accepted " + s)


def test_bool_refusals() raises:
    assert_equal(_bool_err("falsy"), "parse_bool: 5-byte literal is not 'false'")
    assert_equal(_bool_err("trux"), "parse_bool: 4-byte literal is not 'true'")
    assert_equal(
        _bool_err("no"),
        "parse_bool: literal must be 'true' (4 bytes) or 'false' (5 bytes);"
        " got 2 bytes",
    )


def _date(s: String) raises -> Int:
    var b = _b(s)
    return Int(parse_date32(Span(b), 0, len(b)))


def _date_err(s: String) raises -> String:
    try:
        _ = _date(s)
    except e:
        return String(e)
    raise Error("parse_date32 accepted " + s)


def test_date_refusals_and_leap_rule() raises:
    var sep = String("parse_date32: missing '-' separator (expected YYYY-MM-DD)")
    assert_equal(_date_err("2024/01-01"), sep)
    assert_equal(_date_err("2024-01/01"), sep)
    assert_equal(
        _date_err("20x4-01-01"), "parse_date32: non-digit in year at position 2"
    )
    assert_equal(
        _date_err("2024-0a-01"), "parse_date32: non-digit in month at position 6"
    )
    assert_equal(
        _date_err("2024-01-0x"), "parse_date32: non-digit in day at position 9"
    )
    assert_equal(
        _date_err("2024-13-01"), "parse_date32: month out of range [1, 12]: 13"
    )
    assert_equal(
        _date_err("2024-00-01"), "parse_date32: month out of range [1, 12]: 0"
    )
    assert_equal(
        _date_err("1900-02-29"),
        "parse_date32: day out of range for year=1900 month=2: 29",
    )
    assert_equal(
        _date_err("2023-02-29"),
        "parse_date32: day out of range for year=2023 month=2: 29",
    )
    assert_equal(_date("2000-02-29"), 11016)
    assert_equal(_date("1900-02-28"), -25509)
    # Year 0 January and February: y - 1 = -1, the negative era.
    assert_equal(_date("0000-01-01"), -719528)
    assert_equal(_date("0000-02-29"), -719469)
    assert_equal(_date("0000-03-01"), -719468)


def _int_err(s: String) raises -> String:
    var b = _b(s)
    try:
        _ = parse_int_i64(Span(b), 0, len(b))
    except e:
        return String(e)
    raise Error("parse_int_i64 accepted " + s)


def _int(s: String) raises -> Int64:
    var b = _b(s)
    return parse_int_i64(Span(b), 0, len(b))


def test_int_refusals() raises:
    assert_equal(_int_err("-"), "parse_int_i64: lone '-' sign without digits")
    assert_equal(_int_err("+"), "parse_int_i64: lone '+' sign without digits")
    assert_equal(_int("+5"), Int64(5))
    assert_equal(_int_err("1a"), "parse_int_i64: non-digit byte at position 1")
    assert_equal(
        _int_err("18446744073709551616"),
        "parse_int_i64: integer overflow at position 19",
    )
    assert_equal(
        _int_err("99999999999999999999"),
        "parse_int_i64: integer overflow at position 19",
    )
    assert_equal(
        _int_err("9223372036854775808"),
        "parse_int_i64: integer overflow (greater than Int64.MAX)",
    )
    assert_equal(
        _int_err("-9223372036854775809"),
        "parse_int_i64: integer underflow (less than Int64.MIN)",
    )
    assert_equal(_int("-9223372036854775808"), Int64(-9223372036854775808))


def _dec(s: String, p: Int, sc: Int) raises -> Int:
    var b = _b(s)
    return Int(parse_decimal128_unscaled(Span(b), 0, len(b), p, sc))


def _dec_err(s: String, p: Int, sc: Int) raises -> String:
    try:
        _ = _dec(s, p, sc)
    except e:
        return String(e)
    raise Error("parse_decimal128_unscaled accepted " + s)


def test_decimal_refusals_and_quotes() raises:
    var prec = String("parse_decimal128_unscaled: precision out of range [1, 38]: ")
    assert_equal(_dec_err("1", 0, 0), prec + "0")
    assert_equal(_dec_err("1", 39, 0), prec + "39")
    var sc = String("parse_decimal128_unscaled: scale out of range [0, precision]: ")
    assert_equal(_dec_err("1", 5, -1), sc + "-1")
    assert_equal(_dec_err("1", 5, 6), sc + "6")
    assert_equal(_dec("+1.5", 5, 2), 150)
    assert_equal(_dec('"12.5"', 5, 2), 1250)
    assert_equal(_dec('7"', 5, 0), 7)
    assert_equal(
        _dec_err(".5", 5, 2),
        "parse_decimal128_unscaled: non-digit at integer start position 0",
    )
    assert_equal(
        _dec_err('"x"', 5, 2),
        "parse_decimal128_unscaled: non-digit at integer start position 1",
    )


@fieldwise_init
struct _ListOut(Movable):
    var n: Int
    var ints: List[Int64]
    var floats: List[Float64]
    var bools: List[Bool]
    var strs: List[String]
    var dates: List[Int32]
    var nulls: List[Bool]
    var pos: Int


def _list_at(
    text: String, idx: StructuralIndex, at: ArrowType, pos: Int
) raises -> _ListOut:
    var b = _b(text)
    var out = _ListOut(
        0, List[Int64](), List[Float64](), List[Bool](), List[String](),
        List[Int32](), List[Bool](), pos,
    )
    out.n = Int(
        parse_list_one_value(
            Span(b), idx, out.pos, at, out.ints, out.floats, out.bools,
            out.strs, out.dates, out.nulls, 0,
        )
    )
    return out^


def _list(text: String, at: ArrowType) raises -> _ListOut:
    return _list_at(text, build_structural_index(text.as_bytes()), at, 0)


def _list_err_at(
    text: String, idx: StructuralIndex, at: ArrowType, pos: Int
) raises -> String:
    try:
        _ = _list_at(text, idx, at, pos)
    except e:
        return String(e)
    raise Error("parse_list_one_value accepted " + text)


def _list_err(text: String, at: ArrowType) raises -> String:
    return _list_err_at(text, build_structural_index(text.as_bytes()), at, 0)


def _first(idx: StructuralIndex, k: Int) -> StructuralIndex:
    var o = List[UInt32]()
    var t = List[UInt8]()
    for i in range(k):
        o.append(idx.offsets[i])
        t.append(idx.tags[i])
    return StructuralIndex(o^, t^)


def test_list_refusals() raises:
    var w = String("parse_list_one_value: ")
    var empty = String("[]")
    assert_equal(
        _list_err_at(empty, build_structural_index(empty.as_bytes()), ArrowType.INT64, 2),
        w + "tape position out of range",
    )
    assert_equal(
        _list_err("{}", ArrowType.INT64),
        w + "expected TAG_OPEN_BRACKET at tape pos 0, got tag=1",
    )
    assert_equal(
        _list_err("[null]", ArrowType.INT32),
        w + "child arrow_type " + String(Int(ArrowType.INT32.type_id))
        + " not supported",
    )
    assert_equal(
        _list_err("[abc]", ArrowType.STRING),
        w + "child arrow_type " + String(Int(ArrowType.STRING.type_id))
        + " expected a quoted form but got unquoted scalar at byte 1",
    )
    assert_equal(
        _list_err('["1"]', ArrowType.INT64),
        w + "child arrow_type " + String(Int(ArrowType.INT64.type_id))
        + " does not accept a JSON string element",
    )
    assert_equal(
        _list_err("[1:2]", ArrowType.INT64),
        w + "unexpected structural tag inside array: 5",
    )
    # `[1,2]`: [ , ] at 0 2 4. Cut before `]`.
    var two = String("[1,2]")
    var t2 = build_structural_index(two.as_bytes())
    assert_equal(
        _list_err_at(two, _first(t2, 2), ArrowType.INT64, 0),
        w + "unterminated array — no matching TAG_CLOSE_BRACKET for"
        " TAG_OPEN_BRACKET at byte 0",
    )
    # `["a"]`: [ " " ] at 0 1 3 4. The closing quote cut, then retagged.
    var s = String('["a"]')
    var ts = build_structural_index(s.as_bytes())
    var q = w + "missing TAG_QUOTE_CLOSE for string element at byte 1"
    assert_equal(_list_err_at(s, _first(ts, 2), ArrowType.STRING, 0), q)
    var retag = ts.copy()
    retag.tags[2] = TAG_COMMA
    assert_equal(_list_err_at(s, retag, ArrowType.STRING, 0), q)


def test_list_whitespace_and_escapes() raises:
    var r = _list("[1 , 2\t,\n3 ]", ArrowType.INT64)
    assert_equal(r.n, 3)
    assert_equal(len(r.ints), 3)
    assert_equal(r.ints[0], Int64(1))
    assert_equal(r.ints[1], Int64(2))
    assert_equal(r.ints[2], Int64(3))
    var s = _list('["a\\"b", "c\\nd", "plain"]', ArrowType.STRING)
    assert_equal(s.n, 3)
    assert_equal(s.strs[0], 'a"b')
    assert_equal(s.strs[1], "c\nd")
    assert_equal(s.strs[2], "plain")
    assert_false(s.nulls[0])
    assert_equal(s.pos, 10)


def main() raises:
    test_bool_refusals()
    test_date_refusals_and_leap_rule()
    test_int_refusals()
    test_decimal_refusals_and_quotes()
    test_list_refusals()
    test_list_whitespace_and_escapes()
    print("test_value_parser_refusals: all passed")
