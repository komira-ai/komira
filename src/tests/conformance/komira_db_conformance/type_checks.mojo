# =============================================================================
# komira_db_conformance/type_checks.mojo -- every logical type round-trips
#   through `put` and `get_by_key`.
# =============================================================================
#
# What a value reads back as is the DbRow contract (komira_db/db_row.mojo):
# each cell is the canonical text the matching typed getter decodes, so the
# check reads each type through its getter (get_text, get_int4, get_int8,
# get_uuid, get_timestamptz_micros, get_bytes, get_jsonb, get_text_array).
# DbRow has no float or bool getter: a FLOAT cell is compared as the number its
# text parses to, and a BOOL cell as the generated decoder reads it
# (`_db_decode_bool`: "true", "1" or "t" is true, other text false).
#
# Each value goes into its own row of conf_types (id r0, r1, ...) with every
# other column left out, and is read back alone.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_async.reactor.reactor import Reactor

from komira_db import (
    Database,
    DbRow,
    DbValue,
    LOGICAL_BOOL,
    LOGICAL_BYTES,
    LOGICAL_FLOAT4,
    LOGICAL_FLOAT8,
    LOGICAL_INT4,
    LOGICAL_INT8,
    LOGICAL_JSONB,
    LOGICAL_TEXT,
    LOGICAL_TEXT_ARRAY,
    LOGICAL_TIMESTAMPTZ,
    LOGICAL_UUID,
)

from komira_db_conformance.common import (
    Rt,
    assert_bytes,
    assert_strs,
    new_rt,
    strs,
)
from komira_db_conformance.targets import NeutralTarget, TYPES


def _store_and_read[
    T: NeutralTarget
](mut t: T, col: String, vals: List[DbValue]) raises -> List[DbRow]:
    """Put each of `vals` in its own conf_types row (column `col` only) on a
    fresh database and read each back by key, projecting `col`."""
    var db = t.fresh()
    var rt = new_rt()
    ref reactor = rt.reactor()
    var cols = List[String]()
    cols.append(String("id"))
    cols.append(col)
    for i in range(len(vals)):
        var row = List[DbValue]()
        row.append(DbValue.text(String("r") + String(i)))
        row.append(vals[i].copy())
        var n = db.put[Rt](reactor, String(TYPES), cols, row)
        assert_equal(n, UInt64(1), col + String(": put reports one row"))
    var out = List[DbRow]()
    var proj = List[String]()
    proj.append(col)
    for i in range(len(vals)):
        var got = db.get_by_key[Rt](
            reactor,
            String(TYPES),
            proj,
            String("id"),
            DbValue.text(String("r") + String(i)),
        )
        assert_true(
            got.__bool__(), col + String(": row r") + String(i) + " not found"
        )
        out.append(got.take())
    return out^


def check_text[T: NeutralTarget](mut t: T) raises:
    """TEXT: ASCII, empty (distinct from NULL), non-ASCII UTF-8, quotes and
    control characters come back byte for byte."""
    var want = strs(
        "plain",
        "",
        "Zürich ⛔ 東京 café",
        "tab\tnew\nline",
        "O'Brien \"q\" \\ back",
    )
    var vals = List[DbValue]()
    for i in range(len(want)):
        vals.append(DbValue.text(want[i]))
    var rows = _store_and_read(t, String("t_text"), vals)
    for i in range(len(want)):
        assert_true(not rows[i].is_null(0), "text: empty string read as NULL")
        assert_equal(rows[i].get_text(0), want[i], "text round trip")


def check_int4[T: NeutralTarget](mut t: T) raises:
    var want = List[Int32]()
    want.append(Int32.MIN)
    want.append(Int32(-1))
    want.append(Int32(0))
    want.append(Int32.MAX)
    var vals = List[DbValue]()
    for i in range(len(want)):
        vals.append(DbValue.int4(want[i]))
    var rows = _store_and_read(t, String("t_int4"), vals)
    for i in range(len(want)):
        assert_equal(rows[i].get_int4(0), want[i], "int4 round trip")


