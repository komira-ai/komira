# =============================================================================
# FFI-BOUNDARY: a consumer of the Arrow C Stream Interface structs this
# library exports. The stream and schema boxes are allocated here with
# `alloc` and freed here; the exported schema is freed by its own release
# callback (`release_c_schema`) and the stream by the drain's release call.
#
# Arrow C Stream Interface: nested columns through export and import.
#
# Spec: https://arrow.apache.org/docs/format/CDataInterface.html (format
# strings `+l`, `+s`, `+m`, `+us:I,J,...`, `+ud:I,J,...`, `d:P,S[,256]`; the
# MAP_KEYS_SORTED flag) and the columnar format's nested layouts. One batch
# carries every nested shape the exporter writes, at the top level (the
# Field-and-Column path) and as a STRUCT child (the Column-only path):
#
#   * LIST: a child name from the column, an empty one and none (both give
#     `item`); a nullable list; INT64, INT8, Decimal128 and Decimal256 items.
#   * STRUCT: children named, named "" and past the end of the names (both
#     give `f<i>`), a struct with no children.
#   * MAP: keys sorted and not, the `entries` struct with `key` and `value`.
#   * UNION: sparse and dense, declared type ids, children named three ways,
#     Decimal128 and Decimal256 children.
#   * Decimal (precision, scale) carried by the column, or the defaults
#     (38,18 for 128 bits, 76,0 for 256) when it carries none.
#
# The exported schema is read through get_schema (format, name, flags,
# children), then the stream is drained and every offset, null bit, value,
# child name, type id and (precision, scale) is checked on the import side.
# A second stream of zero rows covers the shapes that hold no child at all.
# =============================================================================

from std.memory import alloc
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.bitmap import Bitmap
from komira_arrow.column import Column
from komira_arrow.schema import Field, RecordBatch, Schema, SchemaBuilder
from komira_arrow.string_array import StringArray
from komira_arrow_ipc.c_data_interface import ARROW_FLAG_MAP_KEYS_SORTED, ARROW_FLAG_NULLABLE
from komira_arrow_ipc.c_data_stream import (
    CArrowArrayStream,
    CArrowSchema,
    build_record_batch_stream,
    drain_record_batch_stream,
    release_c_schema,
    _c_str_to_mojo,
)
from komira_buffer.heap_region import HeapRegion
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_collections.slab import Slab

comptime _SP = UnsafePointer[CArrowSchema, MutUntrackedOrigin]
comptime _STP = UnsafePointer[CArrowArrayStream, MutUntrackedOrigin]
comptime _D128 = ArrowType.DECIMAL128
comptime _D256 = ArrowType.DECIMAL256


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
    var c = _fixed(t, 16 if t == _D128 else 32, values)
    c._decimal_p = p
    c._decimal_s = s
    return c^


def _i64(values: List[Int]) -> Column[HeapRegion]:
    return _fixed(ArrowType.INT64, 8, values)


def _str(values: List[String]) raises -> Column[HeapRegion]:
    return Column.from_string(StringArray.from_strings(values.copy()))


def _i32_buf(values: List[Int]) -> OwnedAlignedBuffer:
    var b = OwnedAlignedBuffer(max(len(values) * 4, 1))
    b.set_length(Int64(len(values) * 4))
    for i in range(len(values)):
        b.write_i32_le_at(i * 4, Int32(values[i]))
    return b^


def _shell(
    t: ArrowType, n: Int, offsets: List[Int] = List[Int](), valid: List[Bool] = List[Bool]()
) -> Column[HeapRegion]:
    var data = OwnedAlignedBuffer(1)
    data.set_length(0)
    var off = Optional[OwnedAlignedBuffer](None)
    if len(offsets) > 0:
        off = _i32_buf(offsets)
    return Column[HeapRegion](
        arrow_type=t, data=data^, offsets=off^, validity=_bitmap(valid),
        length=n, null_count=_nulls(valid), offset=0,
    )


