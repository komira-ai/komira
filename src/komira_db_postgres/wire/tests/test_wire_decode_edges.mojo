"""komira_db_postgres.wire: the refusal and text-format paths of the decoders.

NO NETWORK. The round-trip tests (test_binary_codec, test_scram_and_pgwire)
cover well-formed input; this file covers what they leave out:

  * every short-body refusal of the BINARY decoders (pg_binary.mojo): a body
    one byte short of its fixed width raises, the exact width decodes;
  * the text[] array_recv refusals: ndim > 1, a truncated dimension header, a
    truncated element length and a NULL element;
  * UUID hex parsing (both copies: pg_binary for binds and pg_types for
    text-format rows): upper-case hex, a bad nibble, an odd digit count and a
    short UUID;
  * the TEXT-format PgRow getters (the simple-query path), the integer text
    parser's refusals, the bounds and NULL refusals, and the binary-only
    getters refusing a text row;
  * PgError.to_string for a server error with and without detail and for a
    transport error;
  * the SCRAM server-signature length refusal (31 and 33 decoded bytes).
"""

from std.testing import assert_equal, assert_true, assert_false, assert_raises

from komira_encoding import base64_encode

from komira_db_postgres.wire.pg_types import (
    PgError,
    PgRow,
    PgRows,
    PgValue,
    OID_INT4,
    OID_INT8,
    OID_TEXT,
    OID_UUID,
    OID_JSONB,
    OID_TIMESTAMPTZ,
    OID_TEXT_ARRAY,
)
from komira_db_postgres.wire.pg_binary import (
    decode_int4_binary,
    decode_int8_binary,
    decode_uuid_binary,
    decode_jsonb_binary,
    decode_timestamptz_binary,
    decode_text_array_binary,
    uuid_hex_to_bytes,
    PG_EPOCH_OFFSET_MICROS,
)
from komira_db_postgres.wire.pgwire import put_i32_be
from komira_db_postgres.wire.scram import verify_server_signature


# -----------------------------------------------------------------------------
# helpers
# -----------------------------------------------------------------------------
def _bytes(n: Int, fill: UInt8) -> List[UInt8]:
    var out = List[UInt8]()
    for _ in range(n):
        out.append(fill)
    return out^


def _text_row(cells: List[String], nulls: List[Bool]) -> PgRow:
    """A TEXT-format PgRow (the simple-query shape): cell i is NULL when
    nulls[i]; its text is then ignored."""
    var data = List[UInt8]()
    var offsets = List[Int]()
    offsets.append(0)
    var oids = List[UInt32]()
    for i in range(len(cells)):
        if not nulls[i]:
            var b = cells[i].as_bytes()
            for j in range(len(b)):
                data.append(b[j])
        offsets.append(len(data))
        oids.append(OID_TEXT)
    return PgRow(data^, offsets^, nulls.copy(), oids^)


def _one_text_row(cell: String) -> PgRow:
    var cells = List[String]()
    cells.append(cell)
    var nulls = List[Bool]()
    nulls.append(False)
    return _text_row(cells, nulls)


def _array_header(ndim: Int32) -> List[UInt8]:
    """The 12-byte text[] array_send header: ndim, hasnull 0, element OID 25."""
    var b = List[UInt8]()
    put_i32_be(b, ndim)
    put_i32_be(b, Int32(0))
    put_i32_be(b, Int32(25))
    return b^


