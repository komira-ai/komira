"""komira_db_postgres.wire: a backend message body shorter than the counts and
lengths it declares is refused, not decoded short (komira#1086).

NO NETWORK. `parse_backend_messages` frames by the length header first, so a
body that ends before its own declared counts means the server sent a
self-inconsistent message. Each decoder must raise rather than return the
prefix it managed to read; a short result is indistinguishable from a
well-formed one to the caller.

  1. parse_row_description: a body under 2 bytes, a field count of 2 with one
     complete field, a field cut inside its fixed 18-byte tail, and a name
     with no NUL terminator all raise; the same fields ending exactly at the
     body end decode.
  2. parse_parameter_description: a body under 2 bytes and a count of 2 with
     one OID (plus 3 stray bytes) raise; the exact body decodes.
  3. DataRow, through parse_data_row, row_from_data_message and
     binary_row_from_data_message: a body under 2 bytes, a column count of 2
     whose second length is cut, and a column declaring 5 bytes with 3
     present all raise; a column ending exactly at the body end decodes.
  4. decode_text_array_binary and PgRow.get_text_array: an element declaring
     5 bytes with 3 present, and with 4 present, raises; the exact element
     decodes.
  5. PgReadFrame.drain_complete: a truncated DataRow lands the ERR terminal
     with the decoder's text (the frame does not raise; ERR is how it reports
     a protocol fault), and a truncated RowDescription does the same.

main runs every check and raises after the last one if any failed.
"""

from std.testing import assert_equal, assert_true, assert_false, assert_raises

from komira_db_postgres.wire.pg_binary import decode_text_array_binary
from komira_db_postgres.wire.pg_query_op import PgReadFrame
from komira_db_postgres.wire.pg_types import (
    OID_TEXT,
    row_from_data_message,
    binary_row_from_data_message,
)
from komira_db_postgres.wire.pgwire import (
    BackendMessage,
    put_i16_be,
    put_i32_be,
    parse_row_description,
    parse_parameter_description,
    parse_data_row,
    MSG_DATA_ROW,
    MSG_ROW_DESC,
)


def _ascii(mut out: List[UInt8], s: String):
    for c in s.as_bytes():
        out.append(c)


def _field(mut body: List[UInt8], name: String, oid: Int32):
    """One RowDescription field: name CString + 18 fixed bytes."""
    _ascii(body, name)
    body.append(UInt8(0))
    put_i32_be(body, Int32(0))  # table OID
    put_i16_be(body, Int16(0))  # attnum
    put_i32_be(body, oid)  # type OID
    put_i16_be(body, Int16(-1))  # type size
    put_i32_be(body, Int32(-1))  # type modifier
    put_i16_be(body, Int16(0))  # format code


def _msg(t: UInt8, body: List[UInt8]) -> BackendMessage:
    return BackendMessage(t, body.copy())


def _frame_bytes(t: UInt8, body: List[UInt8]) -> List[UInt8]:
    var out = List[UInt8]()
    out.append(t)
    put_i32_be(out, Int32(len(body) + 4))
    for b in body:
        out.append(b)
    return out^


# -----------------------------------------------------------------------------
# 1. RowDescription
# -----------------------------------------------------------------------------
def test_row_description() raises:
    var one = List[UInt8]()
    one.append(UInt8(0))
    with assert_raises(contains="RowDescription truncated"):
        _ = parse_row_description(_msg(MSG_ROW_DESC, one))

    # Exact: two fields ending at the body end decode.
    var exact = List[UInt8]()
    put_i16_be(exact, Int16(2))
    _field(exact, String("a"), Int32(25))
    _field(exact, String("bc"), Int32(23))
    var cols = parse_row_description(_msg(MSG_ROW_DESC, exact))
    assert_equal(len(cols), 2)
    assert_equal(cols[1].name, String("bc"))
    assert_equal(Int(cols[1].type_oid), 23)

    # Count 2, only one complete field.
    var short_count = List[UInt8]()
    put_i16_be(short_count, Int16(2))
    _field(short_count, String("a"), Int32(25))
    with assert_raises(contains="RowDescription truncated"):
        _ = parse_row_description(_msg(MSG_ROW_DESC, short_count))

    # Count 1, field cut one byte inside its fixed tail.
    var cut_tail = List[UInt8]()
    put_i16_be(cut_tail, Int16(1))
    _field(cut_tail, String("a"), Int32(25))
    _ = cut_tail.pop()
    with assert_raises(contains="RowDescription truncated"):
        _ = parse_row_description(_msg(MSG_ROW_DESC, cut_tail))

    # Count 1, name runs to the body end with no NUL.
    var no_nul = List[UInt8]()
    put_i16_be(no_nul, Int16(1))
    _ascii(no_nul, String("abcdefghijklmnopqrstuvwxyz"))
    with assert_raises(contains="RowDescription truncated"):
        _ = parse_row_description(_msg(MSG_ROW_DESC, no_nul))
    print("  [1] RowDescription: short body, count, tail, no NUL refused OK")


