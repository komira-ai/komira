# =============================================================================
# FFI-BOUNDARY: a consumer of the Arrow C Stream Interface structs this
# library exports, and a stand-in producer of a few of them. Each stream,
# schema and array box is allocated here with `alloc` and freed here; what
# the library filled into a box is freed first by that struct's own release
# callback (`release_c_*`, or the drain's release of the stream).
#
# Arrow C Stream Interface: the export arms of `c_data_stream.mojo`.
#
# Spec: https://arrow.apache.org/docs/format/CStreamInterface.html and
# https://arrow.apache.org/docs/format/CDataInterface.html. What each group
# proves:
#
#   * Released and zeroed structs. A zeroed `ArrowArrayStream` answers EINVAL
#     from every slot and writes nothing; release moves every slot of an
#     exported stream off its callback; every `release_c_*` /
#     `consumer_release_c_*` helper is a no-op on NULL and on a struct whose
#     `release` is NULL ("released structure"); the producer release frees a
#     partly filled export (NULL child slots, no buffers or format).
#   * The exported callbacks refuse a NULL stream, a NULL out-struct and a
#     stream struct that carries no producer state, with EINVAL; get_last_error
#     is NULL until a callback has failed. The export refuses a NULL out-stream
#     and a type outside the subset, with the full message.
#   * A stream with no batches takes its schema from the Fields: format, name,
#     flags (nullable cleared when the Field is not nullable, dictionary-ordered
#     kept), metadata and the dictionary value schema; a nested Field in such a
#     stream fails get_schema with EIO and its text, and the drain reports it.
#     Zero columns, with and without a batch, export and drain.
#   * The drain refuses a root schema that is not a struct, and reports a
#     producer that fails with no error text.
#   * A column with a non-zero logical offset is refused per family (variable
#     length, nested, union) at get_next with EIO; a fixed-width one is exported
#     with its offset and the import refuses it.
#   * Columns of length 0 without an offsets buffer (and a dictionary without
#     value bytes, a dense union without offsets) export a NULL slot and import
#     with the canonical offsets `[0]`.
#   * Export refusals of malformed nested columns (a LIST or MAP without its
#     one child, a MAP whose child is not a STRUCT), top level and nested.
#   * `c_abi_stream_schema` reads the schema without releasing the stream, and
#     reports a failing get_schema, with and without error text.
# =============================================================================

from std.memory import alloc
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.bitmap import Bitmap
from komira_arrow.column import Column
from komira_arrow.schema import Field, RecordBatch, Schema, SchemaBuilder
from komira_arrow.string_array import StringArray
from komira_arrow_ipc.c_data_interface import (
    ARROW_FLAG_DICTIONARY_ORDERED,
    ARROW_FLAG_MAP_KEYS_SORTED,
    ARROW_FLAG_NULLABLE,
    decode_metadata,
)
from komira_arrow_ipc.c_data_stream import (
    CArrowArray,
    CArrowArrayStream,
    CArrowSchema,
    build_record_batch_stream,
    c_abi_stream_schema,
    consumer_release_c_array,
    consumer_release_c_schema,
    consumer_release_c_stream,
    drain_record_batch_stream,
    release_c_array,
    release_c_schema,
    release_c_stream,
    _c_str_to_mojo,
    _copy_string_to_c_int8,
    _alloc_array_ptr_array,
    _alloc_schema_ptr_array,
    _null_ptr,
    _set_array_release,
    _set_schema_release,
    _set_stream_release,
    _stub_get_last_error,
    _stub_get_schema,
)
from komira_buffer.heap_region import HeapRegion
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_collections.slab import Slab

comptime _VP = UnsafePointer[NoneType, MutUntrackedOrigin]
comptime _AP = UnsafePointer[CArrowArray, MutUntrackedOrigin]
comptime _SP = UnsafePointer[CArrowSchema, MutUntrackedOrigin]
comptime _STP = UnsafePointer[CArrowArrayStream, MutUntrackedOrigin]
comptime _CP = UnsafePointer[Int8, MutUntrackedOrigin]


# --- columns -----------------------------------------------------------------


def _bitmap(valid: List[Bool]) -> Optional[Bitmap[HeapRegion]]:
    if len(valid) == 0:
        return None
    var bm = Bitmap.create(len(valid))
    for i in range(len(valid)):
        if valid[i]:
            bm.set(i)
    return bm^


def _nulls(valid: List[Bool]) -> Int:
    var n = 0
    for i in range(len(valid)):
        if not valid[i]:
            n += 1
    return n


