# =============================================================================
# test_avro_spec_valid_unions_skip_null.mojo — spec-valid input the reader
# used to refuse: unions with no null branch or more than two branches, a
# writer-only field of a nested kind, and a field of type "null".
# =============================================================================
#
# Every fixture is one record field (or a few) in a one-block container with
# the null codec, emitted by hand so the wire bytes are the spec's, not the
# writer's. The expectations follow the Avro 1.11 resolution rules:
#   - writer union, reader non-union: the writer's branch is selected and
#     resolved against the reader; a branch that does not resolve is an error
#     when a value of that branch is read;
#   - reader union: the writer value lands in the reader branch of the same
#     type, else the first branch it promotes to; the column is an Arrow dense
#     union with one child per reader branch (type id = branch index);
#   - a writer field the reader does not have is skipped, whatever its type;
#   - a "null" field is an Arrow NULL column (no buffers, every row null).
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
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


def _ocf(schema: String, object_count: Int64, payload: List[UInt8]) -> List[UInt8]:
    var out = List[UInt8]()
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
    _enc_long(object_count, out)
    _enc_long(Int64(len(payload)), out)
    for i in range(len(payload)):
        out.append(payload[i])
    for i in range(len(s)):
        out.append(s[i])
    return out^


def _record(fields: String) -> String:
    return String('{"type":"record","name":"R","fields":[') + fields + "]}"


def _resolve_error(ocf: List[UInt8], reader: String) -> String:
    try:
        var rb = read_avro_bytes_resolved(Span(ocf), reader)
        _ = rb.num_rows()
    except e:
        return String(e)
    return String("")


# -----------------------------------------------------------------------------
# Issue case 1: a writer union with no null branch, read into a scalar reader
# field. int 1 is selected from branch 0 and promoted to long 1. Before the fix
# the table build raised UNION_NO_MATCHING_BRANCH for every such union.
# -----------------------------------------------------------------------------
def test_writer_union_without_null_into_long() raises:
    var writer = _record('{"name":"v","type":["int","string"]}')
    var reader = _record('{"name":"v","type":"long"}')
    var p = List[UInt8]()
    _enc_long(0, p)  # branch 0: int
    _enc_long(1, p)
    _enc_long(0, p)
    _enc_long(-3, p)
    var rb = read_avro_bytes_resolved(Span(_ocf(writer, 2, p)), reader)
    assert_equal(rb.num_rows(), 2)
    assert_true(rb.schema.field_at_unchecked(0).arrow_type == ArrowType.INT64)
    var v = rb.column_at(0).as_primitive[DType.int64]()
    assert_equal(Int(v.get(0)), 1)
    assert_equal(Int(v.get(1)), -3)


# The string branch does not resolve against long: the spec signals an error
# when such a value is read, and only then (the int rows above still read).
def test_writer_union_branch_without_match_raises_on_read() raises:
    var writer = _record('{"name":"v","type":["int","string"]}')
    var reader = _record('{"name":"v","type":"long"}')
    var p = List[UInt8]()
    _enc_long(1, p)  # branch 1: string
    _enc_str("hi", p)
    var err = _resolve_error(_ocf(writer, 1, p), reader)
    assert_true(
        err.find("AvroResolutionError.UNION_NO_MATCHING_BRANCH") >= 0, err
    )
    assert_true(err.find("string") >= 0, err)


# A three-branch writer union with null into a double reader: the int and long
# branches both promote to double; the null branch is a null row, as it is for
# a two-branch nullable writer union.
def test_writer_three_branch_union_into_double() raises:
    var writer = _record('{"name":"v","type":["null","int","long"]}')
    var reader = _record('{"name":"v","type":"double"}')
    var p = List[UInt8]()
    _enc_long(1, p)  # int 5
    _enc_long(5, p)
    _enc_long(0, p)  # null
    _enc_long(2, p)  # long 7
    _enc_long(7, p)
    var rb = read_avro_bytes_resolved(Span(_ocf(writer, 3, p)), reader)
    ref col = rb.column_at(0)
    assert_equal(col.null_count(), 1)
    assert_true(col.is_null_at(1))
    var v = col.as_primitive[DType.float64]()
    assert_equal(Float64(v.get(0)), 5.0)
    assert_equal(Float64(v.get(2)), 7.0)