# =============================================================================
# 1. Binary decoders: a body one byte short raises; the exact width decodes.
# =============================================================================
def test_binary_short_bodies_refused() raises:
    # INT4: 3 bytes refused, 4 bytes decode (0x00000102 == 258).
    with assert_raises(contains="INT4 body shorter than 4 bytes"):
        _ = decode_int4_binary(Span[UInt8](_bytes(3, 1)))
    var i4 = List[UInt8]()
    put_i32_be(i4, Int32(258))
    assert_equal(decode_int4_binary(Span[UInt8](i4)), Int32(258))

    # INT8: 7 bytes refused, 8 decode.
    with assert_raises(contains="INT8 body shorter than 8 bytes"):
        _ = decode_int8_binary(Span[UInt8](_bytes(7, 1)))
    assert_equal(
        decode_int8_binary(Span[UInt8](_bytes(8, 0))), Int64(0)
    )

    # UUID: 15 bytes refused, 16 decode.
    with assert_raises(contains="UUID body shorter than 16 bytes"):
        _ = decode_uuid_binary(Span[UInt8](_bytes(15, 0xAB)))
    var u = decode_uuid_binary(Span[UInt8](_bytes(16, 0xAB)))
    assert_equal(u[15], UInt8(0xAB))

    # JSONB: an empty body (no version byte) refused; a lone version byte is
    # the empty document.
    with assert_raises(contains="JSONB body empty"):
        _ = decode_jsonb_binary(Span[UInt8](List[UInt8]()))
    assert_equal(decode_jsonb_binary(Span[UInt8](_bytes(1, 1))), String(""))

    # TIMESTAMPTZ: 7 bytes refused; 8 zero bytes are the pg epoch (2000-01-01),
    # i.e. exactly the offset in UNIX micros.
    with assert_raises(contains="TIMESTAMPTZ body shorter than 8 bytes"):
        _ = decode_timestamptz_binary(Span[UInt8](_bytes(7, 0)))
    assert_equal(
        decode_timestamptz_binary(Span[UInt8](_bytes(8, 0))),
        PG_EPOCH_OFFSET_MICROS,
    )
    print("  [1] binary short-body refusals at width-1, decode at width OK")


# =============================================================================
# 2. text[] array_recv refusals.
# =============================================================================
def test_text_array_refusals() raises:
    # 11-byte header refused; the 12-byte ndim-0 header is the empty array.
    var short_hdr = _array_header(Int32(0))
    _ = short_hdr.pop()
    with assert_raises(contains="header shorter than 12 bytes"):
        _ = decode_text_array_binary(Span[UInt8](short_hdr))
    assert_equal(
        len(decode_text_array_binary(Span[UInt8](_array_header(Int32(0))))), 0
    )

    # ndim 2: refused (only 1-D supported), naming the ndim.
    var two_d = _array_header(Int32(2))
    put_i32_be(two_d, Int32(1))
    put_i32_be(two_d, Int32(1))
    with assert_raises(contains="ndim=2 (only 1-D supported)"):
        _ = decode_text_array_binary(Span[UInt8](two_d))

    # ndim 1 with a 7-byte dimension header (needs 8: length + lower bound).
    var trunc_dim = _array_header(Int32(1))
    put_i32_be(trunc_dim, Int32(1))
    for _ in range(3):
        trunc_dim.append(UInt8(0))
    with assert_raises(contains="truncated dimension header"):
        _ = decode_text_array_binary(Span[UInt8](trunc_dim))

    # One declared element with only 3 of its 4 length bytes present.
    var trunc_len = _array_header(Int32(1))
    put_i32_be(trunc_len, Int32(1))
    put_i32_be(trunc_len, Int32(1))
    for _ in range(3):
        trunc_len.append(UInt8(0))
    with assert_raises(contains="truncated element length"):
        _ = decode_text_array_binary(Span[UInt8](trunc_len))

    # Two elements, the SECOND NULL (length -1): refused, not skipped. The
    # first element decodes on its own when it is the only one.
    var with_null = _array_header(Int32(1))
    put_i32_be(with_null, Int32(2))
    put_i32_be(with_null, Int32(1))
    put_i32_be(with_null, Int32(1))
    with_null.append(UInt8(ord("a")))
    put_i32_be(with_null, Int32(-1))
    with assert_raises(contains="contains a NULL element"):
        _ = decode_text_array_binary(Span[UInt8](with_null))
    print("  [2] text[] refusals: short header, ndim 2, dim, elem len, NULL OK")


