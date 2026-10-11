# =============================================================================
# JSON writer value formatters and the row-native writer.
# =============================================================================
#
#   * test_escape_every_control_byte -- `write_string_escaped` on each byte
#     0x00..0x1F, alone (scalar tail) and inside a 16-byte chunk (SIMD
#     scan), against a table built here: `\b \t \n \f \r` take their
#     two-character form, the rest `\u00xx` with lowercase hex. A swapped or
#     missing arm in `_write_escaped_byte` changes one row of the table.
#   * test_append_helpers -- `_append_byte` and `_append_str_literal` append
#     exactly their bytes, in order (no caller in the package uses them).
#   * test_fast_dtoa_refuses_nan -- `_try_fast_decimal_dtoa` called with NaN
#     returns False and writes nothing.
#   * test_date32_year_sweeps -- `write_date32` on every day from
#     0000-01-01 to 0001-12-31 and of 1900..1901, 1969..1970, 2000..2001 and
#     2100..2101, against a day-by-day calendar counted here (month lengths,
#     the 4/100/400 leap rule): year 0 (`0000`), month ends and Feb 29. Each
#     date also reads back through `parse_date32` to the same day number.
#     Days before 0000-03-01 take the negative era (one day late before
#     komira-ai/komira#1114 was fixed); negative years are swept in
#     test_jsonl_date32_negative_era.mojo.
#   * test_decimal128_matches_int128 -- `write_decimal128` at scale 0 against
#     Mojo's own Int128 formatting for the Int128 extremes, values around
#     2^64 (the carry into the low word of `_u128_div10`) and a sequence of
#     generated values; then the decimal point at every scale 0..38 against
#     a string insertion done here.
#   * test_u128_div10_low_word_carry -- `_u128_div10(2^64 - 6, 1)`, the case
#     where `r_hi * 6 + low` passes 2^64.
#   * test_row_output_every_supported_tag -- `write_row_output_jsonl` with
#     INT64, INT32, FLOAT64 and STRING columns and a validity byte: values,
#     an all-null row, INT32 min and an empty string; a BOOL tag is refused
#     naming the tag. A layout with no columns writes one `{}` line per row
#     (komira-ai/komira#1139), asserted in test_jsonl_zero_column_rows.mojo.
# =============================================================================

from std.memory import bitcast
from std.testing import assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_collections.slab import Slab
from komira_row_format.row_block import (
    DT_BOOL,
    DT_F64,
    DT_I32,
    DT_I64,
    DT_STRING,
    RowBlock,
)
from komira_row_format.row_output import RowOutput, RowOutputLayout

from komira_jsonl.json_writer import (
    _append_byte,
    _append_str_literal,
    _try_fast_decimal_dtoa,
    _u128_div10,
    write_date32,
    write_decimal128,
    write_row_output_jsonl,
    write_string_escaped,
)
from komira_jsonl.value_parsers.parse_date import parse_date32


def _text(buf: List[UInt8]) -> String:
    return String(unsafe_from_utf8=Span(buf))


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


def test_escape_every_control_byte() raises:
    for b in range(0x20):
        # Alone: the scalar tail.
        var one = List[UInt8]()
        one.append(UInt8(b))
        var buf = List[UInt8]()
        write_string_escaped(buf, String(unsafe_from_utf8=Span(one)))
        assert_equal(_text(buf), '"' + _expected_escape(b) + '"', String(b))
        # At position 5 of a 20-byte string: found by the 16-byte scan.
        var long = List[UInt8]()
        for i in range(20):
            long.append(UInt8(b) if i == 5 else UInt8(0x61))
        var lbuf = List[UInt8]()
        write_string_escaped(lbuf, String(unsafe_from_utf8=Span(long)))
        assert_equal(
            _text(lbuf),
            '"aaaaa' + _expected_escape(b) + 'aaaaaaaaaaaaaa"',
            String(b),
        )


def test_append_helpers() raises:
    var buf = List[UInt8]()
    _append_byte(buf, UInt8(0x7B))
    _append_str_literal(buf, "ab")
    _append_byte(buf, UInt8(0x00))
    assert_equal(len(buf), 4)
    assert_equal(Int(buf[0]), 0x7B)
    assert_equal(Int(buf[1]), 0x61)
    assert_equal(Int(buf[2]), 0x62)
    assert_equal(Int(buf[3]), 0)


def test_fast_dtoa_refuses_nan() raises:
    var buf = List[UInt8]()
    var nan = bitcast[DType.float64](UInt64(0x7FF8000000000000))
    assert_false(_try_fast_decimal_dtoa(buf, nan))
    assert_equal(len(buf), 0)


def _pad(v: Int, width: Int) -> String:
    var s = String(v)
    while s.byte_length() < width:
        s = "0" + s
    return s


