# =============================================================================
# FFI-BOUNDARY: a stand-in foreign producer of Arrow C Data Interface
# dictionary arrays, and a consumer of the streams this library exports. The
# hand-built structs and buffers are allocated here with `alloc` and left
# allocated for the life of the test process (none carries a release; the
# importer copies and frees nothing of a foreign struct). Exported streams,
# schemas and arrays are released through `release_c_*` and their boxes freed.
#
# Arrow C Data Interface: the width of dictionary indices.
#
# Spec: https://arrow.apache.org/docs/format/CDataInterface.html. For a
# dictionary-encoded array the parent format string is the INDEX type, and
# "the index type MUST be an integer type, preferably signed". Every buffer
# holds `length` values of that width.
#
#   * Import of each index type `c s i l C S I L`: the bytes are read at the
#     declared width (one width for the 8-bit types is a 4-byte read past a
#     1-byte-per-row buffer if the width is ignored), stored as INT32 (8- to
#     32-bit) or INT64 (64-bit), and the Field says so. An unsigned index that
#     does not fit the storage is refused on a valid row and stored as 0 on a
#     null row (the value under a null is undefined).
#   * Round trip: an imported 8-bit and 64-bit dictionary exports with the
#     format of the bytes it holds and drains back to the same indices.
#   * Export agreement: the Field's index type and the Column's index byte
#     width must agree (INT32 with 4, INT64 with 8); any other pairing, a
#     numeric dictionary or a DICTIONARY Field over a non-dictionary column
#     is refused instead of exported with a format that misdescribes it.
#   * A dictionary below the top level is refused on import and export, and a
#     dictionary value array whose buffer count is not 3 is refused.
# =============================================================================

from std.memory import alloc
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.dictionary_array import StringDictionaryArray
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import Field, RecordBatch, Schema, SchemaBuilder
from komira_arrow.string_array import StringArray
from komira_arrow_ipc.c_data_interface import ARROW_FLAG_NULLABLE
from komira_arrow_ipc.c_data_stream import (
    CArrowArray,
    CArrowArrayStream,
    CArrowSchema,
    build_record_batch_stream,
    drain_record_batch_stream,
    release_c_array,
    release_c_schema,
    release_c_stream,
    _alloc_array_ptr_array,
    _alloc_buffers_array,
    _alloc_schema_ptr_array,
    _build_schema_from_info,
    _c_str_to_mojo,
    _copy_string_to_c_int8,
    _import_column,
    _import_record_batch,
    _null_ptr,
    _read_root_schema,
)
from komira_buffer.heap_region import HeapRegion
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_collections.slab import Slab

comptime _VP = UnsafePointer[NoneType, MutUntrackedOrigin]
comptime _AP = UnsafePointer[CArrowArray, MutUntrackedOrigin]
comptime _SP = UnsafePointer[CArrowSchema, MutUntrackedOrigin]
comptime _STP = UnsafePointer[CArrowArrayStream, MutUntrackedOrigin]


# --- a hand-built foreign producer ----------------------------------------------


def _arr(length: Int, n_buffers: Int, null_count: Int = 0) -> CArrowArray:
    var a = CArrowArray()
    a.length = Int64(length)
    a.null_count = Int64(null_count)
    a.n_buffers = Int64(n_buffers)
    a.buffers = _alloc_buffers_array(n_buffers)  # every slot NULL
    return a^


def _ha(var a: CArrowArray) -> _AP:
    var p = alloc[CArrowArray](1).unsafe_origin_cast[MutUntrackedOrigin]()
    p.unsafe_write(a^)
    return p


def _sch(fmt: String, name: String = "", flags: Int64 = 0) -> CArrowSchema:
    var s = CArrowSchema()
    s.format = _copy_string_to_c_int8(fmt)
    s.name = _copy_string_to_c_int8(name)
    s.flags = flags
    return s^


def _hs(var s: CArrowSchema) -> _SP:
    var p = alloc[CArrowSchema](1).unsafe_origin_cast[MutUntrackedOrigin]()
    p.unsafe_write(s^)
    return p


def _akids(mut a: CArrowArray, kids: List[_AP]):
    a.n_children = Int64(len(kids))
    a.children = _alloc_array_ptr_array(len(kids))
    for i in range(len(kids)):
        (a.children + i).unsafe_write(kids[i])


