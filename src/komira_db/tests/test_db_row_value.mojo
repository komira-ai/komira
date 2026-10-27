# =============================================================================
# komira_db/tests/test_db_row_value.mojo
# The value carriers' edges: the logical-type names, DbRow / DbRows bounds and
# NULL refusals, the integer-text decoder's refusals, INT4 reads, raw bytes
# with high bytes, out-of-range integer text and over-long UUID text, and the
# RAW_EXPR literal shapes a document backend reads.
# =============================================================================
# Every expected value is written out by hand from the docstrings of
# db_value.mojo, db_row.mojo and neutral_ops.mojo, never computed by the code
# under test. Refusals are checked by their exact message, so a refusal that
# fires from the wrong guard (or not at all) goes red.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_db.db_row import DbRow, DbRows
from komira_db.db_value import (
    DbValue,
    logical_type_name,
    LOGICAL_UUID,
    LOGICAL_TEXT,
    LOGICAL_INT4,
    LOGICAL_INT8,
    LOGICAL_FLOAT8,
    LOGICAL_FLOAT4,
    LOGICAL_BOOL,
    LOGICAL_BYTES,
    LOGICAL_TIMESTAMPTZ,
    LOGICAL_JSONB,
    LOGICAL_TEXT_ARRAY,
)
from komira_db.neutral_ops import (
    classify_raw_expr,
    RAWEXPR_INCREMENT,
    RAWEXPR_LITERAL,
    RAWEXPR_UNEVALUABLE,
)


def _names(a: String, b: String) -> List[String]:
    var l = List[String]()
    l.append(a)
    l.append(b)
    return l^


def _row2(var a: DbValue, var b: DbValue) -> DbRow:
    var v = List[DbValue]()
    v.append(a^)
    v.append(b^)
    return DbRow.from_values(v, _names("a", "b"))


def _int4_err(row: DbRow, col: Int) -> String:
    """The message `get_int4(col)` raises, or `no error`."""
    try:
        _ = row.get_int4(col)
    except e:
        return String(e)
    return String("no error")


def _int8_err(row: DbRow, col: Int) -> String:
    try:
        _ = row.get_int8(col)
    except e:
        return String(e)
    return String("no error")


def _raw_err(row: DbRow, col: Int) -> String:
    try:
        _ = row.raw_bytes(col)
    except e:
        return String(e)
    return String("no error")


comptime OOR = "DbRow: column index out of range"
comptime IS_NULL = "DbRow: column is NULL (use is_null / get_opt_*)"
comptime EMPTY = "DbRow: empty integer text"
comptime NON_NUMERIC = "DbRow: non-numeric byte in integer text"
comptime NO_DIGITS = "DbRow: integer text had no digits"
comptime BAD_NIBBLE = "DbRow: invalid hex nibble in UUID"
comptime TRUNCATED = "DbRow: truncated UUID hex"
comptime SHORT = "DbRow: UUID did not yield 16 bytes"
comptime OUT_I64 = "DbRow: integer text out of Int64 range"
comptime OUT_I32 = "DbRow: integer text out of Int32 range"
comptime UUID_LONG = "DbRow: UUID text continues past 16 bytes"


# =============================================================================
# 1 — logical_type_name: every tag, and the unknown arm
# =============================================================================
def test_logical_type_name_every_tag() raises:
    """Each LOGICAL_* tag has its own name (a swapped arm, e.g. FLOAT4 answering
    FLOAT8, goes red); a tag outside the closed set is UNKNOWN."""
    assert_equal(logical_type_name(LOGICAL_UUID), "UUID")
    assert_equal(logical_type_name(LOGICAL_TEXT), "TEXT")
    assert_equal(logical_type_name(LOGICAL_INT4), "INT4")
    assert_equal(logical_type_name(LOGICAL_INT8), "INT8")
    assert_equal(logical_type_name(LOGICAL_FLOAT8), "FLOAT8")
    assert_equal(logical_type_name(LOGICAL_FLOAT4), "FLOAT4")
    assert_equal(logical_type_name(LOGICAL_BOOL), "BOOL")
    assert_equal(logical_type_name(LOGICAL_BYTES), "BYTES")
    assert_equal(logical_type_name(LOGICAL_TIMESTAMPTZ), "TIMESTAMPTZ")
    assert_equal(logical_type_name(LOGICAL_JSONB), "JSONB")
    assert_equal(logical_type_name(LOGICAL_TEXT_ARRAY), "TEXT[]")
    assert_equal(logical_type_name(11), "UNKNOWN")
    assert_equal(logical_type_name(-1), "UNKNOWN")
    print("  [1] logical_type_name: 11 tags + UNKNOWN OK")