def _is_leap(y: Int) -> Bool:
    return (y % 4 == 0 and y % 100 != 0) or y % 400 == 0


def _month_days(y: Int, m: Int) -> Int:
    if m == 2:
        return 29 if _is_leap(y) else 28
    if m == 4 or m == 6 or m == 9 or m == 11:
        return 30
    return 31


def _sweep(first_day: Int, year: Int, month: Int, n_days: Int) raises:
    """Walk `n_days` days from `first_day`, the first of `month` in `year`."""
    var y = year
    var m = month
    var d = 1
    for k in range(n_days):
        var days = first_day + k
        var want = _pad(y, 4) + "-" + _pad(m, 2) + "-" + _pad(d, 2)
        var buf = List[UInt8]()
        write_date32(buf, Int32(days))
        assert_equal(_text(buf), '"' + want + '"', String(days))
        var wb = want.as_bytes()
        assert_equal(Int(parse_date32(wb, 0, len(wb))), days, want)
        d += 1
        if d > _month_days(y, m):
            d = 1
            m += 1
            if m > 12:
                m = 1
                y += 1


def test_date32_year_sweeps() raises:
    # From 0000-01-01 through 0001: the days before 0000-03-01 (day 0 of
    # the algorithm's shifted epoch) take the negative era (#1114).
    _sweep(-719528, 0, 1, 366 + 365)
    _sweep(-25567, 1900, 1, 365 + 365)  # 1900 is not leap
    _sweep(-365, 1969, 1, 365 + 365)
    _sweep(10957, 2000, 1, 366 + 365)  # 2000 is leap
    _sweep(47482, 2100, 1, 365 + 365)  # 2100 is not leap


def _i128(low: UInt64, high: Int64) -> Scalar[DType.int128]:
    return (Scalar[DType.int64](high).cast[DType.int128]() << 64) | (
        Scalar[DType.uint64](low).cast[DType.int128]()
    )


def _dec(low: UInt64, high: Int64, scale: Int) -> String:
    var buf = List[UInt8]()
    write_decimal128(buf, Int64(bitcast[DType.int64](low)), high, scale)
    return _text(buf)


def _scaled(digits: String, negative: Bool, scale: Int) -> String:
    """`digits` (no sign) with a decimal point before the last `scale`."""
    var out = String("-") if negative else String("")
    var n = digits.byte_length()
    if scale == 0:
        return out + digits
    if scale >= n:
        out += "0."
        for _ in range(scale - n):
            out += "0"
        return out + digits
    return (
        out + String(digits[byte=0 : n - scale]) + "."
        + String(digits[byte=n - scale : n])
    )


def _check_scale0(low: UInt64, high: Int64) raises:
    var want = String(_i128(low, high))
    assert_equal(_dec(low, high, 0), '"' + want + '"', want)


def test_decimal128_matches_int128() raises:
    var max_low = UInt64(0xFFFFFFFFFFFFFFFF)
    # Int128 max and min.
    _check_scale0(max_low, Int64(0x7FFFFFFFFFFFFFFF))
    assert_equal(
        _dec(UInt64(0), Int64(-9223372036854775808), 0),
        '"-170141183460469231731687303715884105728"',
    )
    # Around 2^64 and 2^65, both signs.
    for d in range(12):
        _check_scale0(max_low - UInt64(d), Int64(0))
        _check_scale0(max_low - UInt64(d), Int64(1))
        _check_scale0(UInt64(d), Int64(1))
        _check_scale0(max_low - UInt64(d), Int64(-1))
        _check_scale0(max_low - UInt64(d), Int64(-2))
        _check_scale0(UInt64(d), Int64(-1))
    # Generated values.
    var x = UInt64(0x9E3779B97F4A7C15)
    for _ in range(200):
        x = x * UInt64(6364136223846793005) + UInt64(1442695040888963407)
        var lo = x
        x = x * UInt64(6364136223846793005) + UInt64(1442695040888963407)
        var hi = Int64(bitcast[DType.int64](x)) >> Int64(Int(x & 63))
        _check_scale0(lo, hi)
    # The point at every scale, for a 39-digit, a 21-digit, a 1-digit and
    # a zero value.
    var lows = List[UInt64]()
    var highs = List[Int64]()
    lows.append(max_low)
    highs.append(Int64(0x7FFFFFFFFFFFFFFF))
    lows.append(max_low - UInt64(5))
    highs.append(Int64(-2))
    lows.append(UInt64(7))
    highs.append(Int64(0))
    lows.append(UInt64(0))
    highs.append(Int64(0))
    for v in range(len(lows)):
        var i = _i128(lows[v], highs[v])
        var neg = i < 0
        var digits = String(-i) if neg else String(i)
        for scale in range(39):
            assert_equal(
                _dec(lows[v], highs[v], scale),
                '"' + _scaled(digits, neg, scale) + '"',
                digits + " scale " + String(scale),
            )


