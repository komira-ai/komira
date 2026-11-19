# =============================================================================
# test_avro_cov_union_wire.mojo -- general unions over every scalar wire kind,
# reader-union routing by promotion and by named type, and the refusals of a
# writer-only field's skip walk, each on an OCF file built in the test (header,
# one block, null codec), so every expected value is one written below.
#
# What each case proves:
#   W1  a plain read of a general union with a boolean, float, double, bytes
#       and named fixed branch, and of one with an int, a decimal over bytes
#       and a decimal over fixed branch, lands each value in the child of its
#       branch with the value written; a named branch's child takes the
#       type's full name, an unnamed one its Avro type name.
#   W2  a writer union ["int", fixed F2] read into a reader union ["long",
#       "string", fixed F2]: the int finds no reader branch of its own type
#       and lands in the first one it promotes to (long); the fixed lands in
#       the reader's fixed of the same name and size.
#   W3  a union branch that is an enum matches the reader's enum of the same
#       name, and a value of it is refused by name when read (a union child
#       holds no enum column).
#   W4  a general union of 128 branches is refused by name (an Arrow union
#       holds 127), and one of 127 branches is read.
#   W5  a writer-only record of boolean, float, double and fixed(3) fields is
#       skipped value by value, so the reader's field after it decodes.
#   W6  a writer-only general union whose tag is past its last branch (3 of
#       3) or negative (-1) is refused as malformed, naming the tag.
#   W7  a writer-only array block with a negative count and a negative byte
#       size is refused as malformed, naming the size.
# =============================================================================

from std.testing import assert_equal, assert_true

from arrow.arrow_types import ArrowType

from avro import read_avro_bytes, read_avro_bytes_resolved, OCF_SYNC_LEN


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


def _ocf(schema: String, count: Int, payload: List[UInt8]) -> List[UInt8]:
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


def _record(fields: String) -> String:
    return String('{"type":"record","name":"R","fields":[') + fields + "]}"


def _plain_error(ocf: List[UInt8]) -> String:
    try:
        var rb = read_avro_bytes(Span(ocf))
        _ = rb.num_rows()
    except e:
        return String(e)
    return String("(accepted)")


def _resolve_error(ocf: List[UInt8], reader: String) -> String:
    try:
        var rb = read_avro_bytes_resolved(Span(ocf), reader)
        _ = rb.num_rows()
    except e:
        return String(e)
    return String("(accepted)")


