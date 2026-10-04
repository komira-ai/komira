"""komira_db_postgres.wire BINARY-format codec round-trip guard.

NO NETWORK. Exercises the extended-protocol BINARY codecs (pg_binary.mojo) +
the binary-aware PgRow getters + the extended-protocol message encoders
(pgwire.mojo) WITHOUT a live server, by:

  * round-tripping each of the 7 OIDs through encode_*_binary ->
    decode_*_binary and asserting byte/semantic exactness (esp. the
    TIMESTAMPTZ 2000-epoch offset, the TEXT[] array_send header, the UUID 16
    raw bytes, and the JSONB version byte),
  * building a BINARY-format PgRow by hand (the wire shape a DataRow body
    produces) and reading it back through the public get_* getters,
  * accumulating >=3 binary rows in a List[PgRow] and decoding after the
    growth reallocs (the flat-PgRow relocation guard, on the binary path),
  * round-tripping the PgValue binary bodies (the bind-param carrier).

No database server, no TLS.
"""

from komira_db_postgres.wire.pg_types import (
    PgRow,
    PgRows,
    PgValue,
    pg_param_binary,
    binary_row_from_data_message,
    OID_BOOL,
    OID_INT4,
    OID_INT8,
    OID_TEXT,
    OID_UUID,
    OID_JSONB,
    OID_TIMESTAMPTZ,
    OID_TEXT_ARRAY,
)
from komira_db_postgres.wire.pg_binary import (
    encode_int4_binary,
    encode_int8_binary,
    encode_text_binary,
    encode_uuid_binary,
    encode_jsonb_binary,
    encode_timestamptz_binary,
    encode_text_array_binary,
    decode_int4_binary,
    decode_int8_binary,
    decode_text_binary,
    decode_uuid_binary,
    decode_jsonb_binary,
    decode_timestamptz_binary,
    decode_text_array_binary,
    uuid_hex_to_bytes,
    uuid_bytes_to_hex,
    PG_EPOCH_OFFSET_MICROS,
)
from komira_db_postgres.wire.pgwire import (
    BackendMessage,
    put_i16_be,
    put_i32_be,
    encode_parse,
    encode_bind,
    encode_describe_statement,
    encode_execute,
    encode_sync,
    parse_parameter_description,
)


def _eq(got: Int32, want: Int32, label: String) raises:
    if got != want:
        raise Error(
            label + " mismatch: got " + String(Int(got)) + " want "
            + String(Int(want))
        )


def _eq(got: Int64, want: Int64, label: String) raises:
    if got != want:
        raise Error(
            label + " mismatch: got " + String(Int(got)) + " want "
            + String(Int(want))
        )


# =============================================================================
# Per-OID binary round-trips.
# =============================================================================
def _rt_int4() raises:
    var vals = List[Int32]()
    vals.append(0)
    vals.append(42)
    vals.append(-1)
    vals.append(2147483647)
    vals.append(-2147483648)
    for v in vals:
        var enc = encode_int4_binary(v)
        if len(enc) != 4:
            raise Error("INT4 body not 4 bytes")
        var dec = decode_int4_binary(Span[UInt8](enc))
        _eq(dec, v, "INT4")


def _rt_int8() raises:
    var vals = List[Int64]()
    vals.append(0)
    vals.append(9000000000)
    vals.append(-1)
    vals.append(9223372036854775807)
    vals.append(-9223372036854775808)
    for v in vals:
        var enc = encode_int8_binary(v)
        if len(enc) != 8:
            raise Error("INT8 body not 8 bytes")
        var dec = decode_int8_binary(Span[UInt8](enc))
        _eq(dec, v, "INT8")


def _rt_text() raises:
    # ASCII round-trips exactly through the chr()-accumulating String decoder.
    var s = String("hello world / control-plane:job-id_42")
    var enc = encode_text_binary(s)
    var dec = decode_text_binary(Span[UInt8](enc))
    if dec != s:
        raise Error("TEXT round-trip mismatch: '" + dec + "'")
    # Multi-byte UTF-8: the BINARY encode is a raw byte copy, so the wire bytes
    # must be byte-identical to the source's UTF-8 bytes (the String-level
    # round-trip is governed by owned_utf8_string's chr() reinterpretation,
    # which is a separate concern from the codec's byte fidelity).
    var u = String("ünïcödé")
    var ub = u.as_bytes()
    var uenc = encode_text_binary(u)
    if len(uenc) != len(ub):
        raise Error("UTF-8 TEXT byte length changed by encode")
    for i in range(len(ub)):
        if uenc[i] != ub[i]:
            raise Error("UTF-8 TEXT byte mismatch at " + String(i))
    # Empty text.
    var e = encode_text_binary(String(""))
    if len(e) != 0:
        raise Error("empty TEXT body not empty")
    if decode_text_binary(Span[UInt8](e)) != String(""):
        raise Error("empty TEXT decode mismatch")