def check_int8[T: NeutralTarget](mut t: T) raises:
    var want = List[Int64]()
    want.append(Int64.MIN)
    want.append(Int64(-1))
    want.append(Int64(0))
    want.append(Int64(4294967296))
    want.append(Int64.MAX)
    var vals = List[DbValue]()
    for i in range(len(want)):
        vals.append(DbValue.int8(want[i]))
    var rows = _store_and_read(t, String("t_int8"), vals)
    for i in range(len(want)):
        assert_equal(rows[i].get_int8(0), want[i], "int8 round trip")


def check_float8[T: NeutralTarget](mut t: T) raises:
    """FLOAT8: the cell's text parses to the stored number."""
    var want = List[Float64]()
    want.append(1.5)
    want.append(-0.25)
    want.append(0.0)
    want.append(123456.789)
    want.append(1.0e300)
    var vals = List[DbValue]()
    for i in range(len(want)):
        vals.append(DbValue.float8(want[i]))
    var rows = _store_and_read(t, String("t_float8"), vals)
    for i in range(len(want)):
        var text = rows[i].get_text(0)
        assert_equal(
            atof(text), want[i], String("float8 round trip (cell '") + text + "')"
        )


def check_float4[T: NeutralTarget](mut t: T) raises:
    var want = List[Float32]()
    want.append(Float32(1.5))
    want.append(Float32(-2.25))
    var vals = List[DbValue]()
    for i in range(len(want)):
        vals.append(DbValue.float4(want[i]))
    var rows = _store_and_read(t, String("t_float4"), vals)
    for i in range(len(want)):
        var text = rows[i].get_text(0)
        assert_equal(
            atof(text),
            Float64(want[i]),
            String("float4 round trip (cell '") + text + "')",
        )


def check_bool[T: NeutralTarget](mut t: T) raises:
    """A bool reads back as what the generated decoder (`_db_decode_bool`,
    protoc-gen-mojo-db) reads as that bool: true is one of "true" / "1" /
    "t", false is any other non-NULL text."""
    var vals = List[DbValue]()
    vals.append(DbValue.bool_val(True))
    vals.append(DbValue.bool_val(False))
    var rows = _store_and_read(t, String("t_bool"), vals)
    var t0 = rows[0].get_text(0)
    var f0 = rows[1].get_text(0)
    assert_true(_decodes_true(t0), String("bool true read back as '") + t0 + "'")
    assert_true(not rows[1].is_null(0), "bool false read back as NULL")
    assert_true(not _decodes_true(f0), String("bool false read back as '") + f0 + "'")


def _decodes_true(s: String) -> Bool:
    # `_db_decode_bool`'s rule, verbatim.
    return s == String("true") or s == String("1") or s == String("t")


