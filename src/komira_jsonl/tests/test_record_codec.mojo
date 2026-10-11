# =============================================================================
# The record-level codec: `JsonCompatible` records through `encode` and
# `decode`, and the `encode` emit helpers.
# =============================================================================
#
#   * test_write_record_frames_each_line -- `write_record` appends the
#     record's `to_json()` and one LF; `write_records_into` does it per
#     record in order. Catches a missing or doubled LF, a dropped record,
#     and records written out of order.
#   * test_split_lines_chunks -- `decode.split_lines` on inputs shorter
#     than one 16-byte chunk, with LFs inside the first chunk (one or
#     several, and an LF as its last byte), lines spanning chunks, empty
#     lines and a last line with no LF. Each expected list is written out;
#     LF-only input (shorter than a chunk, and 17 LFs) returns no lines,
#     asserted by count (`parse_jsonl` relies on it: no empty line reaches
#     its skip).
#   * test_parse_record_and_parse_jsonl -- `parse_record` hands the text to
#     `T.from_json`; `parse_jsonl` decodes one record per non-empty line in
#     file order, and a bad line raises from `from_json`.
#   * test_emit_helpers -- `_emit_int`, `_emit_int64`, `_emit_bool`,
#     `_emit_float64` (finite, NaN, +-Inf) and the five `_emit_optional_*`
#     with a value and with None (`null`).
#   * test_emit_string_escaped_control_bytes -- `_emit_string_escaped` on
#     each byte 0x00..0x1F against a table built here (`\b \t \n \f \r`,
#     else `\u00xx` lowercase): a swapped arm or an uppercase hex digit
#     changes one row.
#   * test_not_null_check_skips_null_rows -- `check_float_column_writable`
#     over a NOT NULL float column holding a null row (NaN underneath)
#     before a NaN: the null row is skipped and the NaN's own row is named.
#
# The records and lines here are ASCII; non-ASCII text through
# `write_record`, `write_batch_jsonl`, `split_lines` and `parse_jsonl`
# (komira-ai/komira#1116) is in test_jsonl_non_ascii_text.mojo.
# =============================================================================

from std.memory import bitcast
from std.testing import assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import Field, Schema, SchemaBuilder

from komira_jsonl.decode import parse_jsonl, parse_record, split_lines
from komira_jsonl.encode import (
    _emit_bool,
    _emit_float64,
    _emit_int,
    _emit_int64,
    _emit_optional_bool,
    _emit_optional_float64,
    _emit_optional_int,
    _emit_optional_int64,
    _emit_optional_string,
    _emit_string_escaped,
    check_float_column_writable,
    write_record,
    write_records_into,
)
from komira_jsonl.json_compatible import JsonCompatible
from komira_jsonl.value_parsers.parse_int import parse_int_i64


@fieldwise_init
struct _Rec(JsonCompatible):
    """`{"id":<int>,"ok":<bool>}`. `from_json` reads exactly that shape."""

    var id: Int
    var ok: Bool

    def to_json(self) raises -> String:
        return '{"id":' + _emit_int(self.id) + ',"ok":' + _emit_bool(self.ok) + "}"

    @staticmethod
    def from_json(s: String) raises -> Self:
        var b = s.as_bytes()
        var n = len(b)
        if not s.startswith('{"id":'):
            raise Error("_Rec.from_json: no id in " + s)
        var i = 6
        while i < n and b[i] != UInt8(0x2C):
            i += 1
        var id = Int(parse_int_i64(b, 6, i))
        var ok: Bool
        if s.endswith(',"ok":true}'):
            ok = True
        elif s.endswith(',"ok":false}'):
            ok = False
        else:
            raise Error("_Rec.from_json: no ok in " + s)
        return Self(id, ok)


def _text(buf: List[UInt8]) -> String:
    return String(unsafe_from_utf8=Span(buf))


def test_write_record_frames_each_line() raises:
    var buf = List[UInt8]()
    write_record(buf, _Rec(7, True))
    assert_equal(_text(buf), '{"id":7,"ok":true}\n')
    var recs = List[_Rec]()
    recs.append(_Rec(-1, False))
    recs.append(_Rec(20, True))
    recs.append(_Rec(0, False))
    write_records_into(buf, recs)
    assert_equal(
        _text(buf),
        String(
            '{"id":7,"ok":true}\n{"id":-1,"ok":false}\n'
            '{"id":20,"ok":true}\n{"id":0,"ok":false}\n'
        ),
    )
    var none = List[UInt8]()
    write_records_into(none, List[_Rec]())
    assert_equal(len(none), 0)


def _split(text: String) raises -> String:
    """The lines `split_lines` returns, joined with `|`."""
    var lines = split_lines(text.as_bytes())
    var out = String()
    for i in range(len(lines)):
        if i > 0:
            out += "|"
        out += lines[i]
    return out


