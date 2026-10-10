"""komira_db_postgres.wire: PgReadFrame, pgwire and TX-cursor edges.

NO NETWORK. Plaintext pgwire bytes forged as a server would send them, fed to
the recv-agnostic `PgReadFrame`; the pgwire encoders and parsers on inputs the
round-trip tests do not reach; and the SENDLESS TX cursor drive on the two
sequences test_pg_tx_op_sequence leaves out.

  1. A RowDescription on the wire replaces the frame's seeded column names
     and OIDs.
  2. An ErrorResponse lands the frame in ERR with the rendered server error
     (severity, SQLSTATE, message, detail); a later drain is a no-op.
  3. Over 64 KiB of consumed messages with more still buffered: the frame
     compacts its read buffer and every later row still decodes exactly.
  4. Parse ('P') writes each parameter OID; Bind ('B') writes -1 for a NULL
     parameter and the bytes of the next one.
  5. parse_backend_messages stops at an incomplete message and reports the
     bytes it consumed; parse_one_message on an incomplete message returns
     the empty type-0 message.
  6. rows_affected_from_tag: a non-numeric last token is 0, digits are parsed.
  7. parse_error_fields keeps the 'D' (detail) field.
  8. TX cursor: an error on ROLLBACK itself still lands ERR; a TX with no
     business step is BEGIN then COMMIT.
"""

from std.testing import assert_equal, assert_true, assert_false

from komira_db_postgres.wire.pg_query_op import PgReadFrame
from komira_db_postgres.wire.pg_tx_op import PgTxAsyncOp, TxStep
from komira_db_postgres.wire.pg_types import OID_TEXT, OID_INT4, OID_JSONB
from komira_db_postgres.wire.pgwire import (
    BackendMessage,
    put_i16_be,
    put_i32_be,
    read_i16_be,
    read_i32_be,
    encode_parse,
    encode_bind,
    parse_backend_messages,
    parse_one_message,
    rows_affected_from_tag,
    parse_error_fields,
    MSG_DATA_ROW,
    MSG_ROW_DESC,
    MSG_ERROR,
    MSG_CMD_COMPLETE,
    MSG_READY,
)


# -----------------------------------------------------------------------------
# Server-side message builders.
# -----------------------------------------------------------------------------
def _framed(msg_type: UInt8, body: List[UInt8]) -> List[UInt8]:
    var out = List[UInt8]()
    out.append(msg_type)
    put_i32_be(out, Int32(4 + len(body)))
    for i in range(len(body)):
        out.append(body[i])
    return out^


def _append_all(mut dst: List[UInt8], src: List[UInt8]):
    for i in range(len(src)):
        dst.append(src[i])


def _put_cstr(mut b: List[UInt8], s: String):
    var sb = s.as_bytes()
    for i in range(len(sb)):
        b.append(sb[i])
    b.append(UInt8(0))


def _data_row(cells: List[String]) -> List[UInt8]:
    var body = List[UInt8]()
    put_i16_be(body, Int16(len(cells)))
    for ci in range(len(cells)):
        var cb = cells[ci].as_bytes()
        put_i32_be(body, Int32(len(cb)))
        for j in range(len(cb)):
            body.append(cb[j])
    return _framed(MSG_DATA_ROW, body^)


def _one_cell_row(cell: String) -> List[UInt8]:
    var cells = List[String]()
    cells.append(cell)
    return _data_row(cells)


def _row_description(names: List[String], oids: List[UInt32]) -> List[UInt8]:
    var body = List[UInt8]()
    put_i16_be(body, Int16(len(names)))
    for i in range(len(names)):
        _put_cstr(body, names[i])
        put_i32_be(body, Int32(0))  # table OID
        put_i16_be(body, Int16(0))  # attnum
        put_i32_be(body, Int32(oids[i]))  # type OID
        put_i16_be(body, Int16(-1))  # type size
        put_i32_be(body, Int32(-1))  # type modifier
        put_i16_be(body, Int16(1))  # format code (binary)
    return _framed(MSG_ROW_DESC, body^)


def _error_response() -> List[UInt8]:
    var body = List[UInt8]()
    body.append(UInt8(ord("S")))
    _put_cstr(body, String("ERROR"))
    body.append(UInt8(ord("C")))
    _put_cstr(body, String("23505"))
    body.append(UInt8(ord("M")))
    _put_cstr(body, String("duplicate key"))
    body.append(UInt8(ord("D")))
    _put_cstr(body, String("Key (id)=(7) already exists."))
    body.append(UInt8(0))
    return _framed(MSG_ERROR, body^)


def _command_complete(tag: String) -> List[UInt8]:
    var body = List[UInt8]()
    _put_cstr(body, tag)
    return _framed(MSG_CMD_COMPLETE, body^)


def _ready() -> List[UInt8]:
    var body = List[UInt8]()
    body.append(UInt8(ord("I")))
    return _framed(MSG_READY, body^)


def _seeded_frame() -> PgReadFrame:
    var oids = List[UInt32]()
    oids.append(OID_TEXT)
    var names = List[String]()
    names.append(String("seeded"))
    return PgReadFrame(oids^, names^)