def _fixed(
    t: ArrowType, width: Int, values: List[Int], valid: List[Bool] = List[Bool]()
) -> Column[HeapRegion]:
    """`values` little-endian in `width` bytes each, sign-extended past 8."""
    var n = len(values)
    var buf = OwnedAlignedBuffer(max(n * width, 1))
    buf.set_length(Int64(n * width))
    for i in range(n):
        var v = values[i]
        for b in range(width):
            var byte = (v >> (8 * b)) & 0xFF if b < 8 else (0xFF if v < 0 else 0)
            buf.set_typed[UInt8](i * width + b, UInt8(byte))
    return Column[HeapRegion](
        arrow_type=t, data=buf^, offsets=None, validity=_bitmap(valid),
        length=n, null_count=_nulls(valid), offset=0,
    )


def _dec(t: ArrowType, p: Int, s: Int, values: List[Int]) -> Column[HeapRegion]:
    var c = _fixed(t, 16 if t == ArrowType.DECIMAL128 else 32, values)
    c._decimal_p = p
    c._decimal_s = s
    return c^


def _i64(values: List[Int], valid: List[Bool] = List[Bool]()) -> Column[HeapRegion]:
    return _fixed(ArrowType.INT64, 8, values, valid)


def _str(values: List[String]) raises -> Column[HeapRegion]:
    return Column.from_string(StringArray.from_strings(values.copy()))


def _i32_buf(values: List[Int]) -> OwnedAlignedBuffer:
    var b = OwnedAlignedBuffer(max(len(values) * 4, 1))
    b.set_length(Int64(len(values) * 4))
    for i in range(len(values)):
        b.write_i32_le_at(i * 4, Int32(values[i]))
    return b^


def _shell(
    t: ArrowType, n: Int, offsets: List[Int] = List[Int](),
    valid: List[Bool] = List[Bool](), offset: Int = 0,
) -> Column[HeapRegion]:
    """A LIST / STRUCT / MAP (or var-len) column with no children yet."""
    var data = OwnedAlignedBuffer(1)
    data.set_length(0)
    var off = Optional[OwnedAlignedBuffer](None)
    if len(offsets) > 0:
        off = _i32_buf(offsets)
    return Column[HeapRegion](
        arrow_type=t, data=data^, offsets=off^, validity=_bitmap(valid),
        length=n, null_count=_nulls(valid), offset=offset,
    )


def _union(
    t: ArrowType, ids: List[Int], types: List[Int],
    dense_offsets: List[Int] = List[Int](), offset: Int = 0,
) -> Column[HeapRegion]:
    var n = len(types)
    var tb = OwnedAlignedBuffer(max(n, 1))
    tb.set_length(Int64(n))
    for i in range(n):
        tb.set_typed[Int8](i, Int8(types[i]))
    var off = Optional[OwnedAlignedBuffer](None)
    if t == ArrowType.UNION_DENSE:
        off = _i32_buf(dense_offsets)
    var c = Column[HeapRegion](
        arrow_type=t, data=tb^, offsets=off^, validity=None,
        length=n, null_count=0, offset=offset,
    )
    c._type_ids = ids.copy()
    return c^


def _kid(mut parent: Column[HeapRegion], var kid: Column[HeapRegion], name: String):
    parent._children.append(kid^)
    parent._field_names.append(name)


def _kid_unnamed(mut parent: Column[HeapRegion], var kid: Column[HeapRegion]):
    """A child past the end of `_field_names`: the exporter names it `f<i>`."""
    parent._children.append(kid^)


def _entries(keys: List[String], vals: List[Int]) raises -> Column[HeapRegion]:
    var e = _shell(ArrowType.STRUCT, len(keys))
    _kid(e, _str(keys), "key")
    _kid(e, _i64(vals), "value")
    return e^


def _schema(var fields: List[Field]) raises -> Schema:
    var sb = SchemaBuilder()
    for i in range(len(fields)):
        sb.add_field(fields[i].copy())
    return sb.build()


def _batch(var schema: Schema, var cols: List[Column[HeapRegion]], rows: Int) -> RecordBatch:
    var slab = Slab[Column[HeapRegion]].with_capacity(max(len(cols), 1))
    while len(cols) > 0:
        slab.append(cols.pop(0))
    var b = RecordBatch()
    b.schema = schema^
    b._columns = slab^
    b._num_rows = rows
    return b^


# --- the stream --------------------------------------------------------------


def _export(var batches: Slab[RecordBatch], var schema: Schema) raises -> _STP:
    var sp = alloc[CArrowArrayStream](1).unsafe_origin_cast[MutUntrackedOrigin]()
    sp.unsafe_write(CArrowArrayStream())
    build_record_batch_stream(batches^, schema^, sp)
    return sp


