# =============================================================================
# test_avro_resolve_aliases_defaults.mojo — resolution: aliases /
# defaults / record-field-reorder (Avro schema-resolution rules).
# =============================================================================
#
# The OCF is written with the WRITER schema; the caller reads it with a
# different READER schema. `read_avro_bytes_resolved` runs the
# resolution-rewriter (writer, reader) and produces the batch in READER order.
# Fixtures are hand-emitted as the decoder-inverse (no external Avro library needed).
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_avro import read_avro_bytes_resolved, OCF_SYNC_LEN


def _enc_long(n: Int64, mut out: List[UInt8]):
    var zz = UInt64((n << 1) ^ (n >> 63))
    while True:
        var b = UInt8(zz & 0x7F)
        zz >>= 7
        if zz != 0:
            out.append(b | 0x80)
        else:
            out.append(b)
            break


def _str_bytes(s: String) -> List[UInt8]:
    var b = s.as_bytes()
    var out = List[UInt8]()
    for i in range(len(b)):
        out.append(b[i])
    return out^


def _enc_str(s: String, mut out: List[UInt8]):
    var b = s.as_bytes()
    _enc_long(Int64(len(b)), out)
    for i in range(len(b)):
        out.append(b[i])


def _enc_bytes(b: List[UInt8], mut out: List[UInt8]):
    _enc_long(Int64(len(b)), out)
    for i in range(len(b)):
        out.append(b[i])


def _sync() -> List[UInt8]:
    var s = List[UInt8]()
    for i in range(OCF_SYNC_LEN):
        s.append(UInt8(0xA0 + i))
    return s^


def _make_header(schema: String, mut out: List[UInt8]):
    out.append(UInt8(ord("O")))
    out.append(UInt8(ord("b")))
    out.append(UInt8(ord("j")))
    out.append(0x01)
    _enc_long(Int64(2), out)
    _enc_str(String("avro.schema"), out)
    _enc_bytes(_str_bytes(schema), out)
    _enc_str(String("avro.codec"), out)
    _enc_bytes(_str_bytes(String("null")), out)
    _enc_long(Int64(0), out)
    var s = _sync()
    for i in range(len(s)):
        out.append(s[i])


def _append_block(mut out: List[UInt8], object_count: Int64, payload: List[UInt8]):
    _enc_long(object_count, out)
    _enc_long(Int64(len(payload)), out)
    for i in range(len(payload)):
        out.append(payload[i])
    var s = _sync()
    for i in range(len(s)):
        out.append(s[i])


# -----------------------------------------------------------------------------
# test_resolve_aliases — reader field "user_id" matches writer field "id" via
# alias. Writer record has one field "id":long; reader names it "user_id" with
# `aliases:["id"]`.
# -----------------------------------------------------------------------------
def test_resolve_aliases() raises:
    var writer = String(
        '{"type":"record","name":"R","fields":['
        '{"name":"id","type":"long"}]}'
    )
    var reader = String(
        '{"type":"record","name":"R","fields":['
        '{"name":"user_id","type":"long","aliases":["id"]}]}'
    )
    var buf = List[UInt8]()
    _make_header(writer, buf)
    var p = List[UInt8]()
    _enc_long(Int64(42), p)   # row 0: id = 42
    _enc_long(Int64(-7), p)   # row 1: id = -7
    _append_block(buf, Int64(2), p)

    var rb = read_avro_bytes_resolved(Span(buf), reader)
    assert_equal(rb.num_rows(), 2, "aliases: 2 rows")
    assert_equal(rb.num_columns(), 1, "aliases: 1 col")
    assert_equal(rb.schema.field_at_unchecked(0).name, String("user_id"), "renamed col")
    var c = rb.column_at(0).as_primitive[DType.int64]()
    assert_equal(Int(c.get(0)), 42, "aliases row0")
    assert_equal(Int(c.get(1)), -7, "aliases row1")


# -----------------------------------------------------------------------------
# test_resolve_defaults — reader field "score":double is ABSENT in the writer
# and declares default 7.5; reader field "id":long is present. Every record
# gets the default for score.
# -----------------------------------------------------------------------------
def test_resolve_defaults() raises:
    var writer = String(
        '{"type":"record","name":"R","fields":['
        '{"name":"id","type":"long"}]}'
    )
    var reader = String(
        '{"type":"record","name":"R","fields":['
        '{"name":"id","type":"long"},'
        '{"name":"score","type":"double","default":7.5}]}'
    )
    var buf = List[UInt8]()
    _make_header(writer, buf)
    var p = List[UInt8]()
    _enc_long(Int64(1), p)
    _enc_long(Int64(2), p)
    _append_block(buf, Int64(2), p)

    var rb = read_avro_bytes_resolved(Span(buf), reader)
    assert_equal(rb.num_rows(), 2, "defaults: 2 rows")
    assert_equal(rb.num_columns(), 2, "defaults: 2 cols")
    var idc = rb.column_at(0).as_primitive[DType.int64]()
    assert_equal(Int(idc.get(0)), 1, "defaults id row0")
    assert_equal(Int(idc.get(1)), 2, "defaults id row1")
    var sc = rb.column_at(1).as_primitive[DType.float64]()
    assert_true(sc.get(0) > 7.49 and sc.get(0) < 7.51, "defaults score row0 == 7.5")
    assert_true(sc.get(1) > 7.49 and sc.get(1) < 7.51, "defaults score row1 == 7.5")


# -----------------------------------------------------------------------------
# test_resolve_record_field_reorder — writer order (a, b), reader order (b, a).
# The output batch must be in READER order: column 0 == b, column 1 == a.
# -----------------------------------------------------------------------------
def test_resolve_record_field_reorder() raises:
    var writer = String(
        '{"type":"record","name":"R","fields":['
        '{"name":"a","type":"int"},'
        '{"name":"b","type":"long"}]}'
    )
    var reader = String(
        '{"type":"record","name":"R","fields":['
        '{"name":"b","type":"long"},'
        '{"name":"a","type":"int"}]}'
    )
    var buf = List[UInt8]()
    _make_header(writer, buf)
    var p = List[UInt8]()
    # Wire is WRITER order: a then b.
    _enc_long(Int64(11), p)  # a = 11 (row 0)
    _enc_long(Int64(99), p)  # b = 99
    _enc_long(Int64(22), p)  # a = 22 (row 1)
    _enc_long(Int64(88), p)  # b = 88
    _append_block(buf, Int64(2), p)

    var rb = read_avro_bytes_resolved(Span(buf), reader)
    assert_equal(rb.num_columns(), 2, "reorder: 2 cols")
    assert_equal(rb.schema.field_at_unchecked(0).name, String("b"), "reorder col0 == b")
    assert_equal(rb.schema.field_at_unchecked(1).name, String("a"), "reorder col1 == a")
    var bcol = rb.column_at(0).as_primitive[DType.int64]()
    var acol = rb.column_at(1).as_primitive[DType.int32]()
    assert_equal(Int(bcol.get(0)), 99, "reorder b row0")
    assert_equal(Int(acol.get(0)), 11, "reorder a row0")
    assert_equal(Int(bcol.get(1)), 88, "reorder b row1")
    assert_equal(Int(acol.get(1)), 22, "reorder a row1")


def main() raises:
    test_resolve_aliases()
    test_resolve_defaults()
    test_resolve_record_field_reorder()
    print("test_avro_resolve_aliases_defaults: ALL PASS")