# =============================================================================
# 1. A wire RowDescription replaces the seeded columns.
# =============================================================================
def test_row_description_overrides_seed() raises:
    var frame = _seeded_frame()
    var names = List[String]()
    names.append(String("id"))
    names.append(String("doc"))
    var oids = List[UInt32]()
    oids.append(OID_INT4)
    oids.append(OID_JSONB)
    var wire = _row_description(names, oids)
    var cells = List[String]()
    cells.append(String("ab"))
    cells.append(String("cd"))
    _append_all(wire, _data_row(cells))
    _append_all(wire, _command_complete(String("SELECT 1")))
    _append_all(wire, _ready())
    frame.feed(wire)
    assert_true(frame.drain_complete())
    assert_true(frame.is_ready())
    var rows = frame.take_result()
    assert_equal(rows.column_count(), 2)
    assert_equal(rows.column_name(0), String("id"))
    assert_equal(rows.column_name(1), String("doc"))
    assert_equal(rows.row(0).col_count(), 2)
    assert_equal(rows.row(0).get_text(1), String("cd"))
    print("  [1] wire RowDescription replaces the seeded names OK")


# =============================================================================
# 2. ErrorResponse -> ERR with the rendered error; a later drain is a no-op.
# =============================================================================
def test_error_response_terminal() raises:
    var frame = _seeded_frame()
    var wire = _one_cell_row(String("before"))
    _append_all(wire, _error_response())
    # Bytes after the error (the server's ReadyForQuery) stay unread.
    _append_all(wire, _one_cell_row(String("after")))
    _append_all(wire, _ready())
    frame.feed(wire)
    assert_true(frame.drain_complete())
    assert_true(frame.is_error())
    assert_false(frame.is_ready())
    assert_equal(
        frame.err_text(),
        String(
            "PgError[ERROR 23505]: duplicate key (detail: Key (id)=(7) already"
            " exists.)"
        ),
    )
    assert_equal(frame.row_count(), 1)
    # The terminal is sticky: draining again reports terminal, folds nothing.
    assert_true(frame.drain_complete())
    assert_true(frame.is_error())
    assert_equal(frame.row_count(), 1)
    print("  [2] ErrorResponse -> ERR with detail; sticky terminal OK")


# =============================================================================
# 3. Read-buffer compaction past 64 KiB keeps every later row intact.
# =============================================================================
def _row_text(i: Int) -> String:
    var s = String("row-") + String(i) + String("-")
    var pad = 1000 - s.byte_length()
    for k in range(pad):
        s += chr(ord("a") + (i + k) % 26)
    return s^


def test_compaction_preserves_tail() raises:
    comptime N = 80  # 80 rows of ~1011 wire bytes: well past 65536 consumed
    var frame = _seeded_frame()
    var wire = List[UInt8]()
    for i in range(N):
        _append_all(wire, _one_cell_row(_row_text(i)))
    _append_all(wire, _command_complete(String("SELECT 80")))
    _append_all(wire, _ready())
    assert_true(len(wire) > 65536 + 10 * 1011)
    frame.feed(wire)
    assert_true(frame.drain_complete())
    assert_true(frame.is_ready())
    var rows = frame.take_result()
    assert_equal(rows.__len__(), N)
    for i in range(N):
        assert_equal(rows.row(i).get_text(0), _row_text(i))
    print("  [3] 80 rows past the 64 KiB compaction point decode exactly OK")


# =============================================================================
# 4. Parse writes the parameter OIDs; Bind writes -1 for a NULL param.
# =============================================================================
def test_parse_and_bind_params() raises:
    var oids = List[UInt32]()
    oids.append(UInt32(23))
    oids.append(UInt32(2950))
    var p = encode_parse(String("s1"), String("Q"), oids)
    # 'P' len(4) "s1\0" "Q\0" Int16 count Int32 oid*2
    assert_equal(p[0], UInt8(ord("P")))
    assert_equal(len(p), 1 + 4 + 3 + 2 + 2 + 8)
    assert_equal(Int(read_i32_be(Span[UInt8](p), 1)), len(p) - 1)
    assert_equal(Int(read_i16_be(Span[UInt8](p), 10)), 2)
    assert_equal(Int(read_i32_be(Span[UInt8](p), 12)), 23)
    assert_equal(Int(read_i32_be(Span[UInt8](p), 16)), 2950)

    # Two params: the first NULL (its placeholder byte is ignored), the second
    # "ab".
    var formats = List[Int16]()
    formats.append(Int16(1))
    var data = List[UInt8]()
    data.append(UInt8(ord("X")))
    data.append(UInt8(ord("a")))
    data.append(UInt8(ord("b")))
    var offsets = List[Int]()
    offsets.append(0)
    offsets.append(1)
    offsets.append(3)
    var nulls = List[Bool]()
    nulls.append(True)
    nulls.append(False)
    var b = encode_bind(String(""), String(""), formats, data, offsets, nulls, True)
    # 'B' len "" "" fmtcount(2) fmt(2) nparams(2) [-1] [len 2 "ab"] rescount rescode
    assert_equal(b[0], UInt8(ord("B")))
    var s = Span[UInt8](b)
    var off = 1 + 4 + 1 + 1
    assert_equal(Int(read_i16_be(s, off)), 1)
    off += 4
    assert_equal(Int(read_i16_be(s, off)), 2)
    off += 2
    assert_equal(Int(read_i32_be(s, off)), -1)
    off += 4
    assert_equal(Int(read_i32_be(s, off)), 2)
    off += 4
    assert_equal(b[off], UInt8(ord("a")))
    assert_equal(b[off + 1], UInt8(ord("b")))
    off += 2
    assert_equal(Int(read_i16_be(s, off)), 1)
    assert_equal(Int(read_i16_be(s, off + 2)), 1)
    assert_equal(len(b), off + 4)
    print("  [4] Parse writes param OIDs; Bind writes -1 for NULL OK")


