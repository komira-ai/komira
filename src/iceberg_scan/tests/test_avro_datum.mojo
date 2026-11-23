# =============================================================================
# read_avro_datums: Avro object container files decoded by their own schema
# =============================================================================
#
# What each test proves:
#   * test_every_avro_kind_decodes: boolean, int, long, float, double, string,
#     bytes, enum, fixed, a union (both branches), an array written as one
#     block of two items and a negative-count block, a map and a null field
#     decode to the values written, and the accessors return None for an absent
#     name, a NULL value or a value of another kind.
#   * test_deflate_and_several_blocks_decode_in_file_order: a deflate file of
#     two blocks gives its records in file order, and the header map's keys
#     (the codec and a caller's own) read back.
#   * test_a_header_map_in_negative_count_blocks_reads: a header written with
#     a negative pair count (the form with a block byte size) reads.
#   * test_a_field_lookup_outside_the_arena_is_absent: `field` on an index out
#     of range or on a node that is no record is -1.
#   * test_damaged_files_are_refused_by_message: bytes that are no OCF file, a
#     union branch or enum symbol out of range, a negative or overlong length,
#     a value that runs past its block, bytes after the last record, an item
#     count past the block, a count of the most negative long, a header that
#     claims more pairs than it holds and a block cut short are each refused with
#     ICEBERG_MANIFEST_INVALID and the reason.

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from avro.ocf_block_emit import emit_ocf_block, emit_ocf_header_kv
from avro.ocf_header import (
    AVRO_CODEC_DEFLATE,
    AVRO_CODEC_NULL,
    OCF_SYNC_LEN,
)
from avro.varint_encode import (
    encode_boolean,
    encode_bytes,
    encode_double,
    encode_fixed,
    encode_float,
    encode_int,
    encode_long,
    encode_string,
)
from iceberg_scan.avro_datum import (
    AVRO_DATUM_ARRAY,
    AVRO_DATUM_ENUM,
    AVRO_DATUM_MAP,
    AVRO_DATUM_NULL,
    AVRO_DATUM_RECORD,
    read_avro_datums,
)


comptime _ALL_KINDS = String(
    '{"type":"record","name":"all","fields":['
    '{"name":"b","type":"boolean"},'
    '{"name":"i","type":"int"},'
    '{"name":"l","type":"long"},'
    '{"name":"f","type":"float"},'
    '{"name":"d","type":"double"},'
    '{"name":"s","type":"string"},'
    '{"name":"y","type":"bytes"},'
    '{"name":"e","type":{"type":"enum","name":"color","symbols":["RED","GREEN"]}},'
    '{"name":"x","type":{"type":"fixed","name":"fx","size":3}},'
    '{"name":"u","type":["null","long"]},'
    '{"name":"un","type":["null","long"]},'
    '{"name":"a","type":{"type":"array","items":"int"}},'
    '{"name":"m","type":{"type":"map","values":"string"}},'
    '{"name":"z","type":"null"}'
    "]}"
)

comptime _ONE_UNION = String(
    '{"type":"record","name":"r","fields":[{"name":"u","type":["null","long"]}]}'
)
comptime _ONE_ENUM = String(
    '{"type":"record","name":"r","fields":['
    '{"name":"e","type":{"type":"enum","name":"c","symbols":["A"]}}]}'
)
comptime _ONE_STRING = String(
    '{"type":"record","name":"r","fields":[{"name":"s","type":"string"}]}'
)
comptime _ONE_ARRAY = String(
    '{"type":"record","name":"r","fields":['
    '{"name":"a","type":{"type":"array","items":"int"}}]}'
)
comptime _ONE_LONG = String(
    '{"type":"record","name":"r","fields":[{"name":"l","type":"long"}]}'
)


def _sync() -> Array[UInt8, OCF_SYNC_LEN]:
    return Array[UInt8, OCF_SYNC_LEN](fill=3)


def _ocf(schema: String, payload: List[UInt8], count: Int, codec: Int) raises -> List[UInt8]:
    var keys = List[String]()
    var values = List[String]()
    keys.append("iceberg.note")
    values.append("kept")
    var out = List[UInt8]()
    emit_ocf_header_kv(schema, codec, _sync(), keys, values, out)
    emit_ocf_block(Span(payload), count, codec, _sync(), out)
    return out^


def _all_kinds_record(mut p: List[UInt8]):
    encode_boolean(True, p)
    encode_int(-3, p)
    encode_long(Int64(1099511627776), p)
    encode_float(1.5, p)
    encode_double(-2.25, p)
    encode_string("héllo", p)
    var raw = List[UInt8]()
    raw.append(1)
    raw.append(2)
    raw.append(255)
    encode_bytes(Span(raw), p)
    encode_long(1, p)  # enum: GREEN
    var fixed = List[UInt8]()
    fixed.append(9)
    fixed.append(8)
    fixed.append(7)
    encode_fixed(Span(fixed), p)
    encode_long(1, p)  # u: the long branch
    encode_long(42, p)
    encode_long(0, p)  # un: the null branch
    encode_long(2, p)  # a: a block of two items
    encode_int(10, p)
    encode_int(20, p)
    encode_long(-1, p)  # then a block of one item that gives its byte size
    encode_long(1, p)
    encode_int(30, p)
    encode_long(0, p)
    encode_long(1, p)  # m: one pair
    encode_string("k", p)
    encode_string("v", p)
    encode_long(0, p)


