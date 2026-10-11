# =============================================================================
# test_avro_cov_resolve.mojo -- schema resolution arms no other test reaches:
# promotion of a nullable field, skipping a nullable or non-string writer-only
# field, a writer value read into a reader union for every scalar kind, the
# enum and fixed refusals, and records that occupy no wire bytes.
# =============================================================================
#
# Every file here is built in the test (header, one block, null codec), so
# the expected values are the ones written into the payload.
#
# What each case proves, and the mutant planted in the product code to see
# it fail (each alone, then restored; the red message is quoted):
#   V1  int -> long and long -> double promotion of nullable fields, in both
#       null-first and null-second order, keep nulls where the writer wrote
#       the null branch. Mutant: the promotion's NULL_SECOND
#       `is_null = tag == 1` -> `== 0`: red, "TRUNCATED: long varint overrun".
#   V2  writer-only fields of type boolean, int, float, double, fixed(3),
#       null, ["null",long] and ["long","null"] (both branches) are skipped
#       so the reader's field after them decodes. Mutant: the float skip
#       advances 8 bytes: red, "TRUNCATED: long varint overrun".
#   V3  a writer scalar read into a reader ["null",T] for T = boolean, int,
#       float, double, string, bytes, fixed(2); and a writer ["long","null"]
#       read into a reader long (the null-second writer union).
#   V4  refusals by name: enum index out of range (2 and -1); an enum symbol
#       absent from the reader with no default; enum and fixed type names
#       that differ (a reader alias makes the fixed pair resolve); a
#       non-record writer or reader root; a plain read of a non-record
#       root. The refusals of spec-valid input (no-null or 3-branch unions,
#       a nested writer-only field, a "null" field in a plain read) are
#       komira#1083 and are not pinned. Mutant: the enum index check `widx >= len` ->
#       `widx > len`: red, an assert abort ("index 2 is out of bounds").
#   V5  records that occupy zero payload bytes (a writer-only "null" field,
#       reader fields filled from defaults) decode to `object_count` rows,
#       which grows each int/long/float/double accumulator past the block's
#       reserve (the reserve is clamped to the payload length, here 0).
#       Mutant: the long accumulator's growth copies `_len - 1` elements:
#       red, 0 vs -6. (Survivor: `_ensure_capacity`'s `>=` -> `>` in the
#       long accumulator writes one element past the capacity, which lands
#       in the buffer's allocation padding and is copied on the next growth,
#       so no assertion can see it at this assert level.)
# =============================================================================

from std.testing import assert_equal, assert_true

from std.memory import bitcast

from komira_avro import read_avro_bytes, read_avro_bytes_resolved, OCF_SYNC_LEN


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


def _enc_str(s: String, mut out: List[UInt8]):
    var b = s.as_bytes()
    _enc_long(Int64(len(b)), out)
    for i in range(len(b)):
        out.append(b[i])


def _enc_float(v: Float32, mut out: List[UInt8]):
    var bits = bitcast[DType.uint32, 1](SIMD[DType.float32, 1](v))
    for i in range(4):
        out.append(UInt8((bits >> UInt32(8 * i)) & 0xFF))


def _enc_double(v: Float64, mut out: List[UInt8]):
    var bits = bitcast[DType.uint64, 1](SIMD[DType.float64, 1](v))
    for i in range(8):
        out.append(UInt8((bits >> UInt64(8 * i)) & 0xFF))


def _file(schema: String, count: Int, payload: List[UInt8]) -> List[UInt8]:
    var out: List[UInt8] = [0x4F, 0x62, 0x6A, 0x01]
    _enc_long(2, out)
    _enc_str("avro.schema", out)
    _enc_str(schema, out)
    _enc_str("avro.codec", out)
    _enc_str("null", out)
    _enc_long(0, out)
    for i in range(OCF_SYNC_LEN):
        out.append(UInt8(0x50 + i))
    _enc_long(Int64(count), out)
    _enc_long(Int64(len(payload)), out)
    out.extend(Span(payload))
    for i in range(OCF_SYNC_LEN):
        out.append(UInt8(0x50 + i))
    return out^


def _rec(fields: String) -> String:
    return String('{"type":"record","name":"R","fields":[') + fields + "]}"


def _resolve_err(file: List[UInt8], reader: String) -> String:
    try:
        _ = read_avro_bytes_resolved(Span(file), reader)
    except e:
        return String(e)
    return String("(accepted)")


def test_nullable_promotion() raises:
    """V1. Rows: (a=5, b=null), (a=null, b=7 written as a long)."""
    var writer = _rec(
        '{"name":"a","type":["null","int"]},'
        '{"name":"b","type":["long","null"]}'
    )
    var reader = _rec(
        '{"name":"a","type":["null","long"]},'
        '{"name":"b","type":["double","null"]}'
    )
    var p = List[UInt8]()
    _enc_long(1, p)  # a: branch 1 (int)
    _enc_long(5, p)
    _enc_long(1, p)  # b: branch 1 (null)
    _enc_long(0, p)  # a: branch 0 (null)
    _enc_long(0, p)  # b: branch 0 (long)
    _enc_long(7, p)
    var rb = read_avro_bytes_resolved(Span(_file(writer, 2, p)), reader)
    assert_equal(rb.num_rows(), 2)
    var a = rb.column_as_primitive_int64(0)
    assert_equal(Int(a.get(0)), 5)
    assert_true(a.is_null(1), "a[1] null")
    var b = rb.column_as_primitive_float64(1)
    assert_true(b.is_null(0), "b[0] null")
    assert_true(b.get(1) == 7.0, "b[1]")
    assert_true(not b.is_null(1), "b[1] valid")