# =============================================================================
# 2 — DbRow / DbRows bounds and NULL refusals
# =============================================================================
def test_row_bounds_and_null_refusals() raises:
    """`is_null` answers True for an index outside the row (both sides) and the
    real flag inside it; `raw_bytes` refuses an index outside [0, col_count)
    and a NULL column, each with its own message."""
    var row = _row2(DbValue.text("x"), DbValue.null(LOGICAL_TEXT))
    assert_equal(row.col_count(), 2)
    assert_false(row.is_null(0), "a present value is not NULL")
    assert_true(row.is_null(1), "a NULL value is NULL")
    assert_true(row.is_null(2), "past the last column reads as NULL")
    assert_true(row.is_null(-1), "a negative column reads as NULL")
    assert_equal(_raw_err(row, 2), String(OOR))
    assert_equal(_raw_err(row, -1), String(OOR))
    assert_equal(_raw_err(row, 1), String(IS_NULL))
    assert_equal(_raw_err(row, 0), String("no error"))
    var empty = DbRow.from_values(List[DbValue](), List[String]())
    assert_equal(empty.col_count(), 1 - 1, "a row of no values has 0 columns")
    assert_equal(_raw_err(empty, 0), String(OOR))
    print("  [2] DbRow bounds + NULL refusals OK")


def test_rows_bounds() raises:
    """`DbRows.row` and `DbRows.column_name` refuse an index outside the set
    (past the end and negative) and answer inside it."""
    var rs = List[DbRow]()
    rs.append(_row2(DbValue.text("r0"), DbValue.int8(0)))
    var rows = DbRows(rs^, _names("a", "b"))
    assert_equal(rows.row(0).get_text(0), String("r0"))
    assert_equal(rows.column_name(1), String("b"))
    var msgs = List[String]()
    for i in [1, -1]:
        try:
            _ = rows.row(i).col_count()
            msgs.append("no error")
        except e:
            msgs.append(String(e))
    for i in [2, -1]:
        try:
            _ = rows.column_name(i)
            msgs.append("no error")
        except e:
            msgs.append(String(e))
    assert_equal(msgs[0], String("DbRows: row index out of range"))
    assert_equal(msgs[1], String("DbRows: row index out of range"))
    assert_equal(msgs[2], String("DbRows: column index out of range"))
    assert_equal(msgs[3], String("DbRows: column index out of range"))
    print("  [3] DbRows bounds OK")


# =============================================================================
# 3 — the integer-text decoder and INT4 reads
# =============================================================================
def test_int_text_refusals() raises:
    """The decoder refuses empty text, a sign with no digits (both signs), and
    a non-digit anywhere: first byte, middle, last byte, a byte just below
    '0' ('/') and just above '9' (':'), and a high byte (0xC3 of 'é'). Each
    refusal is its own message, so a check that fires from the wrong guard
    goes red."""
    var cases = List[String]()
    var want = List[String]()
    cases.append(""); want.append(EMPTY)
    cases.append("-"); want.append(NO_DIGITS)
    cases.append("+"); want.append(NO_DIGITS)
    cases.append("x1"); want.append(NON_NUMERIC)
    cases.append("1x2"); want.append(NON_NUMERIC)
    cases.append("12x"); want.append(NON_NUMERIC)
    cases.append("1/"); want.append(NON_NUMERIC)
    cases.append("1:"); want.append(NON_NUMERIC)
    cases.append("--1"); want.append(NON_NUMERIC)
    cases.append(" 1"); want.append(NON_NUMERIC)
    cases.append("1é"); want.append(NON_NUMERIC)
    for i in range(len(cases)):
        var row = _row2(DbValue.text(cases[i]), DbValue.text(cases[i]))
        assert_equal(_int8_err(row, 0), want[i], "int8 of '" + cases[i] + "'")
        assert_equal(_int4_err(row, 1), want[i], "int4 of '" + cases[i] + "'")
    print("  [4] integer-text refusals: 11 shapes x INT8/INT4 OK")


