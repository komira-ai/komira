# =============================================================================
# test_avro_resolve_field_skip.mojo — field-skip resolution
# (the field-skip rule).
# =============================================================================
#
# A writer field absent from the reader schema must be decoded-and-discarded:
# the cursor still advances past its bytes so subsequent fields stay aligned.
# Fixtures hand-emitted.
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
# Writer has 3 fields (id:long, name:string, age:int). Reader keeps only
# (id, age). The writer-only "name" field (between id and age on the wire) must
# be decoded-and-skipped so "age" decodes from the right offset.
# -----------------------------------------------------------------------------
def test_resolve_field_skip() raises:
    var writer = String(
        '{"type":"record","name":"R","fields":['
        '{"name":"id","type":"long"},'
        '{"name":"name","type":"string"},'
        '{"name":"age","type":"int"}]}'
    )
    var reader = String(
        '{"type":"record","name":"R","fields":['
        '{"name":"id","type":"long"},'
        '{"name":"age","type":"int"}]}'
    )
    var buf = List[UInt8]()
    _make_header(writer, buf)
    var p = List[UInt8]()
    # Row 0: id=10, name="alice", age=30
    _enc_long(Int64(10), p)
    _enc_str(String("alice"), p)
    _enc_long(Int64(30), p)
    # Row 1: id=20, name="bob", age=40
    _enc_long(Int64(20), p)
    _enc_str(String("bob"), p)
    _enc_long(Int64(40), p)
    _append_block(buf, Int64(2), p)

    var rb = read_avro_bytes_resolved(Span(buf), reader)
    assert_equal(rb.num_rows(), 2, "field-skip 2 rows")
    assert_equal(rb.num_columns(), 2, "field-skip 2 cols (name dropped)")
    assert_equal(rb.schema.field_at_unchecked(0).name, String("id"), "col0 id")
    assert_equal(rb.schema.field_at_unchecked(1).name, String("age"), "col1 age")
    var idc = rb.column_at(0).as_primitive[DType.int64]()
    var agec = rb.column_at(1).as_primitive[DType.int32]()
    assert_equal(Int(idc.get(0)), 10, "id row0")
    assert_equal(Int(agec.get(0)), 30, "age row0 (name skipped)")
    assert_equal(Int(idc.get(1)), 20, "id row1")
    assert_equal(Int(agec.get(1)), 40, "age row1 (name skipped)")


def main() raises:
    test_resolve_field_skip()
    print("test_avro_resolve_field_skip: ALL PASS")