def test_skip_writer_only_fields() raises:
    """V2. One record; the reader keeps only `keep` (last on the wire)."""
    var writer = _rec(
        '{"name":"w_bool","type":"boolean"},'
        '{"name":"w_int","type":"int"},'
        '{"name":"w_float","type":"float"},'
        '{"name":"w_double","type":"double"},'
        '{"name":"w_fixed","type":{"type":"fixed","name":"F3","size":3}},'
        '{"name":"w_null","type":"null"},'
        '{"name":"w_n1","type":["null","long"]},'
        '{"name":"w_n2","type":["long","null"]},'
        '{"name":"w_n3","type":["null","long"]},'
        '{"name":"w_n4","type":["long","null"]},'
        '{"name":"keep","type":"string"}'
    )
    var reader = _rec('{"name":"keep","type":"string"}')
    var p = List[UInt8]()
    p.append(1)  # boolean
    _enc_long(-300, p)  # int (2 bytes)
    _enc_float(Float32(1.5), p)
    _enc_double(-2.25, p)
    p.append(0x61)
    p.append(0x62)
    p.append(0x63)  # fixed(3)
    # null: no bytes
    _enc_long(0, p)  # w_n1: null (branch 0)
    _enc_long(1, p)  # w_n2: null (branch 1)
    _enc_long(1, p)  # w_n3: long (branch 1)
    _enc_long(123456, p)
    _enc_long(0, p)  # w_n4: long (branch 0)
    _enc_long(-1, p)
    _enc_str("kept", p)
    var rb = read_avro_bytes_resolved(Span(_file(writer, 1, p)), reader)
    assert_equal(rb.num_rows(), 1)
    assert_equal(rb.num_columns(), 1)
    assert_equal(rb.column_as_string(0).get(0), "kept")


def test_select_branch_scalars() raises:
    """V3."""
    var writer = _rec(
        '{"name":"b","type":"boolean"},'
        '{"name":"i","type":"int"},'
        '{"name":"f","type":"float"},'
        '{"name":"d","type":"double"},'
        '{"name":"s","type":"string"},'
        '{"name":"y","type":"bytes"},'
        '{"name":"x","type":{"type":"fixed","name":"F2","size":2}},'
        '{"name":"n","type":["long","null"]}'
    )
    var reader = _rec(
        '{"name":"b","type":["null","boolean"]},'
        '{"name":"i","type":["null","int"]},'
        '{"name":"f","type":["null","float"]},'
        '{"name":"d","type":["null","double"]},'
        '{"name":"s","type":["null","string"]},'
        '{"name":"y","type":["null","bytes"]},'
        '{"name":"x","type":["null",{"type":"fixed","name":"F2","size":2}]},'
        '{"name":"n","type":"long"}'
    )
    var p = List[UInt8]()
    # record 0
    p.append(1)
    _enc_long(-7, p)
    _enc_float(Float32(0.5), p)
    _enc_double(3.25, p)
    _enc_str("hi", p)
    _enc_long(2, p)
    p.append(0xFE)
    p.append(0x01)
    p.append(0x10)
    p.append(0x20)
    _enc_long(0, p)  # n: branch 0 = long
    _enc_long(42, p)
    # record 1
    p.append(0)
    _enc_long(9, p)
    _enc_float(Float32(-4.0), p)
    _enc_double(-0.125, p)
    _enc_str("", p)
    _enc_long(0, p)
    p.append(0x30)
    p.append(0x40)
    _enc_long(1, p)  # n: branch 1 = null
    var rb = read_avro_bytes_resolved(Span(_file(writer, 2, p)), reader)
    assert_equal(rb.num_rows(), 2)
    var b = rb.column_as_boolean(0)
    assert_true(b.get(0), "b0")
    assert_true(not b.get(1), "b1")
    var i = rb.column_as_primitive_int32(1)
    assert_equal(Int(i.get(0)), -7)
    assert_equal(Int(i.get(1)), 9)
    var f = rb.column_as_primitive_float32(2)
    assert_true(f.get(0) == Float32(0.5), "f0")
    assert_true(f.get(1) == Float32(-4.0), "f1")
    var d = rb.column_as_primitive_float64(3)
    assert_true(d.get(0) == 3.25, "d0")
    assert_true(d.get(1) == -0.125, "d1")
    var s = rb.column_as_string(4)
    assert_equal(s.get(0), "hi")
    assert_equal(s.get(1), "")
    ref ycol = rb.column_at(5)
    var y = ycol.as_binary()
    assert_equal(len(y.get(0)), 2)
    assert_equal(Int(y.get(0)[0]), 0xFE)
    assert_equal(len(y.get(1)), 0)
    ref xcol = rb.column_at(6)
    var x = xcol.as_binary()
    assert_equal(Int(x.get(0)[1]), 0x20)
    assert_equal(Int(x.get(1)[0]), 0x30)
    var n = rb.column_as_primitive_int64(7)
    assert_equal(Int(n.get(0)), 42)
    assert_true(n.is_null(1), "n1 null")