def _skids(mut s: CArrowSchema, kids: List[_SP]):
    s.n_children = Int64(len(kids))
    s.children = _alloc_schema_ptr_array(len(kids))
    for i in range(len(kids)):
        (s.children + i).unsafe_write(kids[i])


def _bytes(values: List[Int]) -> _VP:
    """`values` as bytes, followed by 64 zero bytes: a reader that ignores the
    declared width reads zeros, not another allocation."""
    var n = len(values) + 64
    var p = alloc[UInt8](n).unsafe_origin_cast[MutUntrackedOrigin]()
    for i in range(n):
        (p + i).unsafe_write(UInt8(values[i]) if i < len(values) else UInt8(0))
    return p.bitcast[NoneType]()


def _le(values: List[Int], width: Int) -> List[Int]:
    """Little-endian bytes of `values` at `width` bytes each."""
    var out = List[Int]()
    for i in range(len(values)):
        var v = values[i]
        for b in range(width):
            out.append((v >> (8 * b)) & 0xFF)
    return out^


def _width(fmt: String) -> Int:
    if fmt == "c" or fmt == "C":
        return 1
    if fmt == "s" or fmt == "S":
        return 2
    if fmt == "i" or fmt == "I":
        return 4
    return 8


def _values_array() -> _AP:
    """The STRING value array `["a", "b", "c"]`."""
    var v = _arr(3, 3)
    (v.buffers + 1).unsafe_write(_bytes(_le([0, 1, 2, 3], 4)))
    (v.buffers + 2).unsafe_write(_bytes([0x61, 0x62, 0x63]))
    return _ha(v^)


def _dict_child(fmt: String, indices: List[Int], valid_byte: Int = -1) -> _AP:
    """A dictionary array of `indices` at `fmt`'s width; `valid_byte` >= 0 is
    the validity bitmap's single byte."""
    var nulls = 0
    if valid_byte >= 0:
        for i in range(len(indices)):
            if (valid_byte >> i) & 1 == 0:
                nulls += 1
    var a = _arr(len(indices), 2, nulls)
    if valid_byte >= 0:
        (a.buffers + 0).unsafe_write(_bytes([valid_byte]))
    (a.buffers + 1).unsafe_write(_bytes(_le(indices, _width(fmt))))
    a.dictionary = _values_array()
    return _ha(a^)


def _root_schema(fmt: String) -> _SP:
    var k = _sch(fmt, "d", ARROW_FLAG_NULLABLE)
    k.dictionary = _hs(_sch("u"))
    var r = _sch("+s")
    _skids(r, [_hs(k^)])
    return _hs(r^)


def _root_array(kid: _AP, length: Int) -> _AP:
    var r = _arr(length, 1)
    _akids(r, [kid])
    return _ha(r^)


def _import(fmt: String, indices: List[Int], valid_byte: Int = -1) raises -> RecordBatch:
    """The drain's own path: `_read_root_schema`, then `_import_record_batch`."""
    var sch = _root_schema(fmt)
    var info = _read_root_schema(sch)
    var arr = _root_array(_dict_child(fmt, indices, valid_byte), len(indices))
    return _import_record_batch(arr, info, _build_schema_from_info(info), sch)


def _import_error(fmt: String, indices: List[Int], valid_byte: Int = -1) -> String:
    try:
        _ = _import(fmt, indices, valid_byte)
    except e:
        return String(e)
    return String("(imported)")


def _index_at(c: Column[HeapRegion], i: Int) -> Int:
    if c.dict_index_byte_width() == 8:
        return Int(c._data.read_i64_le_at(i * 8))
    return Int(c._data.read_i32_le_at(i * 4))


def _value(c: Column[HeapRegion], k: Int) -> String:
    """Dictionary value `k`, read from the value offsets and bytes."""
    var lo = Int(c._offsets.value().read_i32_le_at(k * 4))
    var hi = Int(c._offsets.value().read_i32_le_at(k * 4 + 4))
    var out = String("")
    for j in range(lo, hi):
        out += chr(Int(c._dict_data.value().read_u8_at(j)))
    return out^


# --- import -------------------------------------------------------------------