# =============================================================================
# 5. Incomplete messages: stop and report the consumed count.
# =============================================================================
def test_incomplete_messages() raises:
    var wire = _ready()  # 6 bytes
    var second = _command_complete(String("SELECT 1"))
    # All of the second message but its last byte.
    for i in range(len(second) - 1):
        wire.append(second[i])
    var parsed = parse_backend_messages(Span[UInt8](wire))
    assert_equal(len(parsed.messages), 1)
    assert_equal(parsed.messages[0].msg_type, MSG_READY)
    assert_equal(parsed.consumed, 6)

    var partial = List[UInt8]()
    for i in range(len(second) - 1):
        partial.append(second[i])
    var one = parse_one_message(Span[UInt8](partial))
    assert_equal(one.msg_type, UInt8(0))
    assert_equal(len(one.body), 0)
    print("  [5] incomplete message: stop at it, consumed 6; type-0 OK")


# =============================================================================
# 6. rows_affected_from_tag.
# =============================================================================
def test_rows_affected_tags() raises:
    assert_equal(rows_affected_from_tag(String("UPDATE 12")), UInt64(12))
    assert_equal(rows_affected_from_tag(String("INSERT 0 3")), UInt64(3))
    assert_equal(rows_affected_from_tag(String("FETCH EMPTY")), UInt64(0))
    assert_equal(rows_affected_from_tag(String("DELETE 1x")), UInt64(0))
    assert_equal(rows_affected_from_tag(String("DELETE 9/")), UInt64(0))
    assert_equal(rows_affected_from_tag(String("DELETE :")), UInt64(0))
    print("  [6] non-numeric last token is 0 OK")


# =============================================================================
# 7. parse_error_fields keeps the detail field.
# =============================================================================
def test_error_fields_detail() raises:
    var framed = _error_response()
    var body = List[UInt8]()
    for i in range(5, len(framed)):
        body.append(framed[i])
    var ef = parse_error_fields(BackendMessage(MSG_ERROR, body^))
    assert_equal(ef.severity, String("ERROR"))
    assert_equal(ef.sqlstate, String("23505"))
    assert_equal(ef.message, String("duplicate key"))
    assert_equal(ef.detail, String("Key (id)=(7) already exists."))
    print("  [7] ErrorResponse 'D' field -> detail OK")


# =============================================================================
# 8. TX cursor: error on ROLLBACK; zero business steps.
# =============================================================================
def _labels_str(labels: List[String]) -> String:
    var out = String("")
    for i in range(len(labels)):
        if i > 0:
            out += String(",")
        out += labels[i]
    return out^


def test_tx_cursor_edges() raises:
    var steps = List[TxStep]()
    steps.append(TxStep.simple(String("UPDATE t SET a = 1")))
    var op = PgTxAsyncOp.for_sequence_test(steps^)
    var outcomes = List[Bool]()
    outcomes.append(True)  # BEGIN
    outcomes.append(False)  # step-0 errors
    outcomes.append(False)  # ROLLBACK itself errors
    op.test_drive_sequence(outcomes)
    assert_equal(_labels_str(op.executed_labels()), String("BEGIN,step-0,ROLLBACK"))
    assert_true(op.is_error())
    assert_false(op.is_pending())
    assert_equal(op.err_text(), String("simulated statement error"))
    _ = op^

    var empty = PgTxAsyncOp.for_sequence_test(List[TxStep]())
    var ok2 = List[Bool]()
    ok2.append(True)
    ok2.append(True)
    empty.test_drive_sequence(ok2)
    assert_equal(_labels_str(empty.executed_labels()), String("BEGIN,COMMIT"))
    assert_true(empty.is_ready())
    _ = empty^
    print("  [8] TX: ROLLBACK error -> ERR; zero steps -> BEGIN,COMMIT OK")


def main() raises:
    print("== komira_db_postgres.wire frame/pgwire/TX edges ==")
    test_row_description_overrides_seed()
    test_error_response_terminal()
    test_compaction_preserves_tail()
    test_parse_and_bind_params()
    test_incomplete_messages()
    test_rows_affected_tags()
    test_error_fields_detail()
    test_tx_cursor_edges()
    print("== PASSED ==")