# -----------------------------------------------------------------------------
# 2. ParameterDescription
# -----------------------------------------------------------------------------
def test_parameter_description() raises:
    var empty = List[UInt8]()
    with assert_raises(contains="ParameterDescription truncated"):
        _ = parse_parameter_description(_msg(UInt8(ord("t")), empty))

    var exact = List[UInt8]()
    put_i16_be(exact, Int16(2))
    put_i32_be(exact, Int32(25))
    put_i32_be(exact, Int32(23))
    var oids = parse_parameter_description(_msg(UInt8(ord("t")), exact))
    assert_equal(len(oids), 2)
    assert_equal(Int(oids[1]), 23)

    var short = List[UInt8]()
    put_i16_be(short, Int16(2))
    put_i32_be(short, Int32(25))
    for _ in range(3):
        short.append(UInt8(0))
    with assert_raises(contains="ParameterDescription truncated"):
        _ = parse_parameter_description(_msg(UInt8(ord("t")), short))
    print("  [2] ParameterDescription: short body and count refused OK")


# -----------------------------------------------------------------------------
# 3. DataRow (three entry points, one framing)
# -----------------------------------------------------------------------------
def _check_data_row_refused(body: List[UInt8], what: String) raises:
    var oids = List[UInt32]()
    oids.append(OID_TEXT)
    oids.append(OID_TEXT)
    with assert_raises(contains="DataRow truncated"):
        _ = parse_data_row(_msg(MSG_DATA_ROW, body))
    with assert_raises(contains="DataRow truncated"):
        _ = row_from_data_message(_msg(MSG_DATA_ROW, body), oids)
    with assert_raises(contains="DataRow truncated"):
        _ = binary_row_from_data_message(_msg(MSG_DATA_ROW, body), oids)
    print("      refused:", what)


def test_data_row() raises:
    var one = List[UInt8]()
    one.append(UInt8(0))
    _check_data_row_refused(one, String("1-byte body"))

    # Count 2; column 0 is "abc", column 1's length has 3 of 4 bytes.
    var cut_len = List[UInt8]()
    put_i16_be(cut_len, Int16(2))
    put_i32_be(cut_len, Int32(3))
    _ascii(cut_len, String("abc"))
    for _ in range(3):
        cut_len.append(UInt8(0))
    _check_data_row_refused(cut_len, String("second length cut"))

    # The issue's repro: count 2, column 0 declares 5 bytes, "abc" follows.
    var cut_val = List[UInt8]()
    put_i16_be(cut_val, Int16(2))
    put_i32_be(cut_val, Int32(5))
    _ascii(cut_val, String("abc"))
    _check_data_row_refused(cut_val, String("value 3 of 5 bytes"))

    # Count 1, column declares 5 bytes, 4 present (one short, last column).
    var one_short = List[UInt8]()
    put_i16_be(one_short, Int16(1))
    put_i32_be(one_short, Int32(5))
    _ascii(one_short, String("abcd"))
    _check_data_row_refused(one_short, String("last value one byte short"))

    # Exact: "abc" then NULL then "de" ending at the body end decodes.
    var exact = List[UInt8]()
    put_i16_be(exact, Int16(3))
    put_i32_be(exact, Int32(3))
    _ascii(exact, String("abc"))
    put_i32_be(exact, Int32(-1))
    put_i32_be(exact, Int32(2))
    _ascii(exact, String("de"))
    var raw = parse_data_row(_msg(MSG_DATA_ROW, exact))
    assert_equal(raw.col_count(), 3)
    assert_true(raw.nulls[1])
    assert_equal(len(raw.columns[2]), 2)
    var oids = List[UInt32]()
    for _ in range(3):
        oids.append(OID_TEXT)
    var row = row_from_data_message(_msg(MSG_DATA_ROW, exact), oids)
    assert_equal(row.col_count(), 3)
    assert_equal(row.get_text(0), String("abc"))
    assert_equal(row.get_text(2), String("de"))
    var brow = binary_row_from_data_message(_msg(MSG_DATA_ROW, exact), oids)
    assert_equal(brow.col_count(), 3)
    assert_equal(brow.get_text(2), String("de"))
    print("  [3] DataRow: short body, length, value refused; exact decodes OK")