def test_int4_reads_and_nullable_int4() raises:
    """`get_int4` decodes signed decimal text inside the INT4 range (both ends,
    zero, an explicit '+'); `get_opt_int4` answers None for NULL and the value
    otherwise; `get_int4` of a NULL refuses as NULL."""
    var vals = List[Int32]()
    vals.append(Int32.MIN)
    vals.append(-1)
    vals.append(0)
    vals.append(7)
    vals.append(Int32.MAX)
    for i in range(len(vals)):
        var row = _row2(DbValue.int4(vals[i]), DbValue.null(LOGICAL_INT4))
        assert_equal(row.get_int4(0), vals[i])
        var opt = row.get_opt_int4(0)
        assert_true(opt.__bool__(), "a present INT4 is Some")
        assert_equal(opt.value(), vals[i])
        assert_false(row.get_opt_int4(1).__bool__(), "a NULL INT4 is None")
        assert_equal(_int4_err(row, 1), String(IS_NULL))
    var plus = _row2(DbValue.text("+42"), DbValue.text("-0"))
    assert_equal(plus.get_int4(0), Int32(42))
    assert_equal(plus.get_int4(1), Int32(0))
    print("  [5] INT4 reads (range ends) + get_opt_int4 OK")


def test_int8_range_ends_round_trip() raises:
    """INT8 text at both ends of the Int64 range decodes to the same value."""
    var row = _row2(DbValue.int8(Int64.MIN), DbValue.int8(Int64.MAX))
    assert_equal(row.get_int8(0), Int64.MIN)
    assert_equal(row.get_int8(1), Int64.MAX)
    assert_equal(row.get_timestamptz_micros(1), Int64.MAX)
    print("  [6] INT8 range ends round-trip OK")


# =============================================================================
# 4 — raw bytes with high bytes and an embedded NUL
# =============================================================================
def test_bytes_round_trip_high_bytes() raises:
    """A BYTES value round-trips every byte value 0..255 verbatim through
    `DbRow.raw_bytes` / `get_bytes` / `get_opt_bytes` (no codepoint promotion
    of a byte >= 0x80, no stop at NUL), and its neighbour column's bounds are
    unchanged (the offsets table stays in step)."""
    var raw = List[UInt8]()
    for i in range(256):
        raw.append(UInt8(255 - i))
    var row = _row2(DbValue.bytes(raw), DbValue.text("after"))
    var got = row.get_bytes(0)
    assert_equal(len(got), 256, "every byte, no promotion")
    for i in range(256):
        assert_equal(Int(got[i]), 255 - i, "byte " + String(i))
    var opt = row.get_opt_bytes(0)
    assert_equal(len(opt.value()), 256)
    assert_equal(row.get_text(1), String("after"), "the next column is intact")
    var n = _row2(DbValue.null(LOGICAL_BYTES), DbValue.text(""))
    assert_false(n.get_opt_bytes(0).__bool__(), "a NULL BYTES is None")
    assert_equal(len(n.get_bytes(1)), 0, "an empty value is zero bytes")
    print("  [7] BYTES 0..255 round-trip OK")