def _rt_uuid() raises:
    var hex = String("550e8400-e29b-41d4-a716-446655440000")
    var enc = encode_uuid_binary(hex)
    if len(enc) != 16:
        raise Error("UUID body not 16 bytes")
    # First byte 0x55, second 0x0e, last 0x00.
    if enc[0] != UInt8(0x55) or enc[1] != UInt8(0x0e) or enc[15] != UInt8(0):
        raise Error("UUID byte layout wrong")
    var dec = decode_uuid_binary(Span[UInt8](enc))
    for i in range(16):
        if dec[i] != enc[i]:
            raise Error("UUID decode byte mismatch at " + String(i))
    # bytes -> hex -> bytes is stable.
    var back_hex = uuid_bytes_to_hex(Span[UInt8](enc))
    if back_hex != hex:
        raise Error("UUID hex round-trip: '" + back_hex + "' != '" + hex + "'")
    var raw2 = uuid_hex_to_bytes(back_hex)
    for i in range(16):
        if raw2[i] != enc[i]:
            raise Error("UUID hex->bytes mismatch at " + String(i))


def _rt_jsonb() raises:
    var js = String('{"k": 1, "arr": [1,2,3]}')
    var enc = encode_jsonb_binary(js)
    # First byte MUST be the version byte 0x01.
    if enc[0] != UInt8(1):
        raise Error("JSONB version byte not 1")
    if len(enc) != len(js.as_bytes()) + 1:
        raise Error("JSONB body length wrong")
    var dec = decode_jsonb_binary(Span[UInt8](enc))
    if dec != js:
        raise Error("JSONB round-trip mismatch: '" + dec + "'")
    # A bad version byte must raise (not silently mis-frame).
    var bad = List[UInt8]()
    bad.append(UInt8(9))
    bad.append(UInt8(ord("x")))
    var raised = False
    try:
        _ = decode_jsonb_binary(Span[UInt8](bad))
    except:
        raised = True
    if not raised:
        raise Error("JSONB bad-version-byte did not raise")


def _rt_timestamptz() raises:
    # An arbitrary instant: 1894708800 unix seconds.
    var unix_micros = Int64(1894708800) * Int64(1000000)
    var enc = encode_timestamptz_binary(unix_micros)
    if len(enc) != 8:
        raise Error("TIMESTAMPTZ body not 8 bytes")
    var dec = decode_timestamptz_binary(Span[UInt8](enc))
    _eq(dec, unix_micros, "TIMESTAMPTZ µs")
    # The wire form on the buffer MUST be the pg-epoch value (unix - offset).
    var pg_micros = unix_micros - PG_EPOCH_OFFSET_MICROS
    # Re-decode the raw bytes as a plain i64 and confirm it equals pg_micros.
    var raw = (
        (Int64(Int(enc[0])) << 56)
        | (Int64(Int(enc[1])) << 48)
        | (Int64(Int(enc[2])) << 40)
        | (Int64(Int(enc[3])) << 32)
        | (Int64(Int(enc[4])) << 24)
        | (Int64(Int(enc[5])) << 16)
        | (Int64(Int(enc[6])) << 8)
        | Int64(Int(enc[7]))
    )
    _eq(raw, pg_micros, "TIMESTAMPTZ pg-epoch wire")
    # The pg epoch itself (2000-01-01) must encode to all-zero bytes.
    var zero = encode_timestamptz_binary(PG_EPOCH_OFFSET_MICROS)
    for i in range(8):
        if zero[i] != UInt8(0):
            raise Error("pg-epoch instant did not encode to zero bytes")


def _rt_text_array() raises:
    var elems = List[String]()
    elems.append(String("a"))
    elems.append(String("bb"))
    elems.append(String("ccc"))
    var enc = encode_text_array_binary(elems)
    var dec = decode_text_array_binary(Span[UInt8](enc))
    if len(dec) != 3:
        raise Error("text[] elem count " + String(len(dec)))
    if dec[0] != String("a") or dec[1] != String("bb") or dec[2] != String(
        "ccc"
    ):
        raise Error("text[] element mismatch")
    # Empty array.
    var empty = List[String]()
    var enc_e = encode_text_array_binary(empty)
    var dec_e = decode_text_array_binary(Span[UInt8](enc_e))
    if len(dec_e) != 0:
        raise Error("empty text[] decoded " + String(len(dec_e)) + " elems")