def test_import_reads_each_index_width() raises:
    var fmts: List[String] = ["c", "s", "i", "l", "C", "S", "I", "L"]
    var want_t = [
        ArrowType.INT32, ArrowType.INT32, ArrowType.INT32, ArrowType.INT64,
        ArrowType.INT32, ArrowType.INT32, ArrowType.INT32, ArrowType.INT64,
    ]
    var indices: List[Int] = [2, 0, 1, 2]
    for f in range(len(fmts)):
        var b = _import(fmts[f], indices)
        ref c = b.column_at(0)
        assert_true(c.arrow_type == ArrowType.DICTIONARY, fmts[f])
        var w = 8 if want_t[f] == ArrowType.INT64 else 4
        assert_equal(c.dict_index_byte_width(), w, fmts[f])
        assert_equal(c._data.len(), 4 * w, fmts[f])
        for i in range(4):
            assert_equal(_index_at(c, i), indices[i], fmts[f])
        assert_true(b.schema.field_at(0).dict_index_type() == want_t[f], fmts[f])
        assert_equal(c._dict_size, 3, fmts[f])
        assert_equal(_value(c, 2), String("c"), fmts[f])


def test_import_sign_extends_signed_indices() raises:
    # -1 in 8 and 16 bits is 0xFF / 0xFFFF; widened it stays -1. The value
    # is not a valid index, but widening must not change it into one.
    var fmts: List[String] = ["c", "s", "C", "S"]
    var first = [-1, -1, 255, 65535]
    for f in range(len(fmts)):
        var b = _import(fmts[f], [first[f], 1])
        assert_equal(_index_at(b.column_at(0), 0), first[f], fmts[f])


def test_import_refuses_an_unsigned_index_that_does_not_fit() raises:
    var big32 = 0x80000000
    assert_true(
        _import_error("I", [1, big32], 0b11).startswith(
            "from_arrow_c_stream: dictionary index 2147483648 at row 1 does not fit"
            " the INT32 index storage"
        ),
        _import_error("I", [1, big32], 0b11),
    )
    var big64 = Int(UInt64(1) << 63)  # bit pattern 0x8000000000000000
    assert_true(
        _import_error("L", [big64, 1], 0b11).startswith(
            "from_arrow_c_stream: dictionary index 9223372036854775808 at row 0 does"
            " not fit the INT64 index storage"
        ),
        _import_error("L", [big64, 1], 0b11),
    )
    # The same values under a null row are undefined and stored as 0.
    var b = _import("I", [1, big32], 0b01)
    assert_equal(_index_at(b.column_at(0), 1), 0)
    assert_true(b.column_at(0).is_null_at(1))
    var b64 = _import("L", [big64, 1], 0b10)
    assert_equal(_index_at(b64.column_at(0), 0), 0)
    # A null row's in-range value is kept as the producer wrote it.
    var kept = _import("I", [1, 2], 0b01)
    assert_equal(_index_at(kept.column_at(0), 1), 2)


def test_import_refuses_a_non_integer_index_type() raises:
    var sch = _root_schema("g")
    var msg = String("")
    try:
        _ = _read_root_schema(sch)
    except e:
        msg = String(e)
    assert_equal(
        msg,
        String(
            "from_arrow_c_stream: dictionary index type must be an integer"
            " (c s i l C S I L), got 'g'"
        ),
    )


def test_import_column_refuses_a_non_integer_declared_index_type() raises:
    # `_read_root_schema` refuses such a schema first; this is the importer's
    # own guard for a caller that hands one in directly.
    var a = _arr(0, 2)
    a.dictionary = _values_array()
    var msg = String("")
    try:
        _ = _import_column(a, ArrowType.DICTIONARY, 0, 0, _null_ptr[CArrowSchema, MutUntrackedOrigin](), ArrowType.FLOAT64)
    except e:
        msg = String(e)
    assert_equal(
        msg, String("from_arrow_c_stream: dictionary index type 'float64' is not an integer")
    )


def test_import_refuses_a_value_array_with_another_buffer_count() raises:
    # The value array declares 1 buffer; its buffers array has room for 3, so
    # an importer that ignores `n_buffers` reads NULL slots, not past the end.
    var v = _arr(0, 3)
    v.n_buffers = 1
    var a = _arr(0, 2)
    a.dictionary = _ha(v^)
    var msg = String("")
    try:
        _ = _import_column(a, ArrowType.DICTIONARY)
    except e:
        msg = String(e)
    assert_equal(
        msg,
        String("from_arrow_c_stream: dictionary value array has 1 buffers, expected 3"),
    )