# =============================================================================
# 3. UUID hex parsing, both copies.
# =============================================================================
def test_uuid_hex_parsing() raises:
    # Upper-case hex decodes to the same bytes as lower-case (A-F branch).
    var up = uuid_hex_to_bytes(String("ABCDEF00-0000-0000-0000-0000000000FF"))
    assert_equal(up[0], UInt8(0xAB))
    assert_equal(up[1], UInt8(0xCD))
    assert_equal(up[2], UInt8(0xEF))
    assert_equal(up[15], UInt8(0xFF))
    with assert_raises(contains="invalid hex nibble in UUID"):
        _ = uuid_hex_to_bytes(String("0g000000-0000-0000-0000-000000000000"))
    # 'G' sits just past 'F': the upper-case range must stop at F.
    with assert_raises(contains="invalid hex nibble in UUID"):
        _ = uuid_hex_to_bytes(String("0G000000-0000-0000-0000-000000000000"))
    # An odd number of hex digits leaves a lone nibble at the end.
    with assert_raises(contains="truncated UUID hex"):
        _ = uuid_hex_to_bytes(String("00000000-0000-0000-0000-00000000000"))
    # 15 whole bytes is short.
    with assert_raises(contains="UUID did not yield 16 bytes"):
        _ = uuid_hex_to_bytes(String("00000000-0000-0000-0000-0000000000"))

    # The text-format row copy (PgRow.get_uuid on a simple-query row).
    var r = _one_text_row(String("550E8400-e29b-41d4-a716-44665544000f"))
    var b = r.get_uuid(0)
    assert_equal(b[0], UInt8(0x55))
    assert_equal(b[1], UInt8(0x0E))
    assert_equal(b[4], UInt8(0xE2))
    assert_equal(b[15], UInt8(0x0F))
    with assert_raises(contains="PgRow: invalid hex nibble in UUID"):
        _ = _one_text_row(String("550e8400-e29b-41d4-a716-44665544000G")).get_uuid(0)
    with assert_raises(contains="PgRow: invalid hex nibble in UUID"):
        _ = _one_text_row(String("550e8400-e29b-41d4-a716-44665544000g")).get_uuid(0)
    with assert_raises(contains="PgRow: truncated UUID hex"):
        _ = _one_text_row(String("550e8400-e29b-41d4-a716-44665544000")).get_uuid(0)
    with assert_raises(contains="PgRow: UUID did not yield 16 bytes"):
        _ = _one_text_row(String("550e8400-e29b-41d4-a716-4466554400")).get_uuid(0)
    print("  [3] UUID hex: upper case, bad nibble, odd digits, short OK")


# =============================================================================
# 4. TEXT-format PgRow getters + refusals.
# =============================================================================
def test_text_row_getters() raises:
    var cells = List[String]()
    cells.append(String("{\"k\":1}"))  # 0 jsonb text
    cells.append(String("-9000000000"))  # 1 int8 text
    cells.append(String("00000000-0000-0000-0000-00000000000a"))  # 2 uuid
    cells.append(String("+42"))  # 3 int4 with a plus sign
    cells.append(String(""))  # 4 NULL
    var nulls = List[Bool]()
    for i in range(5):
        nulls.append(i == 4)
    var r = _text_row(cells, nulls)

    assert_equal(r.get_jsonb(0), String("{\"k\":1}"))
    assert_equal(r.get_int8(1), Int64(-9000000000))
    assert_equal(
        r.get_uuid_hex(2), String("00000000-0000-0000-0000-00000000000a")
    )
    var o4 = r.get_opt_int4(3)
    assert_true(Bool(o4))
    assert_equal(o4.value(), Int32(42))
    assert_false(Bool(r.get_opt_int4(4)))

    # Bounds: is_null is True out of range on both sides; a getter raises.
    assert_true(r.is_null(5))
    assert_true(r.is_null(-1))
    assert_false(r.is_null(3))
    with assert_raises(contains="PgRow: column index out of range"):
        _ = r.get_text(5)
    with assert_raises(contains="PgRow: column index out of range"):
        _ = r.get_text(-1)
    with assert_raises(contains="PgRow: column is NULL"):
        _ = r.get_text(4)

    # The binary-only getters refuse a TEXT row (no mis-framed bytes back).
    with assert_raises(contains="get_timestamptz_micros: column is TEXT format"):
        _ = r.get_timestamptz_micros(1)
    with assert_raises(contains="get_text_array: column is TEXT format"):
        _ = r.get_text_array(0)

    # The integer text parser's refusals.
    with assert_raises(contains="PgRow: empty integer text"):
        _ = _one_text_row(String("")).get_int8(0)
    with assert_raises(contains="PgRow: non-numeric byte in integer text"):
        _ = _one_text_row(String("12a")).get_int8(0)
    # '/' and ':' bracket the digit range.
    with assert_raises(contains="PgRow: non-numeric byte in integer text"):
        _ = _one_text_row(String("1/")).get_int8(0)
    with assert_raises(contains="PgRow: non-numeric byte in integer text"):
        _ = _one_text_row(String("1:")).get_int8(0)
    with assert_raises(contains="PgRow: integer text had no digits"):
        _ = _one_text_row(String("-")).get_int8(0)
    with assert_raises(contains="PgRow: integer text had no digits"):
        _ = _one_text_row(String("+")).get_int4(0)

    # Text-format bool: pg sends 't'/'f'; "true" and "1" are also true, and
    # "f", "false", "0" are false. Other text (e.g. "T", or an empty non-NULL
    # cell) is left unpinned: see komira#1113.
    for t in ["t", "true", "1"]:
        assert_true(_one_text_row(String(t)).get_bool(0), String(t))
    for f in ["f", "false", "0"]:
        assert_false(_one_text_row(String(f)).get_bool(0), String(f))

    # PgRows.row bounds.
    var rows_list = List[PgRow]()
    rows_list.append(_one_text_row(String("x")))
    var one_name = List[String]()
    one_name.append(String("only"))
    var rows = PgRows(rows_list^, one_name^)
    assert_equal(rows.column_name(0), String("only"))
    with assert_raises(contains="PgRows: column index out of range"):
        _ = rows.column_name(1)
    with assert_raises(contains="PgRows: column index out of range"):
        _ = rows.column_name(-1)
    assert_equal(rows.row(0).get_text(0), String("x"))
    with assert_raises(contains="PgRows: row index out of range"):
        _ = rows.row(1).get_text(0)
    with assert_raises(contains="PgRows: row index out of range"):
        _ = rows.row(-1).get_text(0)
    print("  [4] TEXT row getters + int/bounds/NULL/format refusals OK")