def _export1(var batch: RecordBatch) raises -> _STP:
    var schema = batch.schema.copy()
    var bs = Slab[RecordBatch].with_capacity(1)
    bs.append(batch^)
    return _export(bs^, schema^)


def _export0(var schema: Schema) raises -> _STP:
    return _export(Slab[RecordBatch].with_capacity(1), schema^)


def _close(sp: _STP):
    release_c_stream(sp)
    sp.free()


def _sbox() -> _SP:
    var p = alloc[CArrowSchema](1).unsafe_origin_cast[MutUntrackedOrigin]()
    p.unsafe_write(CArrowSchema())
    return p


def _abox() -> _AP:
    var p = alloc[CArrowArray](1).unsafe_origin_cast[MutUntrackedOrigin]()
    p.unsafe_write(CArrowArray())
    return p


def _me(sp: _STP) -> _VP:
    return sp.bitcast[NoneType]()


def _last_error(sp: _STP) -> String:
    return _c_str_to_mojo(sp[].get_last_error(_me(sp)))


def _drain_error(sp: _STP) -> String:
    try:
        _ = drain_record_batch_stream(sp)
    except e:
        return String(e)
    return String("(drained)")


def _drain(sp: _STP) raises -> Slab[RecordBatch]:
    var out = drain_record_batch_stream(sp)
    assert_true(sp[].is_released(), "the drain releases the stream")
    sp.free()
    return out^


def _sch_kid(s: _SP, i: Int) -> _SP:
    return (s[].children + i)[]


def _arr_kid(a: _AP, i: Int) -> _AP:
    return (a[].children + i)[]


def _fmt(s: _SP) -> String:
    return _c_str_to_mojo(s[].format)


def _name(s: _SP) -> String:
    return _c_str_to_mojo(s[].name)


def _slot(f: CArrowArrayStream) -> List[Int]:
    """The three callback addresses of a stream."""
    var gs = f.get_schema
    var gn = f.get_next
    var ge = f.get_last_error
    var out = List[Int]()
    out.append(UnsafePointer(to=gs).bitcast[Int]()[])
    out.append(UnsafePointer(to=gn).bitcast[Int]()[])
    out.append(UnsafePointer(to=ge).bitcast[Int]()[])
    return out^


def _flat_batch() raises -> RecordBatch:
    var cols = List[Column[HeapRegion]]()
    cols.append(_i64([1, 2]))
    return _batch(_schema([Field("a", ArrowType.INT64, False)]), cols^, 2)


# --- released and zeroed structs ---------------------------------------------


def test_zeroed_stream_slots_answer_einval_and_write_nothing() raises:
    var sp = alloc[CArrowArrayStream](1).unsafe_origin_cast[MutUntrackedOrigin]()
    sp.unsafe_write(CArrowArrayStream())
    var sb = _sbox()
    var ab = _abox()
    assert_equal(Int(sp[].get_schema(_me(sp), sb)), 22)
    assert_true(sb[].is_released(), "the stub wrote no schema")
    assert_equal(Int(sp[].get_next(_me(sp), ab)), 22)
    assert_true(ab[].is_released(), "the stub wrote no array")
    assert_equal(Int(sp[].get_last_error(_me(sp))), 0)
    sp.free()
    sb.free()
    ab.free()


def test_released_stream_slots_are_the_stubs() raises:
    # A function's address is per compiled unit (the stubs this test's own
    # `CArrowArrayStream()` names are another copy), so the check compares the
    # library's own addresses: release moves every slot off the exported
    # callback, and two released streams hold the same three addresses.
    var sp = _export1(_flat_batch())
    var sp2 = _export1(_flat_batch())
    var live = _slot(sp[])
    release_c_stream(sp)
    release_c_stream(sp2)
    var after = _slot(sp[])
    var after2 = _slot(sp2[])
    for i in range(3):
        assert_true(after[i] != live[i], "release re-points every slot")
        assert_equal(after[i], after2[i])
    assert_equal(Int(sp[].private_data), 0)
    sp.free()
    sp2.free()


def test_release_helpers_ignore_null_pointers() raises:
    release_c_array(_null_ptr[CArrowArray, MutUntrackedOrigin]())
    release_c_schema(_null_ptr[CArrowSchema, MutUntrackedOrigin]())
    release_c_stream(_null_ptr[CArrowArrayStream, MutUntrackedOrigin]())
    consumer_release_c_array(_null_ptr[CArrowArray, MutUntrackedOrigin]())
    consumer_release_c_schema(_null_ptr[CArrowSchema, MutUntrackedOrigin]())
    consumer_release_c_stream(_null_ptr[CArrowArrayStream, MutUntrackedOrigin]())