def test_import_refuses_a_nested_dictionary() raises:
    # A STRUCT child whose schema carries a dictionary: its format is the
    # index type, so reading it as a plain column would drop the values.
    var k = _sch("i", "k")
    k.dictionary = _hs(_sch("u"))
    var s = _sch("+s", "s")
    _skids(s, [_hs(k^)])
    var kid = _arr(0, 2)
    kid.dictionary = _values_array()
    var a = _arr(0, 1)
    _akids(a, [_ha(kid^)])
    var msg = String("")
    try:
        _ = _import_column(a, ArrowType.STRUCT, 0, 0, _hs(s^))
    except e:
        msg = String(e)
    assert_equal(
        msg,
        String(
            "UnsupportedArrowCABIType: child 'k' is dictionary-encoded; only"
            " top-level columns may be dictionary-encoded"
        ),
    )


# --- export -------------------------------------------------------------------


def _export(var fields: List[Field], var cols: List[Column[HeapRegion]], rows: Int) raises -> _STP:
    var sb = SchemaBuilder()
    for i in range(len(fields)):
        sb.add_field(fields[i].copy())
    var schema = sb.build()
    var slab = Slab[Column[HeapRegion]].with_capacity(max(len(cols), 1))
    while len(cols) > 0:
        slab.append(cols.pop(0))
    var b = RecordBatch()
    b.schema = schema.copy()
    b._columns = slab^
    b._num_rows = rows
    var bs = Slab[RecordBatch].with_capacity(1)
    bs.append(b^)
    var sp = alloc[CArrowArrayStream](1).unsafe_origin_cast[MutUntrackedOrigin]()
    sp.unsafe_write(CArrowArrayStream())
    build_record_batch_stream(bs^, schema^, sp)
    return sp


def _restream(var b: RecordBatch) raises -> _STP:
    var schema = b.schema.copy()
    var bs = Slab[RecordBatch].with_capacity(1)
    bs.append(b^)
    var sp = alloc[CArrowArrayStream](1).unsafe_origin_cast[MutUntrackedOrigin]()
    sp.unsafe_write(CArrowArrayStream())
    build_record_batch_stream(bs^, schema^, sp)
    return sp


def _child_format(sp: _STP) raises -> String:
    var sb = alloc[CArrowSchema](1).unsafe_origin_cast[MutUntrackedOrigin]()
    sb.unsafe_write(CArrowSchema())
    assert_equal(Int(sp[].get_schema(sp.bitcast[NoneType](), sb)), 0, "get_schema")
    var fmt = _c_str_to_mojo((sb[].children + 0)[][].format)
    release_c_schema(sb)
    sb.free()
    return fmt^


def _error_of(sp: _STP, schema: Bool) -> String:
    """The rc and `get_last_error` text of get_schema (or get_next)."""
    var rc: Int32
    if schema:
        var sb = alloc[CArrowSchema](1).unsafe_origin_cast[MutUntrackedOrigin]()
        sb.unsafe_write(CArrowSchema())
        rc = sp[].get_schema(sp.bitcast[NoneType](), sb)
        release_c_schema(sb)
        sb.free()
    else:
        var ab = alloc[CArrowArray](1).unsafe_origin_cast[MutUntrackedOrigin]()
        ab.unsafe_write(CArrowArray())
        rc = sp[].get_next(sp.bitcast[NoneType](), ab)
        release_c_array(ab)
        ab.free()
    if rc == 0:
        return String("(rc 0)")
    return _c_str_to_mojo(sp[].get_last_error(sp.bitcast[NoneType]()))


def _close(sp: _STP):
    release_c_stream(sp)
    sp.free()


def test_imported_dictionary_round_trips() raises:
    for fmt in [String("c"), String("S"), String("l"), String("L")]:
        var b = _import(fmt, [2, 0, 1, 2], 0b1011)
        var sp = _restream(b^)
        var want_fmt = String("l") if _width(fmt) == 8 else String("i")
        assert_equal(_child_format(sp), want_fmt, fmt)
        var out = drain_record_batch_stream(sp)
        sp.free()
        ref c = out[0].column_at(0)
        assert_true(c.is_null_at(2), fmt)
        assert_equal(c.null_count(), 1, fmt)
        var want = [2, 0, 1, 2]
        for i in [0, 1, 3]:
            assert_equal(_index_at(c, i), want[i], fmt)
        assert_equal(_value(c, 1), String("b"), fmt)