def test_plain_read_general_union_of_every_scalar_kind() raises:
    """W1."""
    var schema = _record(
        '{"name":"a","type":["boolean","float","double","bytes",'
        '{"type":"fixed","name":"ns.F2","size":2}]},'
        '{"name":"b","type":["int",'
        '{"type":"bytes","logicalType":"decimal","precision":9,"scale":2},'
        '{"type":"fixed","name":"D4","size":4,"logicalType":"decimal",'
        '"precision":9,"scale":2}]}'
    )
    var p: List[UInt8] = [
        # row 0: a = true (boolean), b = 5 (int)
        0x00, 0x01,
        0x00, 0x0A,
        # row 1: a = 1.5f (float), b = 256 (decimal over bytes, 2 bytes)
        0x02, 0x00, 0x00, 0xC0, 0x3F,
        0x02, 0x04, 0x01, 0x00,
        # row 2: a = -2.25 (double), b = -2 (decimal over fixed(4))
        0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0xC0,
        0x04, 0xFF, 0xFF, 0xFF, 0xFE,
        # row 3: a = [0xAB] (bytes), b = -1 (int)
        0x06, 0x02, 0xAB,
        0x00, 0x01,
        # row 4: a = "xy" (fixed F2), b = 0 (decimal over empty bytes)
        0x08, 0x78, 0x79,
        0x02, 0x00,
    ]
    var rb = read_avro_bytes(Span(_ocf(schema, 5, p)))
    assert_equal(rb.num_rows(), 5)
    ref fa = rb.schema.field_at_unchecked(0)
    assert_true(fa.arrow_type == ArrowType.UNION_DENSE, "a is a dense union")
    assert_equal(fa.child_name(0), "boolean")
    assert_equal(fa.child_name(3), "bytes")
    assert_equal(fa.child_name(4), "ns.F2")
    var ua = rb.column_at(0).as_union()
    assert_equal(ua.num_children(), 5)
    for r in range(5):
        assert_equal(Int(ua.type_id_at(r)), r)
        assert_equal(Int(ua.offset_at(r)), 0)
    assert_true(ua.child_at(0).as_boolean().get(0), "a[0] is true")
    assert_equal(ua.child_at(1).as_primitive[DType.float32]().get(0), 1.5)
    assert_equal(ua.child_at(2).as_primitive[DType.float64]().get(0), -2.25)
    var by = ua.child_at(3).as_binary()
    assert_equal(len(by.get(0)), 1)
    assert_equal(Int(by.get(0)[0]), 0xAB)
    var fx = ua.child_at(4).as_binary()
    assert_equal(len(fx.get(0)), 2)
    assert_equal(Int(fx.get(0)[0]), 0x78)
    assert_equal(Int(fx.get(0)[1]), 0x79)

    ref fb = rb.schema.field_at_unchecked(1)
    assert_equal(fb.child_name(2), "D4")
    var ub = rb.column_at(1).as_union()
    assert_equal(Int(ub.type_id_at(0)), 0)
    assert_equal(Int(ub.type_id_at(1)), 1)
    assert_equal(Int(ub.type_id_at(2)), 2)
    assert_equal(Int(ub.type_id_at(3)), 0)
    assert_equal(Int(ub.type_id_at(4)), 1)
    assert_equal(Int(ub.offset_at(3)), 1)
    assert_equal(Int(ub.offset_at(4)), 1)
    var ints = ub.child_at(0).as_primitive[DType.int32]()
    assert_equal(Int(ints.get(0)), 5)
    assert_equal(Int(ints.get(1)), -1)
    var dbytes = ub.child_at(1).as_decimal128()
    assert_equal(Int(dbytes.get_low(0)), 256)
    assert_equal(Int(dbytes.get_high(0)), 0)
    assert_equal(Int(dbytes.get_low(1)), 0)
    assert_equal(Int(dbytes.get_high(1)), 0)
    var dfixed = ub.child_at(2).as_decimal128()
    assert_equal(Int(dfixed.get_low(0)), -2)
    assert_equal(Int(dfixed.get_high(0)), -1)


def test_reader_union_routes_by_promotion_and_named_fixed() raises:
    """W2."""
    var fixed = String('{"type":"fixed","name":"F2","size":2}')
    var writer = _record('{"name":"v","type":["int",' + fixed + "]}")
    var reader = _record('{"name":"v","type":["long","string",' + fixed + "]}")
    var p = List[UInt8]()
    _enc_long(0, p)  # writer branch 0: int 7
    _enc_long(7, p)
    _enc_long(1, p)  # writer branch 1: fixed "ok"
    p.append(0x6F)
    p.append(0x6B)
    var rb = read_avro_bytes_resolved(Span(_ocf(writer, 2, p)), reader)
    assert_equal(rb.num_rows(), 2)
    var ua = rb.column_at(0).as_union()
    assert_equal(ua.num_children(), 3)
    assert_equal(Int(ua.type_id_at(0)), 0)
    assert_equal(Int(ua.type_id_at(1)), 2)
    assert_equal(Int(ua.child_at(0).as_primitive[DType.int64]().get(0)), 7)
    assert_equal(ua.child_at(1).length(), 0)
    var fx = ua.child_at(2).as_binary()
    assert_equal(Int(fx.get(0)[0]), 0x6F)
    assert_equal(Int(fx.get(0)[1]), 0x6B)


def test_enum_union_branch_value_refused_on_read() raises:
    """W3."""
    var schema = _record(
        '{"name":"v","type":["int",'
        '{"type":"enum","name":"E","symbols":["A","B"]}]}'
    )
    var p = List[UInt8]()
    _enc_long(1, p)  # branch 1: enum
    _enc_long(1, p)  # symbol B
    assert_equal(
        _resolve_error(_ocf(schema, 1, p), schema),
        "AvroDecodeError.UNSUPPORTED_FIELD_KIND: a enum value in union field"
        " 'v' is not decoded into a column",
    )