def test_release_helpers_leave_a_released_struct_alone() raises:
    # `release == NULL` is the released structure: nothing it points at is
    # ours to free, and there is no callback to call.
    var s = _sbox()
    s[].format = _copy_string_to_c_int8(String("l"))
    release_c_schema(s)
    assert_equal(_fmt(s), String("l"), "the producer release did not free format")
    consumer_release_c_schema(s)
    assert_equal(_fmt(s), String("l"), "the consumer release called nothing")
    s[].format.free()
    s.free()

    var a = _abox()
    a[].n_buffers = 7
    a[].n_children = 3
    release_c_array(a)
    assert_equal(Int(a[].n_buffers), 7, "a released array keeps its fields")
    assert_equal(Int(a[].n_children), 3)
    consumer_release_c_array(a)
    assert_equal(Int(a[].n_buffers), 7)
    a.free()

    var marker = alloc[Int](1).unsafe_origin_cast[MutUntrackedOrigin]()
    var st = alloc[CArrowArrayStream](1).unsafe_origin_cast[MutUntrackedOrigin]()
    st.unsafe_write(CArrowArrayStream())
    st[].private_data = marker.bitcast[NoneType]()
    release_c_stream(st)
    consumer_release_c_stream(st)
    assert_equal(Int(st[].private_data), Int(marker), "a released stream keeps private_data")
    st.free()
    marker.free()


def test_release_frees_a_partially_filled_export() raises:
    # The producer release walks what is there: NULL child slots (an export
    # that stopped part-way), no buffers array, no format.
    var a = _abox()
    a[].n_children = 2
    a[].children = _alloc_array_ptr_array(2)
    a[].n_buffers = 1
    _set_array_release(a[])
    release_c_array(a)
    assert_true(a[].is_released())
    assert_equal(Int(a[].children), 0)
    assert_equal(Int(a[].n_children), 0)
    assert_equal(Int(a[].n_buffers), 0)
    a.free()

    var s = _sbox()
    s[].n_children = 1
    s[].children = _alloc_schema_ptr_array(1)
    _set_schema_release(s[])
    release_c_schema(s)
    assert_true(s[].is_released())
    assert_equal(Int(s[].children), 0)
    assert_equal(Int(s[].n_children), 0)
    s.free()

    # A child count with no children array: nothing to walk.
    var a2 = _abox()
    a2[].n_children = 1
    _set_array_release(a2[])
    release_c_array(a2)
    assert_true(a2[].is_released())
    assert_equal(Int(a2[].n_children), 0)
    a2.free()
    var s2 = _sbox()
    s2[].n_children = 1
    _set_schema_release(s2[])
    release_c_schema(s2)
    assert_true(s2[].is_released())
    assert_equal(Int(s2[].n_children), 0)
    s2.free()


# --- the exported callbacks' argument checks ---------------------------------


def test_exported_callbacks_refuse_null_arguments() raises:
    var sp = _export1(_flat_batch())
    var nul = _null_ptr[NoneType, MutUntrackedOrigin]()
    var sb = _sbox()
    var ab = _abox()
    assert_equal(Int(sp[].get_schema(_me(sp), _null_ptr[CArrowSchema, MutUntrackedOrigin]())), 22)
    assert_equal(Int(sp[].get_schema(nul, sb)), 22)
    assert_true(sb[].is_released())
    assert_equal(Int(sp[].get_next(_me(sp), _null_ptr[CArrowArray, MutUntrackedOrigin]())), 22)
    assert_equal(Int(sp[].get_next(nul, ab)), 22)
    assert_true(ab[].is_released())
    assert_equal(Int(sp[].get_last_error(nul)), 0)
    # No callback has failed yet: get_last_error is NULL.
    assert_equal(Int(sp[].get_last_error(_me(sp))), 0)
    # The stream still delivers its one chunk after the refused calls.
    assert_equal(Int(sp[].get_next(_me(sp), ab)), 0)
    assert_equal(Int(ab[].length), 2)
    release_c_array(ab)
    _close(sp)
    sb.free()
    ab.free()


def test_exported_callbacks_refuse_a_stream_without_state() raises:
    var sp = _export1(_flat_batch())
    var det = alloc[CArrowArrayStream](1).unsafe_origin_cast[MutUntrackedOrigin]()
    det.unsafe_write(CArrowArrayStream())
    det[].get_schema = sp[].get_schema
    det[].get_next = sp[].get_next
    det[].get_last_error = sp[].get_last_error
    var sb = _sbox()
    var ab = _abox()
    assert_equal(Int(det[].get_schema(_me(det), sb)), 22)
    assert_true(sb[].is_released())
    assert_equal(Int(det[].get_next(_me(det), ab)), 22)
    assert_true(ab[].is_released())
    assert_equal(Int(det[].get_last_error(_me(det))), 0)
    det.free()
    _close(sp)
    sb.free()
    ab.free()