def _error_of(bytes: List[UInt8]) -> String:
    try:
        _ = read_avro_datums(Span(bytes))
    except e:
        return String(e)
    return String("(accepted)")


def test_every_avro_kind_decodes() raises:
    var p = List[UInt8]()
    _all_kinds_record(p)
    var d = read_avro_datums(Span(_ocf(_ALL_KINDS, p, 1, AVRO_CODEC_NULL)))
    assert_equal(len(d.records), 1)
    var r = d.records[0]
    assert_equal(d.nodes[r].kind, AVRO_DATUM_RECORD)
    assert_true(d.get_bool(r, "b").value())
    assert_equal(d.get_long(r, "i").value(), -3)
    assert_equal(d.get_long(r, "l").value(), Int64(1099511627776))
    assert_equal(d.nodes[d.field(r, "f")].f, 1.5)
    assert_equal(d.nodes[d.field(r, "d")].f, -2.25)
    assert_equal(d.get_string(r, "s").value(), "héllo")
    var y = d.get_bytes(r, "y").value().copy()
    assert_equal(len(y), 3)
    assert_equal(Int(y[2]), 255)
    assert_equal(d.nodes[d.field(r, "e")].kind, AVRO_DATUM_ENUM)
    assert_equal(d.nodes[d.field(r, "e")].i, 1)
    var x = d.get_bytes(r, "x").value().copy()
    assert_equal(len(x), 3)
    assert_equal(Int(x[0]), 9)
    assert_equal(d.get_long(r, "u").value(), 42)
    assert_equal(d.field(r, "un"), -1)
    assert_false(Bool(d.get_long(r, "un")))
    var a = d.field(r, "a")
    assert_equal(d.nodes[a].kind, AVRO_DATUM_ARRAY)
    assert_equal(len(d.nodes[a].children), 3)
    assert_equal(d.nodes[d.nodes[a].children[0]].i, 10)
    assert_equal(d.nodes[d.nodes[a].children[1]].i, 20)
    assert_equal(d.nodes[d.nodes[a].children[2]].i, 30)
    var m = d.field(r, "m")
    assert_equal(d.nodes[m].kind, AVRO_DATUM_MAP)
    assert_equal(len(d.nodes[m].names), 1)
    assert_equal(d.nodes[m].names[0], "k")
    assert_equal(
        String(unsafe_from_utf8=Span(d.nodes[d.nodes[m].children[0]].bytes)), "v"
    )
    assert_equal(d.field(r, "z"), -1)
    assert_equal(d.nodes[d.nodes[r].children[13]].kind, AVRO_DATUM_NULL)
    # Absent, or of another kind: None.
    assert_false(Bool(d.get_long(r, "absent")))
    assert_false(Bool(d.get_string(r, "i")))
    assert_false(Bool(d.get_bytes(r, "s")))
    assert_false(Bool(d.get_bool(r, "i")))
    assert_false(Bool(d.get_long(r, "s")))
    assert_equal(d.field(r, "absent"), -1)


def test_deflate_and_several_blocks_decode_in_file_order() raises:
    var keys = List[String]()
    var values = List[String]()
    keys.append("iceberg.note")
    values.append("kept")
    var out = List[UInt8]()
    emit_ocf_header_kv(_ONE_LONG, AVRO_CODEC_DEFLATE, _sync(), keys, values, out)
    for n in range(3):
        var p = List[UInt8]()
        encode_long(Int64(100 + n), p)
        emit_ocf_block(Span(p), 1, AVRO_CODEC_DEFLATE, _sync(), out)
    var d = read_avro_datums(Span(out))
    assert_equal(len(d.records), 3)
    for n in range(3):
        assert_equal(d.get_long(d.records[n], "l").value(), Int64(100 + n))
    assert_equal(d.metadata("avro.codec").value(), "deflate")
    assert_equal(d.metadata("iceberg.note").value(), "kept")
    assert_false(Bool(d.metadata("absent")))
    assert_true(d.metadata("avro.schema").value().find("\"long\"") >= 0)


def test_a_header_map_in_negative_count_blocks_reads() raises:
    var out = List[UInt8]()
    out.append(UInt8(ord("O")))
    out.append(UInt8(ord("b")))
    out.append(UInt8(ord("j")))
    out.append(1)
    encode_long(-2, out)  # two pairs, preceded by their byte size
    encode_long(0, out)
    encode_string("avro.schema", out)
    encode_string(_ONE_LONG, out)
    encode_string("avro.codec", out)
    encode_string("null", out)
    encode_long(0, out)
    for _k in range(OCF_SYNC_LEN):
        out.append(3)
    var p = List[UInt8]()
    encode_long(7, p)
    emit_ocf_block(Span(p), 1, AVRO_CODEC_NULL, _sync(), out)
    var d = read_avro_datums(Span(out))
    assert_equal(d.get_long(d.records[0], "l").value(), 7)
    assert_equal(d.metadata("avro.codec").value(), "null")