# A union tag outside the writer's branch list is malformed input.
def test_writer_union_tag_out_of_range_raises() raises:
    var writer = _record('{"name":"v","type":["int","string"]}')
    var reader = _record('{"name":"v","type":"long"}')
    var p = List[UInt8]()
    _enc_long(2, p)
    var err = _resolve_error(_ocf(writer, 1, p), reader)
    assert_true(err.find("AvroDecodeError.MALFORMED") >= 0, err)


# -----------------------------------------------------------------------------
# Issue case 2, resolution: writer long, reader ["null","int","long"]. long
# does not promote to int, so the value lands in branch 2. The column is a
# dense union with one child per reader branch.
# -----------------------------------------------------------------------------
def test_reader_three_branch_union_from_long() raises:
    var writer = _record('{"name":"v","type":"long"}')
    var reader = _record('{"name":"v","type":["null","int","long"]}')
    var p = List[UInt8]()
    _enc_long(7, p)
    _enc_long(-9, p)
    var rb = read_avro_bytes_resolved(Span(_ocf(writer, 2, p)), reader)
    assert_equal(rb.num_rows(), 2)
    assert_true(
        rb.schema.field_at_unchecked(0).arrow_type == ArrowType.UNION_DENSE
    )
    var ua = rb.column_at(0).as_union()
    assert_equal(ua.num_children(), 3)
    assert_equal(Int(ua.type_id_at(0)), 2)
    assert_equal(Int(ua.type_id_at(1)), 2)
    assert_equal(Int(ua.offset_at(0)), 0)
    assert_equal(Int(ua.offset_at(1)), 1)
    assert_true(ua.child_at(0).arrow_type == ArrowType.NULL)
    assert_equal(ua.child_at(1).length(), 0)
    var longs = ua.child_at(2).as_primitive[DType.int64]()
    assert_equal(Int(longs.get(0)), 7)
    assert_equal(Int(longs.get(1)), -9)


# Writer int, reader ["long","int"]: the branch of the writer's own type wins
# over an earlier branch it would only promote to.
def test_reader_union_prefers_same_type_branch() raises:
    var writer = _record('{"name":"v","type":"int"}')
    var reader = _record('{"name":"v","type":["long","int"]}')
    var p = List[UInt8]()
    _enc_long(4, p)
    var rb = read_avro_bytes_resolved(Span(_ocf(writer, 1, p)), reader)
    var ua = rb.column_at(0).as_union()
    assert_equal(Int(ua.type_id_at(0)), 1)
    assert_equal(Int(ua.child_at(1).as_primitive[DType.int32]().get(0)), 4)


# Writer ["string","int"], reader ["int","string","null"]: each writer branch
# lands in the reader branch of its type.
def test_union_to_union_routes_each_branch() raises:
    var writer = _record('{"name":"v","type":["string","int"]}')
    var reader = _record('{"name":"v","type":["int","string","null"]}')
    var p = List[UInt8]()
    _enc_long(0, p)
    _enc_str("ab", p)
    _enc_long(1, p)
    _enc_long(6, p)
    var rb = read_avro_bytes_resolved(Span(_ocf(writer, 2, p)), reader)
    var ua = rb.column_at(0).as_union()
    assert_equal(Int(ua.type_id_at(0)), 1)
    assert_equal(Int(ua.type_id_at(1)), 0)
    assert_equal(ua.child_at(1).as_string().get(0), "ab")
    assert_equal(Int(ua.child_at(0).as_primitive[DType.int32]().get(0)), 6)


# A writer type that matches no reader branch is refused when the table is
# built (no value of it could ever be read).
def test_reader_union_without_matching_branch_refused() raises:
    var writer = _record('{"name":"v","type":"double"}')
    var reader = _record('{"name":"v","type":["int","string"]}')
    var p = List[UInt8]()
    for _i in range(8):
        p.append(0)
    var err = _resolve_error(_ocf(writer, 1, p), reader)
    assert_true(
        err.find("AvroResolutionError.UNION_NO_MATCHING_BRANCH") >= 0, err
    )