def _dict32() raises -> Column[HeapRegion]:
    var idx = PrimitiveArray[DType.int32].from_list([Int32(1), Int32(0)])
    var vals: List[String] = ["x", "y"]
    return Column.from_dictionary(
        StringDictionaryArray.from_parts(idx^, StringArray.from_strings(vals^))
    )


def _dict64() raises -> Column[HeapRegion]:
    return Column.from_int64_dict_indices([Int64(1), Int64(0)], ["x", "y"])


def _export_one(var f: Field, var c: Column[HeapRegion]) raises -> _STP:
    var fields = List[Field]()
    fields.append(f^)
    var cols = List[Column[HeapRegion]]()
    cols.append(c^)
    return _export(fields^, cols^, 2)


def test_export_requires_the_index_type_and_width_to_agree() raises:
    var types = [ArrowType.INT8, ArrowType.INT16, ArrowType.INT64, ArrowType.INT32]
    var names: List[String] = ["INT8", "INT16", "INT64", "INT32"]
    var wide = [False, False, False, True]
    for k in range(len(types)):
        var col = _dict64() if wide[k] else _dict32()
        var w = 8 if wide[k] else 4
        var want = (
            "ArrowCStream(export): dictionary column 'd' declares " + names[k]
            + " indices but holds " + String(w) + "-byte indices"
        )
        var sp = _export_one(Field.dictionary("d", types[k], True), col^)
        assert_equal(_error_of(sp, True), want, "get_schema " + names[k])
        assert_equal(_error_of(sp, False), want, "get_next " + names[k])
        _close(sp)


def test_export_of_agreeing_index_widths() raises:
    var sp = _export_one(Field.dictionary("d", ArrowType.INT64, True), _dict64())
    assert_equal(_child_format(sp), String("l"))
    var out = drain_record_batch_stream(sp)
    sp.free()
    ref c = out[0].column_at(0)
    assert_equal(c.dict_index_byte_width(), 8)
    assert_equal(_index_at(c, 0), 1)
    assert_true(out[0].schema.field_at(0).dict_index_type() == ArrowType.INT64)
    var sp2 = _export_one(Field.dictionary("d", ArrowType.INT32, True), _dict32())
    assert_equal(_child_format(sp2), String("i"))
    var out2 = drain_record_batch_stream(sp2)
    sp2.free()
    assert_equal(_index_at(out2[0].column_at(0), 0), 1)


def test_export_refuses_a_dictionary_field_over_another_column() raises:
    var pq: List[String] = ["p", "q"]
    var plain = Column.from_string(StringArray.from_strings(pq))
    var sp = _export_one(Field.dictionary("d", ArrowType.INT32, True), plain^)
    assert_equal(
        _error_of(sp, False),
        String("ArrowCStream(export): dictionary column 'd' holds a string column"),
    )
    _close(sp)
    var codes = PrimitiveArray[DType.int32].from_list([Int32(0), Int32(1)])
    var num = Column.from_numeric_dict[DType.int32, DType.int64](codes^, [Int64(7), Int64(8)])
    var sp2 = _export_one(Field.dictionary("d", ArrowType.INT32, True), num^)
    assert_equal(
        _error_of(sp2, False),
        String(
            "ArrowCStream(export): dictionary column 'd' has numeric values;"
            " only STRING dictionary values are exported"
        ),
    )
    _close(sp2)


def test_export_refuses_a_dictionary_column_under_another_field() raises:
    var sp = _export_one(Field("d", ArrowType.STRING, True), _dict32())
    var want = String(
        "ArrowCStream(export): column 'd' is dictionary-encoded but its field is string"
    )
    assert_equal(_error_of(sp, True), want)
    assert_equal(_error_of(sp, False), want)
    _close(sp)


def test_export_refuses_a_nested_dictionary() raises:
    var data = OwnedAlignedBuffer(1)
    data.set_length(0)
    var s = Column[HeapRegion](
        arrow_type=ArrowType.STRUCT, data=data^, offsets=None, validity=None,
        length=2, null_count=0, offset=0,
    )
    s._children.append(_dict32())
    s._field_names.append("k")
    var sp = _export_one(Field("s", ArrowType.STRUCT, True), s^)
    var want = String(
        "UnsupportedArrowCABIType: child 'k' is dictionary-encoded; only"
        " top-level columns may be dictionary-encoded"
    )
    assert_equal(_error_of(sp, True), want)
    assert_equal(_error_of(sp, False), want)
    _close(sp)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