def test_uuid_round_trip_high_bytes() raises:
    """A UUID of high and low bytes renders canonical lowercase 8-4-4-4-12 hex
    and `get_uuid` decodes it back to the same 16 bytes (uppercase hex too).
    `get_uuid` refuses a non-hex nibble, an odd digit count and fewer than 16
    bytes, each with its own message. (Text past 16 bytes: test 8b.)"""
    var b = Array[UInt8, 16](fill=0)
    for i in range(16):
        b[i] = UInt8((i * 17 + 0x0F) & 0xFF)
    var v = DbValue.uuid(b)
    assert_equal(
        v.as_text(), String("0f203142-5364-7586-97a8-b9cadbecfd0e")
    )
    var row = _row2(v^, DbValue.text("ABCDEF00-0000-0000-0000-0000000000FF"))
    var back = row.get_uuid(0)
    for i in range(16):
        assert_equal(Int(back[i]), (i * 17 + 0x0F) & 0xFF, "uuid byte " + String(i))
    var upper = row.get_uuid(1)
    assert_equal(Int(upper[0]), 0xAB, "uppercase hex decodes")
    assert_equal(Int(upper[3]), 0x00)
    assert_equal(Int(upper[15]), 0xFF)
    var refusals = List[String]()
    var want = List[String]()
    # a non-hex nibble: in the high and in the low half of a byte, just past
    # 'f' / 'F' / '9'
    refusals.append("g0112233-4455-6677-8899-aabbccddeeff"); want.append(BAD_NIBBLE)
    refusals.append("0G112233-4455-6677-8899-aabbccddeeff"); want.append(BAD_NIBBLE)
    refusals.append("00112233-4455-6677-8899-aabbccddee:f"); want.append(BAD_NIBBLE)
    # an odd number of hex digits: the last byte has one nibble
    refusals.append("0011223"); want.append(TRUNCATED)
    refusals.append("00112233-4455-6677-8899-aabbccddeef"); want.append(TRUNCATED)
    # 15 bytes, and none
    refusals.append("00112233-4455-6677-8899-aabbccddee"); want.append(SHORT)
    refusals.append("----"); want.append(SHORT)
    refusals.append(""); want.append(SHORT)
    for i in range(len(refusals)):
        var r = _row2(DbValue.text(refusals[i]), DbValue.text(""))
        var msg = String("no error")
        try:
            _ = r.get_uuid(0)
        except e:
            msg = String(e)
        assert_equal(msg, want[i], "uuid '" + refusals[i] + "'")
    print("  [8] UUID high-byte round-trip + 8 refusals OK")


# =============================================================================
# 4b — out-of-range integer text and over-long UUID text (komira-ai/komira#1314)
# =============================================================================
def _ts_err(row: DbRow, col: Int) -> String:
    try:
        _ = row.get_timestamptz_micros(col)
    except e:
        return String(e)
    return String("no error")


def _uuid_err(row: DbRow, col: Int) -> String:
    try:
        _ = row.get_uuid(col)
    except e:
        return String(e)
    return String("no error")


def test_int_text_out_of_range_refusals() raises:
    """Integer text one past either end of the Int64 range refuses (it used to
    wrap: '9223372036854775808' read as Int64.MIN), and so does text whose
    magnitude wraps a 64-bit accumulator back to a small value (2^64 read as 0).
    INT4 refuses text one past either end of the Int32 range (it used to
    narrow: '3000000000' read as -1294967296). Each end itself still decodes,
    with leading zeros allowed."""
    var i64 = List[String]()
    i64.append("9223372036854775808")       # Int64.MAX + 1
    i64.append("-9223372036854775809")      # Int64.MIN - 1
    i64.append("18446744073709551616")      # 2^64: wraps to 0
    i64.append("99999999999999999999")      # 20 nines
    for i in range(len(i64)):
        var row = _row2(DbValue.text(i64[i]), DbValue.text(i64[i]))
        assert_equal(_int8_err(row, 0), String(OUT_I64), "int8 of '" + i64[i] + "'")
        assert_equal(_ts_err(row, 0), String(OUT_I64), "micros of '" + i64[i] + "'")
        assert_equal(_int4_err(row, 1), String(OUT_I64), "int4 of '" + i64[i] + "'")
    var ends = _row2(
        DbValue.text("-0009223372036854775808"), DbValue.text("+9223372036854775807")
    )
    assert_equal(ends.get_int8(0), Int64.MIN, "Int64.MIN text with leading zeros")
    assert_equal(ends.get_int8(1), Int64.MAX, "Int64.MAX text with a '+'")
    var i32 = List[String]()
    i32.append("3000000000")
    i32.append("2147483648")                # Int32.MAX + 1
    i32.append("-2147483649")               # Int32.MIN - 1
    i32.append("4294967296")                # 2^32: narrows to 0
    for i in range(len(i32)):
        var row = _row2(DbValue.text(i32[i]), DbValue.text(""))
        assert_equal(_int4_err(row, 0), String(OUT_I32), "int4 of '" + i32[i] + "'")
    var e32 = _row2(DbValue.text("-2147483648"), DbValue.text("2147483647"))
    assert_equal(e32.get_int4(0), Int32.MIN, "Int32.MIN text")
    assert_equal(e32.get_int4(1), Int32.MAX, "Int32.MAX text")
    print("  [7b] integer text past Int64 / Int32 refuses OK")