def _fixed_branches(n: Int) -> String:
    var s = String('{"name":"u","type":[')
    for i in range(n):
        if i > 0:
            s += ","
        s += '{"type":"fixed","name":"F' + String(i) + '","size":1}'
    return s + "]}"


def test_union_branch_count_limit() raises:
    """W4."""
    var p: List[UInt8] = [0x00, 0x2A]  # branch 0, its one byte
    assert_equal(
        _plain_error(_ocf(_record(_fixed_branches(128)), 1, p)),
        "AvroDecodeError.UNSUPPORTED_UNION: a union of 128 branches exceeds"
        " the 127 an Arrow union can hold",
    )
    var rb = read_avro_bytes(Span(_ocf(_record(_fixed_branches(127)), 1, p)))
    var ua = rb.column_at(0).as_union()
    assert_equal(ua.num_children(), 127)
    assert_equal(Int(ua.child_at(0).as_binary().get(0)[0]), 0x2A)


def test_skip_writer_only_record_of_fixed_width_fields() raises:
    """W5."""
    var writer = _record(
        '{"name":"r","type":{"type":"record","name":"In","fields":['
        '{"name":"b","type":"boolean"},{"name":"f","type":"float"},'
        '{"name":"d","type":"double"},'
        '{"name":"x","type":{"type":"fixed","name":"X3","size":3}}]}},'
        '{"name":"v","type":"long"}'
    )
    var reader = _record('{"name":"v","type":"long"}')
    var p = List[UInt8]()
    for row in range(2):
        p.append(0x01)  # b
        for _i in range(4):  # f
            p.append(0xEE)
        for _i in range(8):  # d
            p.append(0xDD)
        for _i in range(3):  # x
            p.append(0xCC)
        _enc_long(Int64(60 + row), p)  # v
    var rb = read_avro_bytes_resolved(Span(_ocf(writer, 2, p)), reader)
    var v = rb.column_at(0).as_primitive[DType.int64]()
    assert_equal(Int(v.get(0)), 60)
    assert_equal(Int(v.get(1)), 61)


def test_skip_writer_only_union_tag_out_of_range() raises:
    """W6."""
    var writer = _record(
        '{"name":"u","type":["int","string","null"]},{"name":"v","type":"long"}'
    )
    var reader = _record('{"name":"v","type":"long"}')
    var past = List[UInt8]()
    _enc_long(3, past)
    _enc_long(1, past)
    assert_equal(
        _resolve_error(_ocf(writer, 1, past), reader),
        "AvroDecodeError.MALFORMED: union branch 3 out of range for a 3-branch"
        " union",
    )
    var negative = List[UInt8]()
    _enc_long(-1, negative)
    _enc_long(1, negative)
    assert_equal(
        _resolve_error(_ocf(writer, 1, negative), reader),
        "AvroDecodeError.MALFORMED: union branch -1 out of range for a"
        " 3-branch union",
    )


def test_skip_writer_only_array_negative_block_size() raises:
    """W7."""
    var writer = _record(
        '{"name":"arr","type":{"type":"array","items":"int"}},'
        '{"name":"v","type":"long"}'
    )
    var reader = _record('{"name":"v","type":"long"}')
    var p = List[UInt8]()
    _enc_long(-1, p)  # a block of one item...
    _enc_long(-1, p)  # ...of -1 bytes
    _enc_long(1, p)
    assert_equal(
        _resolve_error(_ocf(writer, 1, p), reader),
        "AvroDecodeError.MALFORMED: negative block size -1",
    )


def main() raises:
    test_plain_read_general_union_of_every_scalar_kind()
    test_reader_union_routes_by_promotion_and_named_fixed()
    test_enum_union_branch_value_refused_on_read()
    test_union_branch_count_limit()
    test_skip_writer_only_record_of_fixed_width_fields()
    test_skip_writer_only_union_tag_out_of_range()
    test_skip_writer_only_array_negative_block_size()
    print("test_avro_cov_union_wire: ALL PASS")