def test_resolution_refusals() raises:
    """V4."""
    var ew = _rec(
        '{"name":"e","type":{"type":"enum","name":"E","symbols":["A","B"]}}'
    )
    var p2: List[UInt8] = [0x04]  # index 2
    assert_equal(
        _resolve_err(_file(ew, 1, p2), ew),
        "AvroDecodeError.MALFORMED: enum index 2 out of range for writer"
        " symbol set",
    )
    var pneg: List[UInt8] = [0x01]  # index -1
    assert_equal(
        _resolve_err(_file(ew, 1, pneg), ew),
        "AvroDecodeError.MALFORMED: enum index -1 out of range for writer"
        " symbol set",
    )
    var er = _rec(
        '{"name":"e","type":{"type":"enum","name":"E","symbols":["A"]}}'
    )
    var p1: List[UInt8] = [0x02]  # index 1 = "B"
    assert_equal(
        _resolve_err(_file(ew, 1, p1), er),
        "AvroResolutionError.ENUM_SYMBOL_UNKNOWN: writer symbol 'B' absent"
        " from reader symbol set and no default",
    )
    var er_other = _rec(
        '{"name":"e","type":{"type":"enum","name":"Other","symbols":["A","B"]}}'
    )
    assert_equal(
        _resolve_err(_file(ew, 1, p1), er_other),
        "AvroResolutionError.ENUM_SYMBOL_UNKNOWN: enum type name mismatch"
        " (writer 'E' vs reader 'Other')",
    )
    var fw = _rec('{"name":"x","type":{"type":"fixed","name":"F","size":2}}')
    var fr = _rec('{"name":"x","type":{"type":"fixed","name":"G","size":2}}')
    var pf: List[UInt8] = [1, 2]
    assert_equal(
        _resolve_err(_file(fw, 1, pf), fr),
        "AvroResolutionError.INCOMPATIBLE_TYPE_PROMOTION: fixed type name"
        " mismatch for field 'x'",
    )
    # An alias on the reader's fixed makes the same pair resolve.
    var fr_alias = _rec(
        '{"name":"x","type":{"type":"fixed","name":"G","size":2,'
        '"aliases":["F"]}}'
    )
    assert_equal(_resolve_err(_file(fw, 1, pf), fr_alias), "(accepted)")
    var lw = _rec('{"name":"v","type":"long"}')
    var pl: List[UInt8] = [0x02]
    assert_equal(
        _resolve_err(_file('"long"', 1, pl), lw),
        "AvroResolutionError.NOT_A_RECORD: writer schema root is not a record",
    )
    assert_equal(
        _resolve_err(_file(lw, 1, pl), '"long"'),
        "AvroResolutionError.NOT_A_RECORD: reader schema root is not a record",
    )
    # Not pinned here (komira#1083: the spec allows these inputs): a writer
    # union with no null branch, a reader union with three branches, a
    # nested writer-only field, a plain read of a no-null union or of a
    # field of type "null".
    # A plain (identity) read of a non-record root.
    var got = String("(accepted)")
    try:
        _ = read_avro_bytes(Span(_file('"long"', 1, pl)))
    except e:
        got = String(e)
    assert_equal(
        got,
        "AvroDecodeError.NOT_A_RECORD: the reader requires a record-rooted"
        " Avro schema",
    )


def test_zero_byte_records() raises:
    """V5."""
    var writer = _rec('{"name":"n","type":"null"}')
    var reader = _rec(
        '{"name":"a","type":"int","default":5},'
        '{"name":"b","type":"long","default":-6},'
        '{"name":"c","type":"float","default":7},'
        '{"name":"d","type":"double","default":8.5}'
    )
    var empty = List[UInt8]()
    var rb = read_avro_bytes_resolved(Span(_file(writer, 9, empty)), reader)
    assert_equal(rb.num_rows(), 9)
    var a = rb.column_as_primitive_int32(0)
    var b = rb.column_as_primitive_int64(1)
    var c = rb.column_as_primitive_float32(2)
    var d = rb.column_as_primitive_float64(3)
    for r in range(9):
        assert_equal(Int(a.get(r)), 5)
        assert_equal(Int(b.get(r)), -6)
        assert_true(c.get(r) == Float32(7.0), "c")
        assert_true(d.get(r) == 8.5, "d")


def main() raises:
    test_nullable_promotion()
    test_skip_writer_only_fields()
    test_select_branch_scalars()
    test_resolution_refusals()
    test_zero_byte_records()
    print("test_avro_cov_resolve: ALL PASS")
