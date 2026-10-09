"""komira_db_postgres.pg_driver: the DbValue <-> PgValue mappers and dialect.

NO NETWORK. `PgDatabase` runs every statement through two pure maps, both
public for the poll-shaped handlers that bypass `PgDatabase.query`:

  * `to_pg_params`: a backend-neutral `DbValue` becomes a `PgValue` tagged
    with the pg OID its binary bind needs (UUID 2950, INT4 23, INT8 20,
    TIMESTAMPTZ 1184, JSONB 3802, TEXT[] 1009, BOOL 16, BYTES 17; TEXT and the
    floats bind as TEXT 25), carrying the canonical text unchanged; a NULL
    keeps its OID.
  * `pg_rows_to_db_rows`: a BINARY `PgRow` is rendered column by column (by
    the result OID) to the canonical text and logical type the `DbRow`
    getters decode; a NULL column stays NULL; the column count is the smaller
    of the OID list and the row.

Plus the dialect tokens the shared SQL renderer splices in.
"""

from std.testing import assert_equal, assert_true, assert_false

from komira_db.db_value import (
    DbValue,
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
from komira_db_postgres.pg_driver import (
    PgDatabase,
    to_pg_params,
    pg_rows_to_db_rows,
)
from komira_db_postgres.wire.pg_types import PgRow, PgRows
from komira_db_postgres.wire.pg_binary import (
    encode_int4_binary,
    encode_int8_binary,
    encode_text_binary,
    encode_uuid_binary,
    encode_jsonb_binary,
    encode_timestamptz_binary,
    encode_text_array_binary,
)


# =============================================================================
# 1. to_pg_params: the OID per logical type, text passed through, NULLs.
# =============================================================================
def test_to_pg_params_oids() raises:
    var ub = Array[UInt8, 16](fill=0x11)
    var arr = List[String]()
    arr.append(String("a"))
    arr.append(String("b"))
    var raw = List[UInt8]()
    raw.append(UInt8(0))
    raw.append(UInt8(0xFE))
    var vals = List[DbValue]()
    vals.append(DbValue.uuid(ub))  # 0
    vals.append(DbValue.int4(Int32(-5)))  # 1
    vals.append(DbValue.int8(Int64(1) << 40))  # 2
    vals.append(DbValue.timestamptz_micros(Int64(1700000000000000)))  # 3
    vals.append(DbValue.jsonb(String("{\"a\":1}")))  # 4
    vals.append(DbValue.text_array(arr))  # 5
    vals.append(DbValue.bool_val(True))  # 6
    vals.append(DbValue.bytes(raw))  # 7
    vals.append(DbValue.text(String("plain")))  # 8
    vals.append(DbValue.float8(Float64(1.5)))  # 9
    vals.append(DbValue.float4(Float32(2.5)))  # 10
    vals.append(DbValue.null(LOGICAL_INT8))  # 11
    vals.append(DbValue.null(LOGICAL_UUID))  # 12

    var want = List[UInt32]()
    for o in [2950, 23, 20, 1184, 3802, 1009, 16, 17, 25, 25, 25, 20, 2950]:
        want.append(UInt32(o))

    var got = to_pg_params(vals)
    assert_equal(len(got), len(vals))
    for i in range(len(vals)):
        assert_equal(got[i].oid, want[i], String("oid of param ") + String(i))
        assert_equal(got[i].is_null, vals[i].is_null)
        assert_equal(got[i].as_text(), vals[i].as_text())
    assert_true(got[11].is_null)
    assert_equal(got[1].as_text(), String("-5"))
    assert_equal(got[5].as_text(), String("{a,b}"))
    # The mapped values encode as the binary body their OID names: INT4 is 4
    # bytes, BOOL 1 byte 0x01, BYTES the raw bytes verbatim.
    assert_equal(len(got[1].binary_body()), 4)
    var bb = got[6].binary_body()
    assert_equal(len(bb), 1)
    assert_equal(bb[0], UInt8(1))
    var rb = got[7].binary_body()
    assert_equal(len(rb), 2)
    assert_equal(rb[1], UInt8(0xFE))
    assert_equal(len(to_pg_params(List[DbValue]())), 0)
    print("  [1] to_pg_params: 13 values, OID per logical type, NULLs OK")


# =============================================================================
# 2. pg_rows_to_db_rows: each result OID renders to its canonical text.
# =============================================================================
def _append(mut data: List[UInt8], mut offsets: List[Int], body: List[UInt8]):
    for i in range(len(body)):
        data.append(body[i])
    offsets.append(len(data))


def _binary_row(arr_elems: List[String]) raises -> PgRow:
    var data = List[UInt8]()
    var offsets = List[Int]()
    offsets.append(0)
    var t = List[UInt8]()
    t.append(UInt8(1))
    _append(data, offsets, t)  # 0 bool true
    var f = List[UInt8]()
    f.append(UInt8(0))
    _append(data, offsets, f)  # 1 bool false
    _append(
        data,
        offsets,
        encode_uuid_binary(String("550e8400-e29b-41d4-a716-446655440000")),
    )  # 2 uuid
    _append(data, offsets, encode_int4_binary(Int32(-7)))  # 3 int4
    _append(data, offsets, encode_int8_binary(Int64(-(Int64(1) << 40))))  # 4
    _append(
        data, offsets, encode_timestamptz_binary(Int64(1700000000123456))
    )  # 5 timestamptz (unix micros)
    _append(data, offsets, encode_jsonb_binary(String("{\"k\":2}")))  # 6
    _append(data, offsets, encode_text_array_binary(arr_elems))  # 7 text[]
    var blob = List[UInt8]()
    blob.append(UInt8(0x00))
    blob.append(UInt8(0x7F))
    _append(data, offsets, blob)  # 8 bytea
    _append(data, offsets, encode_text_binary(String("hello")))  # 9 text
    _append(data, offsets, encode_text_binary(String("vc")))  # 10 varchar
    _append(data, offsets, List[UInt8]())  # 11 NULL (int8 column)
    var nulls = List[Bool]()
    for i in range(12):
        nulls.append(i == 11)
    var oids = List[UInt32]()
    for o in [16, 16, 2950, 23, 20, 1184, 3802, 1009, 17, 25, 1043, 20]:
        oids.append(UInt32(o))
    return PgRow(data^, offsets^, nulls^, oids^, True)


def _oids() -> List[UInt32]:
    var oids = List[UInt32]()
    for o in [16, 16, 2950, 23, 20, 1184, 3802, 1009, 17, 25, 1043, 20]:
        oids.append(UInt32(o))
    return oids^


def _names(n: Int) -> List[String]:
    var names = List[String]()
    for i in range(n):
        names.append(String("c") + String(i))
    return names^


def test_render_each_oid() raises:
    var two = List[String]()
    two.append(String("x"))
    two.append(String("yz"))
    var rows_list = List[PgRow]()
    rows_list.append(_binary_row(two))
    rows_list.append(_binary_row(List[String]()))
    var pg_rows = PgRows(rows_list^, _names(12))
    var db = pg_rows_to_db_rows(pg_rows, _oids(), _names(12))
    assert_equal(db.__len__(), 2)
    assert_equal(db.column_count(), 12)
    ref r = db.row(0)
    assert_equal(r.col_count(), 12)
    assert_equal(r.column_name(11), String("c11"))

    var want_text = List[String]()
    want_text.append(String("true"))
    want_text.append(String("false"))
    want_text.append(String("550e8400-e29b-41d4-a716-446655440000"))
    want_text.append(String("-7"))
    want_text.append(String("-1099511627776"))
    want_text.append(String("1700000000123456"))
    want_text.append(String("{\"k\":2}"))
    want_text.append(String("{x,yz}"))
    want_text.append(String(""))  # bytea checked byte-wise below
    want_text.append(String("hello"))
    want_text.append(String("vc"))
    var want_lt = List[Int]()
    for lt in [
        LOGICAL_BOOL,
        LOGICAL_BOOL,
        LOGICAL_UUID,
        LOGICAL_INT4,
        LOGICAL_INT8,
        LOGICAL_TIMESTAMPTZ,
        LOGICAL_JSONB,
        LOGICAL_TEXT_ARRAY,
        LOGICAL_BYTES,
        LOGICAL_TEXT,
        LOGICAL_TEXT,
        LOGICAL_TEXT,
    ]:
        want_lt.append(lt)
    for c in range(11):
        assert_false(r.is_null(c))
        assert_equal(r.logical_type(c), want_lt[c], String("ltype col ") + String(c))
        if c != 8:
            assert_equal(r.get_text(c), want_text[c], String("text col ") + String(c))
    var blob = r.raw_bytes(8)
    assert_equal(len(blob), 2)
    assert_equal(blob[0], UInt8(0x00))
    assert_equal(blob[1], UInt8(0x7F))
    # NULL stays NULL (tagged TEXT; the getter path reads is_null first).
    assert_true(r.is_null(11))
    assert_equal(r.logical_type(11), LOGICAL_TEXT)
    # The second row's empty array renders as the empty literal.
    assert_equal(db.row(1).get_text(7), String("{}"))
    assert_equal(db.row(1).get_text(3), String("-7"))
    print("  [2] pg_rows_to_db_rows: 12 OIDs incl. NULL, 2 rows OK")


# =============================================================================
# 3. Column count: min(result OIDs, row columns).
# =============================================================================
def test_column_count_is_min() raises:
    var rows_list = List[PgRow]()
    rows_list.append(_binary_row(List[String]()))
    var pg_rows = PgRows(rows_list^, _names(12))
    # Fewer OIDs than row columns: only the first 3 render.
    var three = List[UInt32]()
    three.append(UInt32(16))
    three.append(UInt32(16))
    three.append(UInt32(2950))
    var db3 = pg_rows_to_db_rows(pg_rows, three, _names(3))
    assert_equal(db3.row(0).col_count(), 3)
    assert_equal(db3.row(0).get_text(2), String("550e8400-e29b-41d4-a716-446655440000"))
    # More OIDs than row columns: the row's 12 columns render, no overrun.
    var more = _oids()
    more.append(UInt32(25))
    more.append(UInt32(25))
    var db14 = pg_rows_to_db_rows(pg_rows, more, _names(14))
    assert_equal(db14.row(0).col_count(), 12)
    assert_equal(db14.row(0).get_text(10), String("vc"))
    # No rows: no DbRow, the names still carried.
    var none = PgRows(List[PgRow](), _names(2))
    var db0 = pg_rows_to_db_rows(none, _oids(), _names(2))
    assert_equal(db0.__len__(), 0)
    assert_equal(db0.column_count(), 2)
    print("  [3] rendered column count = min(OIDs, row columns) OK")


# =============================================================================
# 4. Dialect tokens.
# =============================================================================
def test_dialect_tokens() raises:
    assert_equal(PgDatabase.dialect(), String("pg"))
    assert_equal(PgDatabase.placeholder(0), String("$1"))
    assert_equal(PgDatabase.placeholder(9), String("$10"))
    assert_equal(PgDatabase.now_expr(), String("NOW()"))
    assert_equal(String(PgDatabase.PK_DEFAULT), String("id"))
    print("  [4] dialect pg, $1-based placeholders, NOW() OK")


def main() raises:
    print("== komira_db_postgres.pg_driver mappers ==")
    test_to_pg_params_oids()
    test_render_each_oid()
    test_column_count_is_min()
    test_dialect_tokens()
    print("== PASSED ==")
