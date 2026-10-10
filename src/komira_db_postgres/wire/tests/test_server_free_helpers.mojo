"""komira_db_postgres.wire: helpers no other test reaches, none of which needs a
server.

NO NETWORK. Each check pins one function by its exact output:

  1. encode_describe_portal / encode_close_statement / encode_flush: the full
     message bytes (type byte, length, kind byte, NUL-terminated name).
  2. body_as_string, sasl_payload_string (body after the 4-byte sub-code) and
     command_tag (stops at the first NUL).
  3. parse_data_row on a well-formed body: one text column and one NULL
     column; RawDataRow.col_count.
  4. PgRow.get_timestamptz_text (text path returns the text, binary path
     raises), get_opt_text and get_opt_int8 (NULL is empty, a value is
     present).
  5. PgReadFrame.mark_error lands ERR with the given text, and a later drain
     is a no-op; PgReadFrame._compact on a frame with nothing consumed keeps
     the buffer, so the buffered message still decodes.
  6. TxStep.seq_select carries the SEQ_SELECT role; TxStep.prepared_seq_bound
     carries the PLAIN role and its bind index; _first_int8_or_zero returns
     the int8 cell, and 0 for an empty result or a non-integer cell.

main runs every check and raises after the last one if any failed, so a
single run reports each failing check by name.
"""

from std.testing import assert_equal, assert_true, assert_false, assert_raises

from komira_db_postgres.wire.connection import PreparedStatement
from komira_db_postgres.wire.pg_query_op import PgReadFrame
from komira_db_postgres.wire.pg_tx_op import (
    TxStep,
    _first_int8_or_zero,
    _STEP_ROLE_PLAIN,
    _STEP_ROLE_SEQ_SELECT,
)
from komira_db_postgres.wire.pg_types import PgRow, PgRows, PgValue, OID_TEXT
from komira_db_postgres.wire.pgwire import (
    BackendMessage,
    put_i16_be,
    put_i32_be,
    encode_describe_portal,
    encode_close_statement,
    encode_flush,
    body_as_string,
    sasl_payload_string,
    command_tag,
    parse_data_row,
    MSG_READY,
)