def test_u128_div10_low_word_carry() raises:
    # (2^64 + 2^64 - 6) / 10 = 3689348814741910322 rest 6.
    var r = _u128_div10(UInt64(0xFFFFFFFFFFFFFFFA), UInt64(1))
    assert_equal(r[0], UInt64(3689348814741910322))
    assert_equal(r[1], UInt64(0))
    assert_equal(r[2], UInt64(6))
    # 2^65 - 1 = 36893488147419103231: 3689348814741910323 rest 1.
    var s = _u128_div10(UInt64(0xFFFFFFFFFFFFFFFF), UInt64(1))
    assert_equal(s[0], UInt64(3689348814741910323))
    assert_equal(s[2], UInt64(1))
    # 9 * 2^64 + 2^64 - 1 = 10 * 2^64 - 1: quotient 2^64 - 1 rest 9.
    var t = _u128_div10(UInt64(0xFFFFFFFFFFFFFFFF), UInt64(9))
    assert_equal(t[0], UInt64(0xFFFFFFFFFFFFFFFF))
    assert_equal(t[1], UInt64(0))
    assert_equal(t[2], UInt64(9))


comptime _STRIDE = 40
comptime _VALIDITY = 32


def _row_schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("i", ArrowType.INT64, True))
    sb.add_field(Field("j", ArrowType.INT32, True))
    sb.add_field(Field("f", ArrowType.FLOAT64, True))
    sb.add_field(Field("s", ArrowType.STRING, True))
    return sb.build()


def _layout(var tags: List[UInt8]) -> RowOutputLayout:
    var offsets = List[Int]()
    offsets.append(0)
    offsets.append(8)
    offsets.append(16)
    offsets.append(24)
    return RowOutputLayout(offsets^, tags^, _VALIDITY, True)


def _row_block() raises -> RowBlock:
    var blk = RowBlock.with_capacity(3, 64, _STRIDE)
    for r in range(3):
        blk.write_fixed[DType.uint8](r, _VALIDITY, UInt8(0))
    blk.write_fixed[DType.int64](0, 0, Int64(-3))
    blk.write_fixed[DType.int32](0, 8, Int32(7))
    blk.write_fixed[DType.float64](0, 16, Float64(1.5))
    var q = String('q"')
    blk.write_var_string_cell(0, 24, q.as_bytes())
    for c in range(4):
        blk.set_cell_null(1, _VALIDITY, c)
    blk.write_fixed[DType.int64](2, 0, Int64(5))
    blk.write_fixed[DType.int32](2, 8, Int32(-2147483648))
    blk.write_fixed[DType.float64](2, 16, Float64(0.25))
    var empty = List[UInt8]()
    blk.write_var_string_cell(2, 24, Span(empty))
    blk.set_n_rows(3)
    return blk^


def _tags(third: UInt8) -> List[UInt8]:
    var t = List[UInt8]()
    t.append(DT_I64)
    t.append(DT_I32)
    t.append(third)
    t.append(DT_STRING)
    return t^


def test_row_output_every_supported_tag() raises:
    var blocks = Slab[RowBlock]()
    blocks.append(_row_block())
    var ro = RowOutput(blocks^, _layout(_tags(DT_F64)), _row_schema())
    var buf = List[UInt8]()
    write_row_output_jsonl(buf, ro)
    assert_equal(
        _text(buf),
        String(
            '{"i":-3,"j":7,"f":1.5,"s":"q\\""}\n'
            '{"i":null,"j":null,"f":null,"s":null}\n'
            '{"i":5,"j":-2147483648,"f":0.25,"s":""}\n'
        ),
    )
    # A tag outside the supported subset is refused.
    var bad_blocks = Slab[RowBlock]()
    bad_blocks.append(_row_block())
    var bad = RowOutput(
        bad_blocks^, _layout(_tags(DT_BOOL)), _row_schema()
    )
    var msg = String()
    var out = List[UInt8]()
    try:
        write_row_output_jsonl(out, bad)
    except e:
        msg = String(e)
    assert_equal(
        msg,
        "write_row_output_jsonl: output DType tag " + String(Int(DT_BOOL))
        + " outside the row-streaming supported subset.",
    )


def main() raises:
    test_escape_every_control_byte()
    test_append_helpers()
    test_fast_dtoa_refuses_nan()
    test_date32_year_sweeps()
    test_decimal128_matches_int128()
    test_u128_div10_low_word_carry()
    test_row_output_every_supported_tag()
    print("test_writer_scalars_rows: all passed")