# =============================================================================
# 5. PgValue.bytea binds its raw bytes verbatim; PgError rendering.
# =============================================================================
def test_bytea_body_and_pg_error() raises:
    var raw = List[UInt8]()
    raw.append(UInt8(0))
    raw.append(UInt8(0xFF))
    raw.append(UInt8(ord("z")))
    var v = PgValue.bytea(String(StringSlice(unsafe_from_utf8=Span(raw))))
    var body = v.binary_body()
    assert_equal(len(body), 3)
    assert_equal(body[0], UInt8(0))
    assert_equal(body[1], UInt8(0xFF))
    assert_equal(body[2], UInt8(ord("z")))

    var with_detail = PgError(
        String("ERROR"),
        String("23505"),
        String("duplicate key"),
        String("Key (id)=(1) already exists."),
        False,
    )
    assert_equal(
        with_detail.to_string(),
        String(
            "PgError[ERROR 23505]: duplicate key (detail: Key (id)=(1) already"
            " exists.)"
        ),
    )
    var no_detail = PgError(
        String("FATAL"), String("28P01"), String("bad password"), String(""), False
    )
    assert_equal(
        no_detail.to_string(), String("PgError[FATAL 28P01]: bad password")
    )
    var transport = PgError.transport(String("socket closed"))
    assert_true(transport.is_transport)
    assert_equal(
        transport.to_string(), String("PgError[transport]: socket closed")
    )
    print("  [5] bytea body verbatim; PgError with/without detail, transport OK")


# =============================================================================
# 6. SCRAM: the server signature must decode to exactly 32 bytes.
# =============================================================================
def test_scram_signature_length() raises:
    var expected = Array[UInt8, 32](fill=7)
    # 32 matching bytes verify.
    assert_true(
        verify_server_signature(expected, base64_encode(Span[UInt8](_bytes(32, 7))))
    )
    # 31 bytes: refused with the measured length.
    with assert_raises(contains="(31 != 32 bytes)"):
        _ = verify_server_signature(
            expected, base64_encode(Span[UInt8](_bytes(31, 7)))
        )
    # 33 bytes whose first 32 MATCH: still refused (a prefix compare would
    # accept a longer forged value).
    with assert_raises(contains="(33 != 32 bytes)"):
        _ = verify_server_signature(
            expected, base64_encode(Span[UInt8](_bytes(33, 7)))
        )
    print("  [6] SCRAM v= length refusal at 31 and 33 bytes OK")


def main() raises:
    print("== komira_db_postgres.wire decoder edges ==")
    test_binary_short_bodies_refused()
    test_text_array_refusals()
    test_uuid_hex_parsing()
    test_text_row_getters()
    test_bytea_body_and_pg_error()
    test_scram_signature_length()
    print("== PASSED ==")