def test_build_refuses_a_null_out_stream() raises:
    var schema = _schema([Field("a", ArrowType.INT64, False)])
    var msg = String("")
    try:
        build_record_batch_stream(
            Slab[RecordBatch].with_capacity(1), schema^,
            _null_ptr[CArrowArrayStream, MutUntrackedOrigin](),
        )
    except e:
        msg = String(e)
    assert_equal(msg, String("build_record_batch_stream: out_stream is NULL"))


def test_build_refuses_a_type_outside_the_subset() raises:
    var sp = alloc[CArrowArrayStream](1).unsafe_origin_cast[MutUntrackedOrigin]()
    sp.unsafe_write(CArrowArrayStream())
    var schema = _schema([
        Field("a", ArrowType.INT64, False),
        Field("b", ArrowType.FIXED_SIZE_BINARY, False),
    ])
    var msg = String("")
    try:
        build_record_batch_stream(Slab[RecordBatch].with_capacity(1), schema^, sp)
    except e:
        msg = String(e)
    assert_equal(
        msg,
        String(
            "UnsupportedArrowCABIType: Arrow type 'fixed_size_binary' is not in"
            " the supported Arrow C Data Interface subset (export). Supported:"
            " Int*/UInt*/Float*/Bool/Date32/Date64/Timestamp/Decimal128/"
            "Decimal256/Time32/Time64/Duration/Interval (YearMonth, DayTime)/"
            "String/Binary/LargeString/LargeBinary/Dictionary/List/Struct/Map/"
            "Union (sparse, dense).  Extension types are passed-through as"
            " metadata; Run-End-Encoded (REE), Float16 SIMD compute, and"
            " Decimal256 arith are not supported."
        ),
    )
    assert_true(sp[].is_released(), "a refused export leaves the stream released")
    sp.free()


# --- streams with no batches ---------------------------------------------------


def test_empty_stream_schema_comes_from_the_fields() raises:
    var fid = Field("id", ArrowType.INT64, False)
    fid.set_flag(ARROW_FLAG_NULLABLE, True)  # contradicts nullable=False
    fid.set_metadata("k", "v")
    var tag = Field.dictionary("tag", ArrowType.INT16, True)
    tag.set_flag(ARROW_FLAG_DICTIONARY_ORDERED, True)
    var dec = Field.decimal128("d", 10, 2, True)
    var sp = _export0(_schema([fid^, tag^, dec^]))

    var sb = _sbox()
    assert_equal(Int(sp[].get_schema(_me(sp), sb)), 0)
    assert_equal(_fmt(sb), String("+s"))
    assert_equal(_name(sb), String(""))
    assert_equal(Int(sb[].flags), 0)
    assert_equal(Int(sb[].n_children), 3)

    var c0 = _sch_kid(sb, 0)
    assert_equal(_fmt(c0), String("l"))
    assert_equal(_name(c0), String("id"))
    assert_equal(Int(c0[].flags), 0, "nullable=False clears the nullable bit")
    assert_equal(Int(c0[].dictionary), 0)
    var kv = decode_metadata(c0[].metadata)
    assert_equal(len(kv[0]), 1)
    assert_equal(kv[0][0], String("k"))
    assert_equal(kv[1][0], String("v"))

    var c1 = _sch_kid(sb, 1)
    assert_equal(_fmt(c1), String("s"), "the parent format is the index type")
    assert_equal(Int(c1[].flags), Int(ARROW_FLAG_DICTIONARY_ORDERED | ARROW_FLAG_NULLABLE))
    assert_equal(Int(c1[].metadata), 0)
    var dv = c1[].dictionary
    assert_equal(_fmt(dv), String("u"))
    assert_equal(_name(dv), String(""))
    assert_equal(Int(dv[].flags), Int(ARROW_FLAG_NULLABLE))
    assert_equal(Int(dv[].n_children), 0)

    var c2 = _sch_kid(sb, 2)
    assert_equal(_fmt(c2), String("d:10,2"))
    assert_equal(Int(c2[].flags), Int(ARROW_FLAG_NULLABLE))
    release_c_schema(sb)
    assert_true(sb[].is_released())
    sb.free()

    var ab = _abox()
    assert_equal(Int(sp[].get_next(_me(sp), ab)), 0)
    assert_true(ab[].is_released(), "no batch: the first get_next is end of stream")
    ab.free()
    var out = _drain(sp)
    assert_equal(len(out), 0)