# A reader-only union field takes its default from the first branch the
# default fits.
def test_reader_union_default() raises:
    var writer = _record('{"name":"a","type":"int"}')
    var reader = _record(
        '{"name":"a","type":"int"},'
        '{"name":"u","type":["int","string"],"default":5}'
    )
    var p = List[UInt8]()
    _enc_long(1, p)
    var rb = read_avro_bytes_resolved(Span(_ocf(writer, 1, p)), reader)
    var ua = rb.column_at(1).as_union()
    assert_equal(Int(ua.type_id_at(0)), 0)
    assert_equal(Int(ua.child_at(0).as_primitive[DType.int32]().get(0)), 5)


# -----------------------------------------------------------------------------
# Issue case 2, plain read: the writer union ["int","string"] reads as a dense
# union column of the writer's own branches.
# -----------------------------------------------------------------------------
def test_plain_read_union_without_null() raises:
    var writer = _record('{"name":"v","type":["int","string"]}')
    var p = List[UInt8]()
    _enc_long(0, p)
    _enc_long(1, p)
    _enc_long(1, p)
    _enc_str("hi", p)
    _enc_long(0, p)
    _enc_long(2, p)
    var rb = read_avro_bytes(Span(_ocf(writer, 3, p)))
    assert_equal(rb.num_rows(), 3)
    var ua = rb.column_at(0).as_union()
    assert_equal(Int(ua.type_id_at(0)), 0)
    assert_equal(Int(ua.type_id_at(1)), 1)
    assert_equal(Int(ua.type_id_at(2)), 0)
    assert_equal(Int(ua.offset_at(2)), 1)
    var ints = ua.child_at(0).as_primitive[DType.int32]()
    assert_equal(Int(ints.get(0)), 1)
    assert_equal(Int(ints.get(1)), 2)
    assert_equal(ua.child_at(1).as_string().get(0), "hi")


# A three-branch union with null: the null row selects the NULL child.
def test_plain_read_three_branch_union_with_null() raises:
    var writer = _record(
        '{"name":"v","type":["null","int","string"]},{"name":"w","type":"int"}'
    )
    var p = List[UInt8]()
    _enc_long(0, p)  # v = null
    _enc_long(3, p)  # w = 3
    _enc_long(2, p)  # v = "z"
    _enc_str("z", p)
    _enc_long(4, p)  # w = 4
    var rb = read_avro_bytes(Span(_ocf(writer, 2, p)))
    var ua = rb.column_at(0).as_union()
    assert_equal(Int(ua.type_id_at(0)), 0)
    assert_equal(Int(ua.type_id_at(1)), 2)
    assert_true(ua.child_at(0).arrow_type == ArrowType.NULL)
    assert_equal(ua.child_at(0).length(), 1)
    assert_equal(ua.child_at(2).as_string().get(0), "z")
    var w = rb.column_at(1).as_primitive[DType.int32]()
    assert_equal(Int(w.get(0)), 3)
    assert_equal(Int(w.get(1)), 4)


# -----------------------------------------------------------------------------
# Issue case 3: a writer-only array field is skipped. Row 0 uses a positive
# block count; row 1 a negative count followed by the block's byte size (the
# spec's skippable form).
# -----------------------------------------------------------------------------
def test_skip_writer_only_array() raises:
    var writer = _record(
        '{"name":"arr","type":{"type":"array","items":"int"}},'
        '{"name":"v","type":"long"}'
    )
    var reader = _record('{"name":"v","type":"long"}')
    var p = List[UInt8]()
    _enc_long(0, p)  # row 0: arr = [] (issue's payload 00 02)
    _enc_long(1, p)  # v = 1
    _enc_long(2, p)  # row 1: arr = [1, 2]
    _enc_long(1, p)
    _enc_long(2, p)
    _enc_long(0, p)
    _enc_long(2, p)  # v = 2
    _enc_long(-2, p)  # row 2: one block of 2 items, 2 bytes
    _enc_long(2, p)
    _enc_long(5, p)
    _enc_long(6, p)
    _enc_long(0, p)
    _enc_long(3, p)  # v = 3
    var rb = read_avro_bytes_resolved(Span(_ocf(writer, 3, p)), reader)
    var v = rb.column_at(0).as_primitive[DType.int64]()
    assert_equal(Int(v.get(0)), 1)
    assert_equal(Int(v.get(1)), 2)
    assert_equal(Int(v.get(2)), 3)