# =============================================================================
# Binary-format PgRow build + read-back through the public getters.
# =============================================================================
def _make_binary_datarow(
    bodies: List[List[UInt8]], nulls: List[Bool]
) -> BackendMessage:
    """Construct the BODY of a DataRow ('D') message in the binary wire shape:
    Int16 column count, then per column Int32 length (-1 == NULL) + bytes."""
    var body = List[UInt8]()
    put_i16_be(body, Int16(len(bodies)))
    for i in range(len(bodies)):
        if nulls[i]:
            put_i32_be(body, Int32(-1))
        else:
            ref b = bodies[i]
            put_i32_be(body, Int32(len(b)))
            for byte in b:
                body.append(byte)
    return BackendMessage(UInt8(ord("D")), body^)


def _binary_row_seven_oids() raises -> PgRow:
    var bodies = List[List[UInt8]]()
    bodies.append(encode_int8_binary(Int64(9000000000)))
    bodies.append(encode_int4_binary(Int32(42)))
    bodies.append(encode_text_binary(String("hello world")))
    bodies.append(encode_uuid_binary(String(
        "550e8400-e29b-41d4-a716-446655440000"
    )))
    bodies.append(encode_jsonb_binary(String('{"k": 1}')))
    bodies.append(encode_timestamptz_binary(
        Int64(1894708800) * Int64(1000000)
    ))
    var arr = List[String]()
    arr.append(String("a"))
    arr.append(String("b"))
    arr.append(String("c"))
    bodies.append(encode_text_array_binary(arr))

    var nulls = List[Bool]()
    for _i in range(7):
        nulls.append(False)

    var oids = List[UInt32]()
    oids.append(OID_INT8)
    oids.append(OID_INT4)
    oids.append(OID_TEXT)
    oids.append(OID_UUID)
    oids.append(OID_JSONB)
    oids.append(OID_TIMESTAMPTZ)
    oids.append(OID_TEXT_ARRAY)

    var msg = _make_binary_datarow(bodies, nulls)
    return binary_row_from_data_message(msg, oids)


def _check_seven_oid_row(r: PgRow) raises:
    _eq(r.get_int8(0), Int64(9000000000), "row INT8")
    _eq(r.get_int4(1), Int32(42), "row INT4")
    if r.get_text(2) != String("hello world"):
        raise Error("row TEXT mismatch")
    var uu = r.get_uuid(3)
    if uu[0] != UInt8(0x55) or uu[15] != UInt8(0):
        raise Error("row UUID bytes mismatch")
    if r.get_uuid_hex(3) != String("550e8400-e29b-41d4-a716-446655440000"):
        raise Error("row UUID hex mismatch")
    if r.get_jsonb(4) != String('{"k": 1}'):
        raise Error("row JSONB mismatch: '" + r.get_jsonb(4) + "'")
    _eq(
        r.get_timestamptz_micros(5),
        Int64(1894708800) * Int64(1000000),
        "row TIMESTAMPTZ µs",
    )
    var arr = r.get_text_array(6)
    if len(arr) != 3 or arr[0] != String("a") or arr[2] != String("c"):
        raise Error("row TEXT[] mismatch")


def _binary_multirow() raises:
    # Accumulate >=3 binary rows and decode after the List[PgRow] growth moves
    # (the flat-PgRow relocation guard, on the binary path).
    var ns = List[Int]()
    ns.append(3)
    ns.append(10)
    ns.append(100)
    for n in ns:
        var rows = List[PgRow]()
        for r in range(n):
            var bodies = List[List[UInt8]]()
            bodies.append(encode_int4_binary(Int32(r)))
            bodies.append(encode_int8_binary(Int64(r) * Int64(1000)))
            var nulls = List[Bool]()
            nulls.append(False)
            nulls.append(False)
            var oids = List[UInt32]()
            oids.append(OID_INT4)
            oids.append(OID_INT8)
            var msg = _make_binary_datarow(bodies, nulls)
            rows.append(binary_row_from_data_message(msg, oids))
        var rs = PgRows(rows^, List[String]())
        if rs.__len__() != n:
            raise Error("binary multirow len " + String(rs.__len__()))
        for r in range(n):
            ref row = rs.row(r)
            _eq(row.get_int4(0), Int32(r), "multirow INT4 r=" + String(r))
            _eq(
                row.get_int8(1),
                Int64(r) * Int64(1000),
                "multirow INT8 r=" + String(r),
            )