# -----------------------------------------------------------------------------
# helpers
# -----------------------------------------------------------------------------
def _ascii(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var b = s.as_bytes()
    for i in range(len(b)):
        out.append(b[i])
    return out^


def _assert_bytes(got: List[UInt8], want: List[UInt8], what: String) raises:
    assert_equal(len(got), len(want), what + String(": length"))
    for i in range(len(want)):
        assert_equal(got[i], want[i], what + String(": byte ") + String(i))


def _text_row(cell: String, is_null: Bool) -> PgRow:
    """A one-column TEXT-format PgRow."""
    var data = List[UInt8]()
    if not is_null:
        data = _ascii(cell)
    var offsets = List[Int]()
    offsets.append(0)
    offsets.append(len(data))
    var nulls = List[Bool]()
    nulls.append(is_null)
    var oids = List[UInt32]()
    oids.append(OID_TEXT)
    return PgRow(data^, offsets^, nulls^, oids^)


def _stmt(var name: String) -> PreparedStatement:
    return PreparedStatement(
        name^, List[UInt32](), List[UInt32](), List[UInt8](), List[Int]()
    )


# -----------------------------------------------------------------------------
# 1. frontend encoders
# -----------------------------------------------------------------------------
def test_encoders() raises:
    # Describe portal: 'D', len 8 (4 + 'P' + "p1\0"), 'P', "p1", NUL.
    var want_d = List[UInt8]()
    want_d.append(UInt8(ord("D")))
    put_i32_be(want_d, Int32(8))
    want_d.append(UInt8(ord("P")))
    want_d.append(UInt8(ord("p")))
    want_d.append(UInt8(ord("1")))
    want_d.append(UInt8(0))
    _assert_bytes(encode_describe_portal(String("p1")), want_d, "describe")

    # Close statement: 'C', len 8, 'S' (statement), "s1", NUL.
    var want_c = List[UInt8]()
    want_c.append(UInt8(ord("C")))
    put_i32_be(want_c, Int32(8))
    want_c.append(UInt8(ord("S")))
    want_c.append(UInt8(ord("s")))
    want_c.append(UInt8(ord("1")))
    want_c.append(UInt8(0))
    _assert_bytes(encode_close_statement(String("s1")), want_c, "close")

    # Flush: 'H', len 4, no body.
    var want_h = List[UInt8]()
    want_h.append(UInt8(ord("H")))
    put_i32_be(want_h, Int32(4))
    _assert_bytes(encode_flush(), want_h, "flush")


# -----------------------------------------------------------------------------
# 2. message body accessors
# -----------------------------------------------------------------------------
def test_body_accessors() raises:
    var m = BackendMessage(UInt8(ord("R")), _ascii(String("abc")))
    assert_equal(body_as_string(m), String("abc"))

    # SASL continue: sub-code 11, then the payload.
    var sasl_body = List[UInt8]()
    put_i32_be(sasl_body, Int32(11))
    var payload = _ascii(String("r=xyz,s=QQ==,i=4096"))
    for i in range(len(payload)):
        sasl_body.append(payload[i])
    var sm = BackendMessage(UInt8(ord("R")), sasl_body^)
    assert_equal(sasl_payload_string(sm), String("r=xyz,s=QQ==,i=4096"))

    # CommandComplete: the tag ends at the first NUL; bytes after it are
    # not part of the tag.
    var tag_body = _ascii(String("INSERT 0 1"))
    tag_body.append(UInt8(0))
    tag_body.append(UInt8(ord("Z")))
    var cm = BackendMessage(UInt8(ord("C")), tag_body^)
    assert_equal(command_tag(cm), String("INSERT 0 1"))


# -----------------------------------------------------------------------------
# 3. parse_data_row (well-formed; truncated bodies: test_truncated_messages)
# -----------------------------------------------------------------------------
def test_parse_data_row() raises:
    var body = List[UInt8]()
    put_i16_be(body, Int16(2))
    put_i32_be(body, Int32(3))
    body.append(UInt8(ord("a")))
    body.append(UInt8(ord("b")))
    body.append(UInt8(ord("c")))
    put_i32_be(body, Int32(-1))  # NULL
    var row = parse_data_row(BackendMessage(UInt8(ord("D")), body^))
    assert_equal(row.col_count(), 2)
    assert_equal(len(row.nulls), 2)
    assert_false(row.nulls[0], "column 0 is not NULL")
    assert_true(row.nulls[1], "column 1 is NULL")
    _assert_bytes(row.columns[0].copy(), _ascii(String("abc")), "column 0")
    assert_equal(len(row.columns[1]), 0, "a NULL column has no bytes")


# -----------------------------------------------------------------------------
# 4. PgRow getters
# -----------------------------------------------------------------------------
def test_pgrow_getters() raises:
    var ts = String("2030-01-15 12:00:00+00")
    assert_equal(_text_row(ts, False).get_timestamptz_text(0), ts)

    var data = List[UInt8]()
    for _ in range(8):
        data.append(UInt8(0))
    var offsets = List[Int]()
    offsets.append(0)
    offsets.append(8)
    var nulls = List[Bool]()
    nulls.append(False)
    var oids = List[UInt32]()
    oids.append(OID_TEXT)
    var bin_row = PgRow(data^, offsets^, nulls^, oids^, True)
    with assert_raises(contains="column is BINARY format"):
        _ = bin_row.get_timestamptz_text(0)

    assert_false(Bool(_text_row(String("x"), True).get_opt_text(0)))
    var t = _text_row(String("hello"), False).get_opt_text(0)
    assert_true(Bool(t), "a value is present")
    assert_equal(t.value(), String("hello"))

    assert_false(Bool(_text_row(String("1"), True).get_opt_int8(0)))
    var n = _text_row(String("-9000000000"), False).get_opt_int8(0)
    assert_true(Bool(n), "a value is present")
    assert_equal(n.value(), Int64(-9000000000))


# -----------------------------------------------------------------------------
# 5. PgReadFrame.mark_error and _compact
# -----------------------------------------------------------------------------
def test_frame_mark_error_and_compact() raises:
    var frame = PgReadFrame(List[UInt32](), List[String]())
    assert_true(frame.is_pending())
    frame.mark_error(String("peer went away"))
    assert_true(frame.is_error(), "mark_error lands ERR")
    assert_false(frame.is_pending())
    assert_equal(frame.err_text(), String("peer went away"))
    assert_true(frame.drain_complete(), "a drain after ERR is a no-op")
    assert_true(frame.is_error())

    # _compact with nothing consumed (_rpos == 0) keeps the buffer as is.
    var f2 = PgReadFrame(List[UInt32](), List[String]())
    var ready = List[UInt8]()
    ready.append(MSG_READY)
    put_i32_be(ready, Int32(5))
    ready.append(UInt8(ord("I")))
    f2.feed(ready)
    f2._compact()
    assert_true(f2.drain_complete(), "the buffered ReadyForQuery survives")
    assert_true(f2.is_ready())


# -----------------------------------------------------------------------------
# 6. TxStep constructors and _first_int8_or_zero
# -----------------------------------------------------------------------------
def test_tx_steps() raises:
    var s = TxStep.seq_select(_stmt(String("seq")), List[PgValue]())
    assert_true(s._is_prepared)
    assert_equal(s._role, _STEP_ROLE_SEQ_SELECT)
    assert_equal(s._seq_bind_idx, -1)
    assert_equal(s._stmt.name, String("seq"))

    var p = TxStep.prepared_seq_bound(
        _stmt(String("ins_event")), List[PgValue](), 3
    )
    assert_true(p._is_prepared)
    assert_equal(p._role, _STEP_ROLE_PLAIN)
    assert_equal(p._seq_bind_idx, 3)
    assert_equal(p._stmt.name, String("ins_event"))

    assert_equal(
        _first_int8_or_zero(PgRows(List[PgRow](), List[String]())), Int64(0)
    )
    var one = List[PgRow]()
    one.append(_text_row(String("41"), False))
    assert_equal(_first_int8_or_zero(PgRows(one^, List[String]())), Int64(41))
    var bad = List[PgRow]()
    bad.append(_text_row(String("x"), False))
    assert_equal(_first_int8_or_zero(PgRows(bad^, List[String]())), Int64(0))


def main() raises:
    print("== komira_db_postgres.wire server-free helpers ==")
    var failed = List[String]()
    try:
        test_encoders()
    except e:
        print("  FAIL encoders:", e)
        failed.append(String("encoders"))
    try:
        test_body_accessors()
    except e:
        print("  FAIL body_accessors:", e)
        failed.append(String("body_accessors"))
    try:
        test_parse_data_row()
    except e:
        print("  FAIL parse_data_row:", e)
        failed.append(String("parse_data_row"))
    try:
        test_pgrow_getters()
    except e:
        print("  FAIL pgrow_getters:", e)
        failed.append(String("pgrow_getters"))
    try:
        test_frame_mark_error_and_compact()
    except e:
        print("  FAIL frame_mark_error_and_compact:", e)
        failed.append(String("frame_mark_error_and_compact"))
    try:
        test_tx_steps()
    except e:
        print("  FAIL tx_steps:", e)
        failed.append(String("tx_steps"))
    if len(failed) > 0:
        raise Error(String(len(failed)) + " check(s) failed")
    print("== PASSED ==")