# Every other nested kind: record, enum, map, a three-branch union and fixed,
# each skipped so that `v` decodes from the right offset.
def test_skip_writer_only_nested_kinds() raises:
    var writer = _record(
        '{"name":"r","type":{"type":"record","name":"In","fields":['
        '{"name":"a","type":"int"},{"name":"s","type":"string"}]}},'
        '{"name":"e","type":{"type":"enum","name":"E","symbols":["X","Y"]}},'
        '{"name":"m","type":{"type":"map","values":"long"}},'
        '{"name":"u","type":["int","string","null"]},'
        '{"name":"f","type":{"type":"fixed","name":"F","size":2}},'
        '{"name":"v","type":"long"}'
    )
    var reader = _record('{"name":"v","type":"long"}')
    var p = List[UInt8]()
    for row in range(2):
        _enc_long(1, p)  # r.a
        _enc_str("ab", p)  # r.s
        _enc_long(1, p)  # e = Y
        _enc_long(1, p)  # m: one entry
        _enc_str("k", p)
        _enc_long(5, p)
        _enc_long(0, p)
        if row == 0:
            _enc_long(1, p)  # u = "z"
            _enc_str("z", p)
        else:
            _enc_long(2, p)  # u = null
        p.append(0xAA)  # f
        p.append(0xBB)
        _enc_long(Int64(40 + row), p)  # v
    var rb = read_avro_bytes_resolved(Span(_ocf(writer, 2, p)), reader)
    var v = rb.column_at(0).as_primitive[DType.int64]()
    assert_equal(Int(v.get(0)), 40)
    assert_equal(Int(v.get(1)), 41)


# A block count of 2^40 items that occupy no bytes (array of null) must not
# spin 2^40 times: there is nothing to skip.
def test_skip_zero_width_items_is_bounded() raises:
    var writer = _record(
        '{"name":"n","type":{"type":"array","items":"null"}},'
        '{"name":"v","type":"long"}'
    )
    var reader = _record('{"name":"v","type":"long"}')
    var p = List[UInt8]()
    _enc_long(Int64(1) << 40, p)
    _enc_long(0, p)
    _enc_long(9, p)
    var rb = read_avro_bytes_resolved(Span(_ocf(writer, 1, p)), reader)
    assert_equal(Int(rb.column_at(0).as_primitive[DType.int64]().get(0)), 9)


# -----------------------------------------------------------------------------
# Issue case 4: a plain read of a "null" field is an Arrow NULL column.
# -----------------------------------------------------------------------------
def test_plain_read_null_field() raises:
    var writer = _record('{"name":"n","type":"null"}')
    var p = List[UInt8]()
    var rb = read_avro_bytes(Span(_ocf(writer, 1, p)))
    assert_equal(rb.num_rows(), 1)
    assert_true(rb.schema.field_at_unchecked(0).arrow_type == ArrowType.NULL)
    assert_true(rb.schema.field_at_unchecked(0).nullable)
    assert_equal(rb.column_at(0).length(), 1)
    assert_equal(rb.column_at(0).null_count(), 1)


# A null field between two others consumes no byte.
def test_plain_read_null_field_between_values() raises:
    var writer = _record(
        '{"name":"a","type":"int"},{"name":"n","type":"null"},'
        '{"name":"b","type":"string"}'
    )
    var p = List[UInt8]()
    _enc_long(8, p)
    _enc_str("q", p)
    _enc_long(9, p)
    _enc_str("r", p)
    var rb = read_avro_bytes(Span(_ocf(writer, 2, p)))
    assert_equal(rb.column_at(1).null_count(), 2)
    assert_equal(Int(rb.column_at(0).as_primitive[DType.int32]().get(1)), 9)
    assert_equal(rb.column_as_string(2).get(1), "r")


def main() raises:
    test_writer_union_without_null_into_long()
    test_writer_union_branch_without_match_raises_on_read()
    test_writer_three_branch_union_into_double()
    test_writer_union_tag_out_of_range_raises()
    test_reader_three_branch_union_from_long()
    test_reader_union_prefers_same_type_branch()
    test_union_to_union_routes_each_branch()
    test_reader_union_without_matching_branch_refused()
    test_reader_union_default()
    test_plain_read_union_without_null()
    test_plain_read_three_branch_union_with_null()
    test_skip_writer_only_array()
    test_skip_writer_only_nested_kinds()
    test_skip_zero_width_items_is_bounded()
    test_plain_read_null_field()
    test_plain_read_null_field_between_values()
    print("test_avro_spec_valid_unions_skip_null: ALL PASS")