def _binary_null_column() raises:
    var bodies = List[List[UInt8]]()
    bodies.append(List[UInt8]())  # ignored for NULL
    bodies.append(encode_int4_binary(Int32(7)))
    var nulls = List[Bool]()
    nulls.append(True)
    nulls.append(False)
    var oids = List[UInt32]()
    oids.append(OID_INT4)
    oids.append(OID_INT4)
    var msg = _make_binary_datarow(bodies, nulls)
    var row = binary_row_from_data_message(msg, oids)
    if not row.is_null(0):
        raise Error("binary NULL column not flagged null")
    if row.is_null(1):
        raise Error("binary non-null column flagged null")
    _eq(row.get_int4(1), Int32(7), "binary NULL sibling")
    var opt = row.get_opt_int4(0)
    if opt:
        raise Error("get_opt_int4 on NULL returned a value")


# =============================================================================
# PgValue binary-body carrier round-trips.
# =============================================================================
def _pgvalue_bodies() raises:
    var v4 = PgValue.int4(Int32(42))
    _eq(decode_int4_binary(Span[UInt8](v4.binary_body())), Int32(42), "PgValue int4")
    var v8 = PgValue.int8(Int64(9000000000))
    _eq(
        decode_int8_binary(Span[UInt8](v8.binary_body())),
        Int64(9000000000),
        "PgValue int8",
    )
    var vt = PgValue.text(String("abc"))
    if decode_text_binary(Span[UInt8](vt.binary_body())) != String("abc"):
        raise Error("PgValue text body mismatch")
    var vj = PgValue.jsonb(String('{"x":1}'))
    if decode_jsonb_binary(Span[UInt8](vj.binary_body())) != String('{"x":1}'):
        raise Error("PgValue jsonb body mismatch")
    var vu = PgValue.uuid_hex(String("550e8400-e29b-41d4-a716-446655440000"))
    var ud = decode_uuid_binary(Span[UInt8](vu.binary_body()))
    if ud[0] != UInt8(0x55) or ud[15] != UInt8(0):
        raise Error("PgValue uuid body mismatch")
    var vts = PgValue.timestamptz_micros(Int64(1894708800) * Int64(1000000))
    _eq(
        decode_timestamptz_binary(Span[UInt8](vts.binary_body())),
        Int64(1894708800) * Int64(1000000),
        "PgValue timestamptz",
    )
    var arr = List[String]()
    arr.append(String("a"))
    arr.append(String("b"))
    var va = PgValue.text_array(arr)
    var ad = decode_text_array_binary(Span[UInt8](va.binary_body()))
    if len(ad) != 2 or ad[0] != String("a"):
        raise Error("PgValue text_array body mismatch")
    # NULL carries an empty binary body.
    var vn = PgValue.null(OID_INT4)
    if not vn.is_null or len(vn.binary_body()) != 0:
        raise Error("PgValue null body not empty")

    # Relocation guard: accumulate many PgValue in a List[PgValue] across growth
    # reallocs (cap 1->2->4->8->16...) and read each back. This is the shape
    # the bind path builds; it must not corrupt the heap.
    var many = List[PgValue]()
    for k in range(64):
        many.append(PgValue.int8(Int64(k) * Int64(1000000000)))
        many.append(PgValue.text(String("elem_") + String(k)))
    if len(many) != 128:
        raise Error("PgValue list len " + String(len(many)))
    for k in range(64):
        var iv = decode_int8_binary(Span[UInt8](many[2 * k].binary_body()))
        if iv != Int64(k) * Int64(1000000000):
            raise Error("PgValue list int8 corruption at " + String(k))
        if many[2 * k + 1].as_text() != String("elem_") + String(k):
            raise Error("PgValue list text corruption at " + String(k))