# -----------------------------------------------------------------------------
# 4. text[] element length
# -----------------------------------------------------------------------------
def _array_one_elem(declared: Int32, present: String) -> List[UInt8]:
    var b = List[UInt8]()
    put_i32_be(b, Int32(1))  # ndim
    put_i32_be(b, Int32(0))  # hasnull
    put_i32_be(b, Int32(25))  # element OID
    put_i32_be(b, Int32(1))  # dim length
    put_i32_be(b, Int32(1))  # lower bound
    put_i32_be(b, declared)
    _ascii(b, present)
    return b^


def test_text_array() raises:
    var short = _array_one_elem(Int32(5), String("abc"))
    with assert_raises(contains="text[] truncated element"):
        _ = decode_text_array_binary(Span[UInt8](short))
    # One byte short at the body end (the boundary an off-by-one would miss).
    var one_short = _array_one_elem(Int32(5), String("abcd"))
    with assert_raises(contains="text[] truncated element"):
        _ = decode_text_array_binary(Span[UInt8](one_short))

    # The same body reached through a binary PgRow cell.
    var body = List[UInt8]()
    put_i16_be(body, Int16(1))
    put_i32_be(body, Int32(len(short)))
    for x in short:
        body.append(x)
    var oids = List[UInt32]()
    oids.append(UInt32(1009))
    var row = binary_row_from_data_message(_msg(MSG_DATA_ROW, body), oids)
    with assert_raises(contains="text[] truncated element"):
        _ = row.get_text_array(0)

    var exact = _array_one_elem(Int32(3), String("abc"))
    var got = decode_text_array_binary(Span[UInt8](exact))
    assert_equal(len(got), 1)
    assert_equal(got[0], String("abc"))
    print("  [4] text[]: element 3 and 4 of 5 bytes refused; exact decodes OK")


# -----------------------------------------------------------------------------
# 5. PgReadFrame reports a truncated message as ERR
# -----------------------------------------------------------------------------
def test_frame_err() raises:
    var cut_val = List[UInt8]()
    put_i16_be(cut_val, Int16(2))
    put_i32_be(cut_val, Int32(5))
    _ascii(cut_val, String("abc"))
    var oids = List[UInt32]()
    oids.append(OID_TEXT)
    oids.append(OID_TEXT)
    var names = List[String]()
    names.append(String("a"))
    names.append(String("b"))
    var frame = PgReadFrame(oids^, names^)
    frame.feed(_frame_bytes(MSG_DATA_ROW, cut_val))
    assert_true(frame.drain_complete(), "a truncated DataRow is terminal")
    assert_true(frame.is_error(), "a truncated DataRow lands ERR")
    var err = frame.err_text()
    assert_true(err.find("DataRow truncated") >= 0, err)
    assert_equal(frame.row_count(), 0, "no short row was accumulated")

    var cut_desc = List[UInt8]()
    put_i16_be(cut_desc, Int16(2))
    _field(cut_desc, String("a"), Int32(25))
    var f2 = PgReadFrame(List[UInt32](), List[String]())
    f2.feed(_frame_bytes(MSG_ROW_DESC, cut_desc))
    assert_true(f2.drain_complete(), "a truncated RowDescription is terminal")
    assert_true(f2.is_error(), "a truncated RowDescription lands ERR")
    var err2 = f2.err_text()
    assert_true(err2.find("RowDescription truncated") >= 0, err2)
    print("  [5] PgReadFrame: truncated DataRow / RowDescription land ERR OK")


def main() raises:
    var failed = List[String]()
    try:
        test_row_description()
    except e:
        print("FAIL row_description:", e)
        failed.append(String("row_description"))
    try:
        test_parameter_description()
    except e:
        print("FAIL parameter_description:", e)
        failed.append(String("parameter_description"))
    try:
        test_data_row()
    except e:
        print("FAIL data_row:", e)
        failed.append(String("data_row"))
    try:
        test_text_array()
    except e:
        print("FAIL text_array:", e)
        failed.append(String("text_array"))
    try:
        test_frame_err()
    except e:
        print("FAIL frame_err:", e)
        failed.append(String("frame_err"))
    if len(failed) > 0:
        raise Error(
            "test_truncated_messages: " + String(len(failed)) + " failed"
        )
    print("test_truncated_messages: all checks passed")