def test_zero_column_streams() raises:
    # No field, no batch.
    var sp = _export0(_schema(List[Field]()))
    var sb = _sbox()
    assert_equal(Int(sp[].get_schema(_me(sp), sb)), 0)
    assert_equal(Int(sb[].n_children), 0)
    assert_equal(Int(sb[].children), 0)
    release_c_schema(sb)
    assert_equal(len(_drain(sp)), 0)

    # No field, one batch of two rows.
    var sp2 = _export1(_batch(_schema(List[Field]()), List[Column[HeapRegion]](), 2))
    assert_equal(Int(sp2[].get_schema(_me(sp2), sb)), 0)
    assert_equal(Int(sb[].n_children), 0)
    release_c_schema(sb)
    var ab = _abox()
    assert_equal(Int(sp2[].get_next(_me(sp2), ab)), 0)
    assert_equal(Int(ab[].length), 2)
    assert_equal(Int(ab[].n_children), 0)
    assert_equal(Int(ab[].children), 0)
    assert_equal(Int(ab[].n_buffers), 1)
    release_c_array(ab)
    _close(sp2)
    var sp3 = _export1(_batch(_schema(List[Field]()), List[Column[HeapRegion]](), 2))
    var out = _drain(sp3)
    assert_equal(len(out), 1)
    assert_equal(out[0].num_columns(), 0)
    assert_equal(out[0].num_rows(), 2)
    sb.free()
    ab.free()


def test_empty_stream_with_a_nested_field_fails_get_schema() raises:
    var kinds = [
        ArrowType.LIST, ArrowType.STRUCT, ArrowType.MAP,
        ArrowType.UNION_SPARSE, ArrowType.UNION_DENSE,
    ]
    var text = String(
        "ArrowCStream: empty stream with nested column 'n' — cannot synthesize"
        " child schema without a sample RecordBatch (child types are not"
        " derived from Field._child_types)."
    )
    for k in range(len(kinds)):
        var schema = _schema([
            Field("a", ArrowType.INT64, False), Field("n", kinds[k], True)
        ])
        var sp = _export0(schema.copy())
        var sb = _sbox()
        assert_equal(Int(sp[].get_schema(_me(sp), sb)), 5, "EIO")
        assert_true(sb[].is_released(), "a failed get_schema writes no schema")
        assert_equal(_last_error(sp), text)
        sb.free()
        assert_equal(
            _drain_error(sp),
            String("from_arrow_c_stream: get_schema failed (rc=5): ") + text,
        )
        assert_true(sp[].is_released(), "the failed drain still releases the stream")
        sp.free()


def _int_root_get_schema(stream: _VP, out_schema: _SP) abi("C") -> Int32:
    """A producer whose root schema is `i`, not the struct `+s`."""
    _ = stream
    var s = CArrowSchema()
    s.format = _copy_string_to_c_int8(String("i"))
    _set_schema_release(s)
    out_schema.unsafe_write(s^)
    return Int32(0)


def test_drain_refuses_a_root_that_is_not_a_struct() raises:
    var sp = _export1(_flat_batch())
    sp[].get_schema = _int_root_get_schema
    assert_equal(
        _drain_error(sp),
        String("from_arrow_c_stream: top-level ArrowSchema must be a struct ('+s'), got 'i'"),
    )
    assert_true(sp[].is_released())
    sp.free()


def test_drain_of_a_failing_stream_without_error_text() raises:
    var sp = alloc[CArrowArrayStream](1).unsafe_origin_cast[MutUntrackedOrigin]()
    sp.unsafe_write(CArrowArrayStream())
    _set_stream_release(sp[])
    assert_equal(
        _drain_error(sp),
        String("from_arrow_c_stream: get_schema failed (rc=22): (no error text)"),
    )
    assert_true(sp[].is_released())
    sp.free()


def test_c_abi_stream_schema_reads_without_releasing() raises:
    var sp = _export1(_flat_batch())
    var s = c_abi_stream_schema(_me(sp), sp[].get_schema, sp[].get_last_error)
    assert_equal(s.num_columns(), 1)
    assert_equal(s.field_name(0), String("a"))
    assert_true(s.field_arrow_type(0) == ArrowType.INT64)
    assert_false(sp[].is_released(), "c_abi_stream_schema does not release")
    _close(sp)

    var bad = _export0(_schema([Field("n", ArrowType.LIST, True)]))
    var msg = String("")
    try:
        _ = c_abi_stream_schema(_me(bad), bad[].get_schema, bad[].get_last_error)
    except e:
        msg = String(e)
    assert_true(
        msg.startswith("c_abi_scan_stream: get_schema failed (rc=5): ArrowCStream: empty stream with nested column 'n'"),
        msg,
    )
    assert_false(bad[].is_released())
    _close(bad)

    var odd = _export1(_flat_batch())
    msg = String("")
    try:
        _ = c_abi_stream_schema(_me(odd), _int_root_get_schema, odd[].get_last_error)
    except e:
        msg = String(e)
    assert_equal(msg, String("from_arrow_c_stream: top-level ArrowSchema must be a struct ('+s'), got 'i'"))
    _close(odd)

    # A failing producer with no error text: the zeroed stream's stubs.
    msg = String("")
    try:
        _ = c_abi_stream_schema(
            _null_ptr[NoneType, MutUntrackedOrigin](), _stub_get_schema, _stub_get_last_error
        )
    except e:
        msg = String(e)
    assert_equal(msg, String("c_abi_scan_stream: get_schema failed (rc=22): (no error text)"))