def test_uuid_text_past_16_bytes_refuses() raises:
    """UUID text that continues after its 16th byte refuses (it used to decode
    the first 16 bytes and drop the rest): 18 bytes of bare hex, one extra
    nibble, a trailing hyphen, a 17th byte after a canonical UUID."""
    var long = List[String]()
    long.append("00112233445566778899aabbccddeeff0011")
    long.append("00112233445566778899aabbccddeeff0")
    long.append("00112233-4455-6677-8899-aabbccddeeff-")
    long.append("00112233-4455-6677-8899-aabbccddeeff-00")
    for i in range(len(long)):
        var row = _row2(DbValue.text(long[i]), DbValue.text(""))
        assert_equal(_uuid_err(row, 0), String(UUID_LONG), "uuid '" + long[i] + "'")
    print("  [8b] UUID text past 16 bytes refuses OK")


# =============================================================================
# 5 — RAW_EXPR literal shapes
# =============================================================================
def test_classify_raw_expr_literal_shapes() raises:
    """The closed RAW_EXPR vocabulary's literal arms: `false` (any case) is the
    bool false; `null` is a typed NULL; a signed decimal integer is an INT8
    carrying its text; a lone sign, an empty expression, a decimal point and a
    sign after a digit are UNEVALUABLE (refused, never guessed)."""
    var f = classify_raw_expr("revoked", "FaLsE")
    assert_equal(f.kind, RAWEXPR_LITERAL)
    assert_equal(f.literal.logical_type, LOGICAL_BOOL)
    assert_false(f.literal.is_null)
    assert_equal(f.literal.as_text(), String("false"))
    var t = classify_raw_expr("revoked", " true ")
    assert_equal(t.literal.as_text(), String("true"))
    var nl = classify_raw_expr("x", "NULL")
    assert_equal(nl.kind, RAWEXPR_LITERAL)
    assert_true(nl.literal.is_null, "null is a typed NULL")
    assert_equal(nl.literal.logical_type, LOGICAL_BOOL)
    var ints = List[String]()
    ints.append("0")
    ints.append("-7")
    ints.append("+12")
    ints.append("9223372036854775807")
    for i in range(len(ints)):
        var r = classify_raw_expr("n", ints[i])
        assert_equal(r.kind, RAWEXPR_LITERAL, "integer " + ints[i])
        assert_equal(r.literal.logical_type, LOGICAL_INT8)
        assert_false(r.literal.is_null)
        assert_equal(r.literal.as_text(), ints[i])
    var spaced = classify_raw_expr("n", " - 3 ")
    assert_equal(spaced.literal.as_text(), String("-3"), "spaces are stripped")
    var bad = List[String]()
    bad.append("-")
    bad.append("+")
    bad.append("")
    bad.append("   ")
    bad.append("1.5")
    bad.append("1-")
    bad.append("1e3")
    bad.append("'x'")
    bad.append("n + 2")
    for i in range(len(bad)):
        var r = classify_raw_expr("n", bad[i])
        assert_equal(r.kind, RAWEXPR_UNEVALUABLE, "refused: '" + bad[i] + "'")
        assert_true(r.is_unevaluable())
        assert_false(r.is_literal())
    var inc = classify_raw_expr("n", "n+1")
    assert_true(inc.is_increment())
    assert_equal(inc.kind, RAWEXPR_INCREMENT)
    print("  [9] classify_raw_expr literal shapes + refusals OK")


def main() raises:
    print("== komira_db value carriers: edges ==")
    test_logical_type_name_every_tag()
    test_row_bounds_and_null_refusals()
    test_rows_bounds()
    test_int_text_refusals()
    test_int4_reads_and_nullable_int4()
    test_int8_range_ends_round_trip()
    test_bytes_round_trip_high_bytes()
    test_uuid_round_trip_high_bytes()
    test_int_text_out_of_range_refusals()
    test_uuid_text_past_16_bytes_refuses()
    test_classify_raw_expr_literal_shapes()
    print("PASS test_db_row_value")