def _union(
    t: ArrowType, ids: List[Int], types: List[Int], dense_offsets: List[Int] = List[Int]()
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
        arrow_type=t, data=tb^, offsets=off^, validity=None, length=n, null_count=0, offset=0,
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


def _map(n: Int, offsets: List[Int], keys: List[String], vals: List[Int], sorted: Bool,
         valid: List[Bool] = List[Bool]()) raises -> Column[HeapRegion]:
    var m = _shell(ArrowType.MAP, n, offsets, valid)
    _kid(m, _entries(keys, vals), "entries")
    m._keys_sorted = sorted
    return m^


def _list(n: Int, offsets: List[Int], var item: Column[HeapRegion], names: List[String],
          valid: List[Bool] = List[Bool]()) -> Column[HeapRegion]:
    var l = _shell(ArrowType.LIST, n, offsets, valid)
    l._children.append(item^)
    l._field_names = names.copy()
    return l^


# --- the stream --------------------------------------------------------------


def _stream(var fields: List[Field], var cols: List[Column[HeapRegion]], rows: Int) raises -> _STP:
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


def _get_schema(sp: _STP) raises -> _SP:
    var sb = alloc[CArrowSchema](1).unsafe_origin_cast[MutUntrackedOrigin]()
    sb.unsafe_write(CArrowSchema())
    assert_equal(Int(sp[].get_schema(sp.bitcast[NoneType](), sb)), 0, "get_schema")
    return sb


def _k(s: _SP, i: Int) -> _SP:
    return (s[].children + i)[]


def _check(s: _SP, fmt: String, name: String, flags: Int, n_children: Int) raises:
    assert_equal(_c_str_to_mojo(s[].format), fmt, name)
    assert_equal(_c_str_to_mojo(s[].name), name)
    assert_equal(Int(s[].flags), flags, name)
    assert_equal(Int(s[].n_children), n_children, name)


def _i64_at(c: Column[HeapRegion], i: Int) -> Int:
    return Int(c._data.read_i64_le_at(i * 8))


def _off_at(c: Column[HeapRegion], i: Int) -> Int:
    return Int(c._offsets.value().read_i32_le_at(i * 4))


def _assert_offsets(c: Column[HeapRegion], want: List[Int], what: String) raises:
    for i in range(len(want)):
        assert_equal(_off_at(c, i), want[i], what)


def _assert_dec(c: Column[HeapRegion], t: ArrowType, p: Int, s: Int, first: Int, what: String) raises:
    assert_true(c.arrow_type == t, what)
    assert_equal(c.decimal_precision(), p, what)
    assert_equal(c.decimal_scale(), s, what)
    assert_equal(_i64_at(c, 0), first, what)


# --- the batch ---------------------------------------------------------------

comptime _N = 3
comptime _F = Int(ARROW_FLAG_NULLABLE)
comptime _SORTED = Int(ARROW_FLAG_MAP_KEYS_SORTED)


def _nested_struct() raises -> Column[HeapRegion]:
    var s = _shell(ArrowType.STRUCT, _N)
    _kid(s, _dec(_D128, 10, 2, [1, 2, 3]), "x")
    _kid(s, _dec(_D256, 0, 0, [4, 5, 6]), "")
    _kid(s, _map(_N, [0, 1, 1, 2], ["a", "b"], [1, 2], True), "ms")
    _kid(s, _list(_N, [0, 1, 2, 3], _fixed(ArrowType.INT8, 1, [1, -2, 3]), List[String]()), "li")
    _kid(s, _list(_N, [0, 0, 1, 1], _dec(_D128, 0, 0, [7]), ["v"]), "lv")
    _kid(s, _list(_N, [0, 0, 0, 0], _i64(List[Int]()), [""]), "lz")
    var u = _union(ArrowType.UNION_SPARSE, [0, 1, 2], [0, 1, 2])
    _kid(u, _fixed(ArrowType.INT32, 4, [1, 2, 3]), "i")
    _kid(u, _dec(_D128, 12, 3, [8, 9, 10]), "")
    _kid_unnamed(u, _i64([4, 5, 6]))
    _kid(s, u^, "u")
    var st = _shell(ArrowType.STRUCT, _N)
    _kid(st, _i64([1, 2, 3]), "p")
    _kid(st, _i64([4, 5, 6]), "")
    _kid_unnamed(st, _i64([7, 8, 9]))
    _kid(s, st^, "st")
    _kid(s, _shell(ArrowType.STRUCT, _N), "e")
    _kid(s, _map(_N, [0, 0, 0, 0], List[String](), List[Int](), False), "mu")
    _kid_unnamed(s, _i64([0, 0, 0]))
    return s^


def _batch_stream() raises -> _STP:
    var fields = List[Field]()
    var cols = List[Column[HeapRegion]]()
    fields.append(Field("l", ArrowType.LIST, True))
    cols.append(_list(_N, [0, 2, 2, 3], _i64([10, 20, 30]), ["elem"], [True, False, True]))
    fields.append(Field("l2", ArrowType.LIST, False))
    cols.append(_list(_N, [0, 1, 1, 1], _i64([5]), List[String]()))
    fields.append(Field("l3", ArrowType.LIST, True))
    cols.append(_list(_N, [0, 0, 0, 1], _dec(_D256, 40, 3, [6]), [""]))
    fields.append(Field("s", ArrowType.STRUCT, False))
    cols.append(_nested_struct())
    fields.append(Field("m", ArrowType.MAP, True))
    cols.append(_map(_N, [0, 2, 2, 2], ["k1", "k2"], [1, 2], True, [True, True, False]))
    fields.append(Field("m2", ArrowType.MAP, False))
    cols.append(_map(_N, [0, 1, 1, 1], ["z"], [9], False))
    fields.append(Field.union("us", ArrowType.UNION_SPARSE, [5, 7, 9], True))
    var us = _union(ArrowType.UNION_SPARSE, [5, 7, 9], [5, 7, 9])
    _kid(us, _i64([1, 2, 3]), "a")
    _kid(us, _dec(_D128, 9, 1, [4, 5, 6]), "")
    _kid_unnamed(us, _dec(_D256, 0, 0, [7, 8, 9]))
    cols.append(us^)
    fields.append(Field.union("ud", ArrowType.UNION_DENSE, [0, 1], True))
    var ud = _union(ArrowType.UNION_DENSE, [0, 1], [0, 1, 0], [0, 0, 1])
    _kid(ud, _str(["x", "y"]), "s")
    _kid(ud, _fixed(ArrowType.INT32, 4, [42]), "n")
    cols.append(ud^)
    fields.append(Field("n8", ArrowType.INT8, True))
    cols.append(_fixed(ArrowType.INT8, 1, [1, 0, -3], [True, False, True]))
    fields.append(Field("iv", ArrowType.INTERVAL_MONTH_DAY_NANO, False))
    cols.append(_fixed(ArrowType.INTERVAL_MONTH_DAY_NANO, 16, [11, 12, 13]))
    return _stream(fields^, cols^, _N)


# --- tests -------------------------------------------------------------------


def test_nested_export_schema() raises:
    var sp = _batch_stream()
    var r = _get_schema(sp)
    _check(r, "+s", "", 0, 10)
    var l = _k(r, 0)
    _check(l, "+l", "l", _F, 1)
    _check(_k(l, 0), "l", "elem", _F, 0)
    _check(_k(_k(r, 1), 0), "l", "item", _F, 0)
    _check(_k(r, 1), "+l", "l2", 0, 1)
    _check(_k(_k(r, 2), 0), "d:40,3,256", "item", _F, 0)

    var s = _k(r, 3)
    _check(s, "+s", "s", 0, 11)
    _check(_k(s, 0), "d:10,2", "x", _F, 0)
    _check(_k(s, 1), "d:76,0,256", "f1", _F, 0)
    var ms = _k(s, 2)
    _check(ms, "+m", "ms", _F | _SORTED, 1)
    var ent = _k(ms, 0)
    _check(ent, "+s", "entries", 0, 2)
    _check(_k(ent, 0), "u", "key", _F, 0)
    _check(_k(ent, 1), "l", "value", _F, 0)
    _check(_k(s, 3), "+l", "li", _F, 1)
    _check(_k(_k(s, 3), 0), "c", "item", _F, 0)
    _check(_k(_k(s, 4), 0), "d:38,18", "v", _F, 0)
    _check(_k(_k(s, 5), 0), "l", "item", _F, 0)
    var u = _k(s, 6)
    _check(u, "+us:0,1,2", "u", _F, 3)
    _check(_k(u, 0), "i", "i", _F, 0)
    _check(_k(u, 1), "d:12,3", "f1", _F, 0)
    _check(_k(u, 2), "l", "f2", _F, 0)
    var st = _k(s, 7)
    _check(st, "+s", "st", _F, 3)
    _check(_k(st, 0), "l", "p", _F, 0)
    _check(_k(st, 1), "l", "f1", _F, 0)
    _check(_k(st, 2), "l", "f2", _F, 0)
    _check(_k(s, 8), "+s", "e", _F, 0)
    assert_equal(Int(_k(s, 8)[].children), 0)
    _check(_k(s, 9), "+m", "mu", _F, 1)
    _check(_k(s, 10), "l", "f10", _F, 0)

    _check(_k(r, 4), "+m", "m", _F | _SORTED, 1)
    _check(_k(_k(r, 4), 0), "+s", "entries", 0, 2)
    _check(_k(r, 5), "+m", "m2", 0, 1)
    var us = _k(r, 6)
    _check(us, "+us:5,7,9", "us", _F, 3)
    _check(_k(us, 0), "l", "a", _F, 0)
    _check(_k(us, 1), "d:9,1", "f1", _F, 0)
    _check(_k(us, 2), "d:76,0,256", "f2", _F, 0)
    var ud = _k(r, 7)
    _check(ud, "+ud:0,1", "ud", _F, 2)
    _check(_k(ud, 0), "u", "s", _F, 0)
    _check(_k(ud, 1), "i", "n", _F, 0)
    _check(_k(r, 8), "c", "n8", _F, 0)
    _check(_k(r, 9), "tin", "iv", 0, 0)
    release_c_schema(r)
    r.free()
    _ = drain_record_batch_stream(sp)
    sp.free()


def test_nested_round_trip_values() raises:
    var sp = _batch_stream()
    var out = drain_record_batch_stream(sp)
    assert_true(sp[].is_released())
    sp.free()
    assert_equal(len(out), 1)
    ref b = out[0]
    assert_equal(b.num_rows(), _N)
    assert_equal(b.num_columns(), 10)

    ref l = b.column_at(0)
    assert_true(l.arrow_type == ArrowType.LIST)
    assert_equal(l.null_count(), 1)
    assert_false(l.is_null_at(0))
    assert_true(l.is_null_at(1))
    _assert_offsets(l, [0, 2, 2, 3], "l offsets")
    assert_equal(l.field_name(0), String("elem"))
    assert_equal(_i64_at(l.child_at(0), 2), 30)
    assert_equal(b.column_at(1).field_name(0), String("item"))
    ref l3 = b.column_at(2)
    assert_equal(l3.field_name(0), String("item"))
    _assert_dec(l3.child_at(0), _D256, 40, 3, 6, "l3 item")

    ref s = b.column_at(3)
    assert_true(s.arrow_type == ArrowType.STRUCT)
    assert_equal(s.num_children(), 11)
    var names: List[String] = ["x", "f1", "ms", "li", "lv", "lz", "u", "st", "e", "mu", "f10"]
    for i in range(len(names)):
        assert_equal(s.field_name(i), names[i])
    _assert_dec(s.child_at(0), _D128, 10, 2, 1, "s.x")
    _assert_dec(s.child_at(1), _D256, 76, 0, 4, "s.f1")
    ref ms = s.child_at(2)
    assert_true(ms.arrow_type == ArrowType.MAP)
    _assert_offsets(ms, [0, 1, 1, 2], "s.ms offsets")
    assert_equal(ms.child_at(0).child_at(0).utf8_value_at(1), String("b"))
    ref li = s.child_at(3)
    assert_true(li.child_at(0).arrow_type == ArrowType.INT8)
    assert_equal(Int(li.child_at(0)._data.read_u8_at(1)), 0xFE)
    assert_equal(s.child_at(4).field_name(0), String("v"))
    _assert_dec(s.child_at(4).child_at(0), _D128, 38, 18, 7, "s.lv item")
    assert_equal(s.child_at(5).child_at(0).length(), 0)
    ref u = s.child_at(6)
    assert_true(u.arrow_type == ArrowType.UNION_SPARSE)
    assert_equal(len(u.type_ids()), 3)
    for i in range(3):
        assert_equal(u.type_ids()[i], i)
        assert_equal(Int(u._data.read_u8_at(i)), i)
    assert_equal(u.field_name(0), String("i"))
    assert_equal(u.field_name(1), String("f1"))
    assert_equal(u.field_name(2), String("f2"))
    _assert_dec(u.child_at(1), _D128, 12, 3, 8, "s.u.f1")
    ref st = s.child_at(7)
    assert_equal(st.field_name(1), String("f1"))
    assert_equal(st.field_name(2), String("f2"))
    assert_equal(_i64_at(st.child_at(2), 2), 9)
    assert_equal(s.child_at(8).num_children(), 0)
    assert_equal(s.child_at(8).length(), _N)
    _assert_offsets(s.child_at(9), [0, 0, 0, 0], "s.mu offsets")
    assert_equal(_i64_at(s.child_at(10), 0), 0)

    ref m = b.column_at(4)
    assert_true(m.arrow_type == ArrowType.MAP)
    assert_true(m.keys_sorted(), "MAP_KEYS_SORTED on the top-level schema")
    assert_true(m.is_null_at(2))
    _assert_offsets(m, [0, 2, 2, 2], "m offsets")
    assert_equal(m.field_name(0), String("entries"))
    ref ent = m.child_at(0)
    assert_equal(ent.field_name(0), String("key"))
    assert_equal(ent.field_name(1), String("value"))
    assert_equal(ent.child_at(0).utf8_value_at(0), String("k1"))
    assert_equal(_i64_at(ent.child_at(1), 1), 2)
    assert_false(b.column_at(5).keys_sorted())
    assert_true(b.schema.field_at(4).are_map_keys_sorted())
    assert_false(b.schema.field_at(5).are_map_keys_sorted())

    ref us = b.column_at(6)
    assert_true(us.arrow_type == ArrowType.UNION_SPARSE)
    var ids = [5, 7, 9]
    for i in range(3):
        assert_equal(us.type_ids()[i], ids[i])
        assert_equal(Int(us._data.read_u8_at(i)), ids[i])
    assert_equal(us.field_name(1), String("f1"))
    _assert_dec(us.child_at(1), _D128, 9, 1, 4, "us.f1")
    _assert_dec(us.child_at(2), _D256, 76, 0, 7, "us.f2")
    assert_equal(b.schema.field_at(6).union_type_ids()[2], 9)

    ref ud = b.column_at(7)
    assert_true(ud.arrow_type == ArrowType.UNION_DENSE)
    _assert_offsets(ud, [0, 0, 1], "ud offsets")
    assert_equal(ud.child_at(0).utf8_value_at(1), String("y"))
    assert_equal(Int(ud.child_at(1)._data.read_i32_le_at(0)), 42)

    ref n8 = b.column_at(8)
    assert_true(n8.arrow_type == ArrowType.INT8)
    assert_equal(n8.null_count(), 1)
    assert_true(n8.is_null_at(1))
    assert_equal(Int(n8._data.read_u8_at(2)), 0xFD)
    ref iv = b.column_at(9)
    assert_equal(iv._data.len(), 48)
    assert_equal(Int(iv._data.read_i64_le_at(32)), 13)


def test_zero_row_nested_shapes() raises:
    var fields = List[Field]()
    var cols = List[Column[HeapRegion]]()
    fields.append(Field("e0", ArrowType.STRUCT, True))
    cols.append(_shell(ArrowType.STRUCT, 0))
    fields.append(Field.union("u0", ArrowType.UNION_SPARSE, List[Int](), True))
    cols.append(_union(ArrowType.UNION_SPARSE, List[Int](), List[Int]()))
    fields.append(Field("s0", ArrowType.STRUCT, True))
    var s0 = _shell(ArrowType.STRUCT, 0)
    _kid(s0, _union(ArrowType.UNION_DENSE, List[Int](), List[Int](), List[Int]()), "uz")
    _kid(s0, _list(0, [0], _i64(List[Int]()), List[String]()), "l0")
    cols.append(s0^)
    var sp = _stream(fields^, cols^, 0)
    var r = _get_schema(sp)
    _check(_k(r, 0), "+s", "e0", _F, 0)
    assert_equal(Int(_k(r, 0)[].children), 0)
    _check(_k(r, 1), "+us:", "u0", _F, 0)
    assert_equal(Int(_k(r, 1)[].children), 0)
    _check(_k(_k(r, 2), 0), "+ud:", "uz", _F, 0)
    release_c_schema(r)
    r.free()
    var out = drain_record_batch_stream(sp)
    sp.free()
    ref b = out[0]
    assert_equal(b.num_rows(), 0)
    assert_equal(b.column_at(0).num_children(), 0)
    assert_true(b.column_at(1).arrow_type == ArrowType.UNION_SPARSE)
    assert_equal(len(b.column_at(1).type_ids()), 0)
    ref uz = b.column_at(2).child_at(0)
    assert_true(uz.arrow_type == ArrowType.UNION_DENSE)
    assert_equal(uz.length(), 0)
    assert_equal(uz._offsets.value().len(), 0)
    _assert_offsets(b.column_at(2).child_at(1), [0], "l0 offsets")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