# --- a logical offset ---------------------------------------------------------


def _sliced(t: ArrowType) -> Column[HeapRegion]:
    if t == ArrowType.UNION_SPARSE or t == ArrowType.UNION_DENSE:
        return _union(t, [0], [0, 0], [0, 0], offset=1)
    return _shell(t, 1, [0, 0, 0], offset=1)


def test_get_next_refuses_a_logical_offset_per_family() raises:
    var kinds = [
        ArrowType.STRING, ArrowType.BINARY, ArrowType.LARGE_STRING, ArrowType.LARGE_BINARY,
        ArrowType.LIST, ArrowType.STRUCT, ArrowType.MAP,
        ArrowType.UNION_SPARSE, ArrowType.UNION_DENSE,
    ]
    var family = List[String]()
    for _ in range(4):
        family.append(String("variable-length"))
    for _ in range(3):
        family.append(String("nested"))
    for _ in range(2):
        family.append(String("union"))
    for k in range(len(kinds)):
        var cols = List[Column[HeapRegion]]()
        cols.append(_i64([1]))
        cols.append(_sliced(kinds[k]))
        var schema = _schema([Field("a", ArrowType.INT64, False), Field("s", kinds[k], True)])
        var text = (
            String("UnsupportedArrowCABIType: ") + family[k]
            + " Column[HeapRegion] with non-zero logical offset (type="
            + String(kinds[k]) + ", offset=1) — not supported"
        )
        var sp = _export1(_batch(schema.copy(), cols^, 1))
        var ab = _abox()
        assert_equal(Int(sp[].get_next(_me(sp), ab)), 5, "EIO")
        assert_true(ab[].is_released(), "a failed get_next writes no array")
        assert_equal(_last_error(sp), text)
        # The cursor did not move: the same chunk fails again.
        assert_equal(Int(sp[].get_next(_me(sp), ab)), 5)
        ab.free()
        _close(sp)
        if k == 0:
            var cols2 = List[Column[HeapRegion]]()
            cols2.append(_i64([1]))
            cols2.append(_sliced(kinds[k]))
            var sp2 = _export1(_batch(schema.copy(), cols2^, 1))
            assert_equal(
                _drain_error(sp2),
                String("from_arrow_c_stream: get_next failed (rc=5): ") + text,
            )
            assert_true(sp2[].is_released())
            sp2.free()


def test_a_sliced_fixed_width_column_exports_its_offset() raises:
    var c = _i64([7, 8, 9])
    c._offset = 1
    c._length = 2
    var cols = List[Column[HeapRegion]]()
    cols.append(c^)
    var schema = _schema([Field("a", ArrowType.INT64, False)])
    var sp = _export1(_batch(schema.copy(), cols^, 2))
    var ab = _abox()
    assert_equal(Int(sp[].get_next(_me(sp), ab)), 0)
    var kid = _arr_kid(ab, 0)
    assert_equal(Int(kid[].offset), 1)
    assert_equal(Int(kid[].length), 2)
    release_c_array(ab)
    ab.free()
    _close(sp)
    # The import side refuses a non-zero offset rather than re-basing it.
    var c2 = _i64([7, 8, 9])
    c2._offset = 1
    c2._length = 2
    var cols2 = List[Column[HeapRegion]]()
    cols2.append(c2^)
    var sp2 = _export1(_batch(schema^, cols2^, 2))
    assert_equal(
        _drain_error(sp2),
        String("from_arrow_c_stream: child array with non-zero offset (1) — not supported"),
    )
    sp2.free()


def _dense_without_offsets() -> Column[HeapRegion]:
    var u = _union(ArrowType.UNION_SPARSE, List[Int](), List[Int]())
    u.arrow_type = ArrowType.UNION_DENSE
    return u^