def test_split_lines_chunks() raises:
    assert_equal(len(split_lines(String("").as_bytes())), 0)
    # Shorter than a chunk: the scalar tail only.
    assert_equal(_split("a\n\nbb\n"), "a|bb")
    assert_equal(_split("abc"), "abc")
    # LF-only input returns no lines at all, not one empty line (the
    # joined form cannot tell the two apart): scalar tail, and a full
    # 16-byte chunk of LFs plus a tail.
    assert_equal(len(split_lines(String("\n").as_bytes())), 0)
    assert_equal(len(split_lines(String("\n\n").as_bytes())), 0)
    assert_equal(len(split_lines(String("\n" * 17).as_bytes())), 0)
    # LFs inside the first 16 bytes: two lines and an empty one in the
    # chunk, then a last line spanning into the tail with no LF.
    assert_equal(_split("ab\ncd\n\nefghijklmnopqrstu"), "ab|cd|efghijklmnopqrstu")
    # The 16th byte is the LF: the chunk ends a line exactly.
    assert_equal(_split("0123456789abcde\nXY\n"), "0123456789abcde|XY")
    # No LF in the first chunk: the line spans 2 chunks and the tail.
    assert_equal(
        _split("0123456789abcdef0123456789abcdefZZ\nq"),
        "0123456789abcdef0123456789abcdefZZ|q",
    )
    # LF as the first byte of the second chunk, then a whole chunk of LFs.
    assert_equal(
        _split("0123456789abcdef\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\nend\n"),
        "0123456789abcdef|end",
    )


def test_parse_record_and_parse_jsonl() raises:
    var r = parse_record[_Rec](String('{"id":42,"ok":true}'))
    assert_equal(r.id, 42)
    assert_true(r.ok)
    var text = String('{"id":1,"ok":true}\n\n{"id":2,"ok":false}\n{"id":3,"ok":true}')
    var recs = parse_jsonl[_Rec](text.as_bytes())
    assert_equal(len(recs), 3)
    assert_equal(recs[0].id, 1)
    assert_equal(recs[1].id, 2)
    assert_true(not recs[1].ok)
    assert_equal(recs[2].id, 3)
    assert_equal(len(parse_jsonl[_Rec](String("\n\n").as_bytes())), 0)
    var msg = String()
    try:
        _ = parse_jsonl[_Rec](String('{"id":1,"ok":true}\n{"x":1}\n').as_bytes())
    except e:
        msg = String(e)
    assert_equal(msg, '_Rec.from_json: no id in {"x":1}')


def test_emit_helpers() raises:
    assert_equal(_emit_int(-12), "-12")
    assert_equal(_emit_int64(Int64(-9223372036854775808)), "-9223372036854775808")
    assert_equal(_emit_bool(True), "true")
    assert_equal(_emit_bool(False), "false")
    assert_equal(_emit_float64(Float64(1.5)), "1.5")
    assert_equal(_emit_float64(bitcast[DType.float64](UInt64(0x7FF8000000000000))), "null")
    assert_equal(_emit_float64(bitcast[DType.float64](UInt64(0x7FF0000000000000))), "null")
    assert_equal(_emit_float64(bitcast[DType.float64](UInt64(0xFFF0000000000000))), "null")
    assert_equal(_emit_optional_int(Optional[Int](5)), "5")
    assert_equal(_emit_optional_int(Optional[Int](None)), "null")
    assert_equal(_emit_optional_int64(Optional[Int64](Int64(-6))), "-6")
    assert_equal(_emit_optional_int64(Optional[Int64](None)), "null")
    assert_equal(_emit_optional_float64(Optional[Float64](Float64(-0.5))), "-0.5")
    assert_equal(_emit_optional_float64(Optional[Float64](None)), "null")
    assert_equal(_emit_optional_bool(Optional[Bool](False)), "false")
    assert_equal(_emit_optional_bool(Optional[Bool](True)), "true")
    assert_equal(_emit_optional_bool(Optional[Bool](None)), "null")
    assert_equal(_emit_optional_string(Optional[String](String('a"'))), '"a\\""')
    assert_equal(_emit_optional_string(Optional[String](None)), "null")


def _hex_digit(n: Int) -> String:
    if n < 10:
        return chr(0x30 + n)
    return chr(0x61 + n - 10)


def _expected_escape(b: Int) -> String:
    if b == 0x08:
        return "\\b"
    if b == 0x09:
        return "\\t"
    if b == 0x0A:
        return "\\n"
    if b == 0x0C:
        return "\\f"
    if b == 0x0D:
        return "\\r"
    return "\\u00" + _hex_digit(b // 16) + _hex_digit(b % 16)


def test_emit_string_escaped_control_bytes() raises:
    for b in range(0x20):
        var one = List[UInt8]()
        one.append(UInt8(0x78))
        one.append(UInt8(b))
        var got = _emit_string_escaped(String(unsafe_from_utf8=Span(one)))
        assert_equal(got, '"x' + _expected_escape(b) + '"', String(b))


def test_not_null_check_skips_null_rows() raises:
    var arr = PrimitiveArray[DType.float64].allocate_nullable(3)
    # The null row holds a NaN underneath: only the validity bit says to
    # skip it.
    var nan = bitcast[DType.float64](UInt64(0x7FF8000000000000))
    arr.set(0, Float64(1.0))
    arr.set(1, nan)
    arr.set(2, nan)
    arr._set_null(1)
    var sb = SchemaBuilder()
    sb.add_field(Field("x", ArrowType.FLOAT64, False))
    var schema = sb.build()
    var msg = String()
    try:
        check_float_column_writable(arr, 0, 3, schema, 0)
    except e:
        msg = String(e)
    assert_true(
        msg.startswith("json_writer: column 'x' is NOT NULL and row 2 holds NaN"),
        msg,
    )
    # Rows [1, 2) hold only the null row: nothing to refuse.
    check_float_column_writable(arr, 1, 2, schema, 0)


def main() raises:
    test_write_record_frames_each_line()
    test_split_lines_chunks()
    test_parse_record_and_parse_jsonl()
    test_emit_helpers()
    test_emit_string_escaped_control_bytes()
    test_not_null_check_skips_null_rows()
    print("test_record_codec: all passed")