# =============================================================================
# REGRESSION: a boolean must bind as OID_BOOL with a 1-byte binary body
# (0x01/0x00), NOT as a 4-byte ASCII "true" under a binary format code. The
# latter produces
#   "PgError[ERROR 22P03]: incorrect binary data format in bind parameter N"
# on EVERY pg INSERT/UPDATE of a native BOOLEAN column. SQLite is unaffected
# (it stores bool as 0/1 text), so this is a pg-vs-sqlite divergence a parity
# test surfaces. The fix: komira_db maps its logical bool to OID_BOOL, and
# pg_param_binary(OID_BOOL) emits the 1 byte.
# =============================================================================
def _bool_binary_bind() raises:
    # The bind body the wire actually sends must be EXACTLY 1 byte.
    var bt = pg_param_binary(OID_BOOL, String("true"))
    if len(bt) != 1 or bt[0] != UInt8(1):
        raise Error(
            "pg_param_binary(OID_BOOL,'true') must be 1 byte 0x01, got len "
            + String(len(bt))
        )
    var bf = pg_param_binary(OID_BOOL, String("false"))
    if len(bf) != 1 or bf[0] != UInt8(0):
        raise Error(
            "pg_param_binary(OID_BOOL,'false') must be 1 byte 0x00, got len "
            + String(len(bf))
        )
    # The PgValue carrier (the bind-param shape) must produce the same 1-byte
    # body when tagged OID_BOOL.
    var v = PgValue(OID_BOOL, False, String("true"))
    var vb = v.binary_body()
    if len(vb) != 1 or vb[0] != UInt8(1):
        raise Error("PgValue(OID_BOOL,'true').binary_body() not 1 byte 0x01")


# =============================================================================
# Extended-protocol frame encoders — structural goldens (no server).
# =============================================================================
def _frame_encoders() raises:
    # Parse: 'P' + len + name CString + query CString + Int16(0) param count.
    var p = encode_parse(String("s1"), String("SELECT 1"), List[UInt32]())
    if p[0] != UInt8(ord("P")):
        raise Error("Parse type byte wrong")
    # Bind: 'B' + len ... result format codes = [1] when all_binary. Params
    # are passed in the FLAT data+offsets layout (no List[List]).
    var fmts = List[Int16]()
    fmts.append(Int16(1))
    var pdata = encode_int4_binary(Int32(5))
    var poffsets = List[Int]()
    poffsets.append(0)
    poffsets.append(len(pdata))
    var nulls = List[Bool]()
    nulls.append(False)
    var b = encode_bind(
        String(""), String("s1"), fmts, pdata, poffsets, nulls, True
    )
    if b[0] != UInt8(ord("B")):
        raise Error("Bind type byte wrong")
    # Describe-statement: 'D' + len + 'S' + name.
    var d = encode_describe_statement(String("s1"))
    if d[0] != UInt8(ord("D")) or d[5] != UInt8(ord("S")):
        raise Error("Describe-statement frame wrong")
    # Execute: 'E' + len + portal + Int32 max-rows.
    var e = encode_execute(String(""), Int32(0))
    if e[0] != UInt8(ord("E")):
        raise Error("Execute type byte wrong")
    # Sync: 'S' + len(4), empty body.
    var s = encode_sync()
    if s[0] != UInt8(ord("S")) or len(s) != 5:
        raise Error("Sync frame wrong")
    # ParameterDescription parse: body == Int16 count + Int32 OIDs.
    var pd_body = List[UInt8]()
    put_i16_be(pd_body, Int16(2))
    put_i32_be(pd_body, Int32(23))  # int4
    put_i32_be(pd_body, Int32(25))  # text
    var pd = BackendMessage(UInt8(ord("t")), pd_body^)
    var oids = parse_parameter_description(pd)
    if len(oids) != 2 or oids[0] != UInt32(23) or oids[1] != UInt32(25):
        raise Error("ParameterDescription parse wrong")


def test_binary_codec() raises:
    print("  test_binary_codec (extended-protocol binary codecs)...")
    _rt_int4()
    _rt_int8()
    _rt_text()
    _rt_uuid()
    _rt_jsonb()
    _rt_timestamptz()
    _rt_text_array()
    print("    7-OID binary round-trips OK (incl. tstz epoch, text[], jsonb v1)")

    var r = _binary_row_seven_oids()
    _check_seven_oid_row(r)
    print("    binary PgRow 7-OID read-back via public getters OK")

    _binary_multirow()
    print("    binary multi-row (N=3,10,100) accumulation + decode OK")

    _binary_null_column()
    print("    binary NULL column + get_opt_* OK")

    _pgvalue_bodies()
    print("    PgValue binary-body carriers OK")

    _bool_binary_bind()
    print("    LOGICAL_BOOL -> OID_BOOL 1-byte binary bind (22P03 regression) OK")

    _frame_encoders()
    print("    extended-protocol frame encoders + ParameterDescription OK")


def main() raises:
    print("== komira_db_postgres.wire BINARY codec round-trip guard ==")
    test_binary_codec()
    print("== PASSED ==")