def test_export_of_columns_without_offsets() raises:
    # Columns of length 0 that hold no offsets buffer (and a dictionary with no
    # value bytes): the exported slot is NULL, which the spec allows for a
    # buffer of size 0, and the import writes the canonical offsets `[0]`.
    var fields = List[Field]()
    var cols = List[Column[HeapRegion]]()
    fields.append(Field("s", ArrowType.STRING, True))
    cols.append(_shell(ArrowType.STRING, 0))
    fields.append(Field("l", ArrowType.LIST, True))
    var l = _shell(ArrowType.LIST, 0)
    _kid(l, _i64(List[Int]()), "item")
    cols.append(l^)
    fields.append(Field.dictionary("d", ArrowType.INT32, True))
    cols.append(_shell(ArrowType.DICTIONARY, 0))
    fields.append(Field.dictionary("e", ArrowType.INT32, True))
    cols.append(_shell(ArrowType.DICTIONARY, 0, [0]))
    fields.append(Field.union("u", ArrowType.UNION_DENSE, List[Int](), True))
    cols.append(_dense_without_offsets())
    var schema = _schema(fields^)
    var sp = _export1(_batch(schema.copy(), cols^, 0))
    var ab = _abox()
    assert_equal(Int(sp[].get_next(_me(sp), ab)), 0)
    assert_equal(Int((_arr_kid(ab, 0)[].buffers + 1)[]), 0, "string offsets NULL")
    assert_equal(Int((_arr_kid(ab, 1)[].buffers + 1)[]), 0, "list offsets NULL")
    var dv = _arr_kid(ab, 2)[].dictionary
    assert_equal(Int((dv[].buffers + 1)[]), 0, "dictionary value offsets NULL")
    assert_equal(Int((dv[].buffers + 2)[]), 0, "dictionary value bytes NULL")
    var ev = _arr_kid(ab, 3)[].dictionary
    assert_true(Int((ev[].buffers + 1)[]) != 0, "dictionary value offsets [0]")
    assert_equal(Int((_arr_kid(ab, 4)[].buffers + 1)[]), 0, "dense union offsets NULL")
    release_c_array(ab)
    ab.free()
    _close(sp)

    var cols2 = List[Column[HeapRegion]]()
    cols2.append(_shell(ArrowType.STRING, 0))
    var l2 = _shell(ArrowType.LIST, 0)
    _kid(l2, _i64(List[Int]()), "item")
    cols2.append(l2^)
    cols2.append(_shell(ArrowType.DICTIONARY, 0))
    cols2.append(_shell(ArrowType.DICTIONARY, 0, [0]))
    cols2.append(_dense_without_offsets())
    var out = _drain(_export1(_batch(schema^, cols2^, 0)))
    ref b = out[0]
    for i in range(4):
        assert_equal(Int(b.column_at(i)._offsets.value().read_i32_le_at(0)), 0)
    assert_equal(b.column_at(2)._dict_size, 0)
    assert_equal(b.column_at(3)._dict_size, 0)
    assert_equal(b.column_at(4)._offsets.value().len(), 0)


# --- malformed nested columns ---------------------------------------------------


def _export_error(var col: Column[HeapRegion], t: ArrowType, nested: Bool) raises -> String:
    """get_schema's error text for `col`, at the top level or as a STRUCT child."""
    var cols = List[Column[HeapRegion]]()
    var schema: Schema
    if nested:
        var s = _shell(ArrowType.STRUCT, 0)
        _kid(s, col^, "c")
        cols.append(s^)
        schema = _schema([Field("s", ArrowType.STRUCT, True)])
    else:
        cols.append(col^)
        schema = _schema([Field("c", t, True)])
    var sp = _export1(_batch(schema^, cols^, 0))
    var sb = _sbox()
    var rc = Int(sp[].get_schema(_me(sp), sb))
    var text = _last_error(sp)
    sb.free()
    _close(sp)
    assert_equal(rc, 5, "EIO")
    return text


def test_export_refuses_malformed_nested_columns() raises:
    for n in range(2):
        var nested = n == 1
        assert_equal(
            _export_error(_shell(ArrowType.LIST, 0, [0]), ArrowType.LIST, nested),
            String("ArrowCStream(export): LIST column must have 1 child, got 0"),
        )
        assert_equal(
            _export_error(_shell(ArrowType.MAP, 0, [0]), ArrowType.MAP, nested),
            String("ArrowCStream(export): MAP column must have 1 entries child, got 0"),
        )
        var m = _shell(ArrowType.MAP, 0, [0])
        _kid(m, _i64(List[Int]()), "entries")
        assert_equal(
            _export_error(m^, ArrowType.MAP, nested),
            String("ArrowCStream(export): MAP entries child must be STRUCT, got int64"),
        )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