def test_a_field_lookup_outside_the_arena_is_absent() raises:
    var p = List[UInt8]()
    encode_long(5, p)
    var d = read_avro_datums(Span(_ocf(_ONE_LONG, p, 1, AVRO_CODEC_NULL)))
    var r = d.records[0]
    assert_equal(d.field(-1, "l"), -1)
    assert_equal(d.field(len(d.nodes), "l"), -1)
    # The field's own node is no record.
    assert_equal(d.field(d.field(r, "l"), "l"), -1)


def test_damaged_files_are_refused_by_message() raises:
    var prefix = String("ICEBERG_MANIFEST_INVALID: ")

    var junk = List[UInt8]()
    for k in range(40):
        junk.append(UInt8(65 + k % 20))
    assert_equal(
        _error_of(junk),
        prefix + "AvroOcfError.BAD_MAGIC: expected 'Obj' 0x01",
    )

    var bad_branch = List[UInt8]()
    encode_long(5, bad_branch)
    assert_equal(
        _error_of(_ocf(_ONE_UNION, bad_branch, 1, AVRO_CODEC_NULL)),
        prefix + "a union branch index is out of range",
    )

    var bad_enum = List[UInt8]()
    encode_long(3, bad_enum)
    assert_equal(
        _error_of(_ocf(_ONE_ENUM, bad_enum, 1, AVRO_CODEC_NULL)),
        prefix + "an enum symbol index is out of range",
    )

    var negative = List[UInt8]()
    encode_long(-1, negative)
    assert_equal(
        _error_of(_ocf(_ONE_STRING, negative, 1, AVRO_CODEC_NULL)),
        prefix + "a negative length",
    )

    var too_long = List[UInt8]()
    encode_long(50, too_long)
    assert_equal(
        _error_of(_ocf(_ONE_STRING, too_long, 1, AVRO_CODEC_NULL)),
        prefix + "a value runs past the end of its block",
    )

    assert_equal(
        _error_of(_ocf(_ONE_LONG, List[UInt8](), 1, AVRO_CODEC_NULL)),
        prefix + "a value runs past the end of its block",
    )

    var overlong = List[UInt8]()
    for _k in range(11):
        overlong.append(0x80)
    assert_equal(
        _error_of(_ocf(_ONE_LONG, overlong, 1, AVRO_CODEC_NULL)),
        prefix + "an integer is longer than 10 bytes",
    )

    var trailing = List[UInt8]()
    encode_long(1, trailing)
    encode_long(2, trailing)
    assert_equal(
        _error_of(_ocf(_ONE_LONG, trailing, 1, AVRO_CODEC_NULL)),
        prefix + "a block holds bytes after its last record",
    )

    var big_count = List[UInt8]()
    encode_long(1000, big_count)
    assert_equal(
        _error_of(_ocf(_ONE_ARRAY, big_count, 1, AVRO_CODEC_NULL)),
        prefix + "an item count runs past the end of its block",
    )

    # zigzag of the most negative long: nine 0xFF bytes and 0x01.
    var most_negative = List[UInt8]()
    for _k in range(9):
        most_negative.append(0xFF)
    most_negative.append(0x01)
    assert_equal(
        _error_of(_ocf(_ONE_ARRAY, most_negative, 1, AVRO_CODEC_NULL)),
        prefix + "an item count is out of range",
    )

    # A header map that claims more pairs than the header holds.
    var header = List[UInt8]()
    header.append(UInt8(ord("O")))
    header.append(UInt8(ord("b")))
    header.append(UInt8(ord("j")))
    header.append(1)
    encode_long(500, header)
    encode_string("avro.schema", header)
    encode_string(_ONE_LONG, header)
    encode_long(0, header)
    for _k in range(OCF_SYNC_LEN):
        header.append(3)
    assert_true(_error_of(header).startswith(prefix))

    var cut = _ocf(_ONE_LONG, trailing, 2, AVRO_CODEC_NULL)
    var shortened = List[UInt8]()
    for k in range(len(cut) - 5):
        shortened.append(cut[k])
    assert_true(_error_of(shortened).startswith(prefix))


def main() raises:
    var suite = TestSuite()
    suite.test[test_every_avro_kind_decodes]()
    suite.test[test_deflate_and_several_blocks_decode_in_file_order]()
    suite.test[test_a_header_map_in_negative_count_blocks_reads]()
    suite.test[test_a_field_lookup_outside_the_arena_is_absent]()
    suite.test[test_damaged_files_are_refused_by_message]()
    suite^.run()