def _byte_run(start: Int, n: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(n):
        out.append(UInt8((start + i) & 255))
    return out^


def _check_bytes_lengths[
    T: NeutralTarget
](mut t: T, lengths: List[Int]) raises:
    var want = List[List[UInt8]]()
    for i in range(len(lengths)):
        # Value i runs up from byte 0x7A * i (mod 256): the first from 0x00,
        # and the 256-byte value through every byte, so NUL and non-UTF-8
        # bytes are both in play.
        want.append(_byte_run(0x7A * i, lengths[i]))
    var vals = List[DbValue]()
    for i in range(len(want)):
        vals.append(DbValue.bytes(want[i]))
    var rows = _store_and_read(t, String("t_bytes"), vals)
    for i in range(len(want)):
        assert_true(
            not rows[i].is_null(0),
            String("bytes: a ") + String(lengths[i]) + "-byte value read as NULL",
        )
        assert_bytes(
            rows[i].get_bytes(0),
            want[i],
            String("bytes round trip, length ") + String(lengths[i]),
        )


def check_bytes[T: NeutralTarget](mut t: T) raises:
    """BYTES of lengths 0, 1, 15, 17 and 256 (every byte value, NUL and
    non-UTF-8 included) come back exactly."""
    var lengths = List[Int]()
    lengths.append(0)
    lengths.append(1)
    lengths.append(15)
    lengths.append(17)
    lengths.append(256)
    _check_bytes_lengths(t, lengths)


def check_bytes_len16[T: NeutralTarget](mut t: T) raises:
    """BYTES of exactly 16 bytes (the length of a UUID) come back exactly."""
    var lengths = List[Int]()
    lengths.append(16)
    _check_bytes_lengths(t, lengths)


def check_uuid[T: NeutralTarget](mut t: T) raises:
    var raw = Array[UInt8, 16](fill=0)
    for i in range(16):
        raw[i] = UInt8(0xF0 + i) if i < 8 else UInt8(i + 1)
    var vals = List[DbValue]()
    vals.append(DbValue.uuid(raw))
    var rows = _store_and_read(t, String("t_uuid"), vals)
    var got = rows[0].get_uuid(0)
    for i in range(16):
        assert_equal(got[i], raw[i], String("uuid byte ") + String(i))


def check_timestamptz[T: NeutralTarget](mut t: T) raises:
    var want = List[Int64]()
    want.append(Int64(0))
    want.append(Int64(-1))
    want.append(Int64(1800000000123456))
    var vals = List[DbValue]()
    for i in range(len(want)):
        vals.append(DbValue.timestamptz_micros(want[i]))
    var rows = _store_and_read(t, String("t_ts"), vals)
    for i in range(len(want)):
        assert_equal(
            rows[i].get_timestamptz_micros(0), want[i], "timestamptz round trip"
        )


def check_jsonb[T: NeutralTarget](mut t: T) raises:
    var want = String('{"k":"Zürich","n":[1,2],"q":"a\\"b"}')
    var vals = List[DbValue]()
    vals.append(DbValue.jsonb(want))
    var rows = _store_and_read(t, String("t_jsonb"), vals)
    assert_equal(rows[0].get_jsonb(0), want, "jsonb round trip")


def check_text_array[T: NeutralTarget](mut t: T) raises:
    """TEXT[] of simple labels (the documented closed set: no ',' or '}'),
    ASCII and non-ASCII, one element and none."""
    var want = List[List[String]]()
    want.append(strs("a", "b", "c"))
    want.append(strs("solo"))
    want.append(List[String]())
    want.append(strs("Zürich", "東京"))
    var vals = List[DbValue]()
    for i in range(len(want)):
        vals.append(DbValue.text_array(want[i]))
    var rows = _store_and_read(t, String("t_text_array"), vals)
    for i in range(len(want)):
        assert_strs(rows[i].get_text_array(0), want[i], "text[] round trip")


def check_nulls[T: NeutralTarget](mut t: T) raises:
    """A typed NULL of every logical type reads back as NULL."""
    var cols = strs(
        "t_text",
        "t_int4",
        "t_int8",
        "t_float8",
        "t_float4",
        "t_bool",
        "t_bytes",
        "t_uuid",
        "t_ts",
        "t_jsonb",
        "t_text_array",
    )
    var types = List[Int]()
    types.append(LOGICAL_TEXT)
    types.append(LOGICAL_INT4)
    types.append(LOGICAL_INT8)
    types.append(LOGICAL_FLOAT8)
    types.append(LOGICAL_FLOAT4)
    types.append(LOGICAL_BOOL)
    types.append(LOGICAL_BYTES)
    types.append(LOGICAL_UUID)
    types.append(LOGICAL_TIMESTAMPTZ)
    types.append(LOGICAL_JSONB)
    types.append(LOGICAL_TEXT_ARRAY)
    for c in range(len(cols)):
        var vals = List[DbValue]()
        vals.append(DbValue.null(types[c]))
        var rows = _store_and_read(t, cols[c], vals)
        assert_true(rows[0].is_null(0), cols[c] + String(": NULL did not read back as NULL"))
