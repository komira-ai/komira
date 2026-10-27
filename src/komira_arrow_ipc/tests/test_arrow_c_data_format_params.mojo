# =============================================================================
# FFI-BOUNDARY: a stand-in foreign producer of Arrow C Data Interface
# structs, and a consumer of the streams this library exports. Hand-built
# structs and buffers are allocated here with `alloc` and left allocated for
# the life of the test process (none carries a release; the importer copies
# and frees nothing of a foreign struct). Exported streams are drained, which
# releases them, and their boxes freed.
#
# Arrow C Data Interface: the parameters a format string carries, read the
# same way at every depth.
#
# Spec: https://arrow.apache.org/docs/format/CDataInterface.html.
#
#   * Union `+us:I,J,...` / `+ud:I,J,...`: the type ids, one per child, are
#     what the types buffer holds. A union below the top level keeps them
#     (it was imported with 0..n-1, misreading every row), and a list whose
#     count is not the child count is refused.
#   * MAP_KEYS_SORTED (flag 4) on a MAP below the top level is kept.
#   * Decimal `d:P,S[,W]`: a precision outside the width's range, a malformed
#     string, a negative scale or a scale above the precision is refused (each
#     was replaced by a default, which changes the value's meaning).
#   * The Null type `n` is refused at the format gate with an import message.
# =============================================================================

from std.memory import alloc
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.schema import Field, RecordBatch, SchemaBuilder
from komira_arrow.string_array import StringArray
from komira_arrow_ipc.c_data_interface import ARROW_FLAG_MAP_KEYS_SORTED
from komira_arrow_ipc.c_data_stream import (
    CArrowArray,
    CArrowArrayStream,
    CArrowSchema,
    build_record_batch_stream,
    drain_record_batch_stream,
    _alloc_array_ptr_array,
    _alloc_buffers_array,
    _alloc_schema_ptr_array,
    _build_schema_from_info,
    _copy_string_to_c_int8,
    _import_column,
    _import_record_batch,
    _parse_decimal_format,
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


def _arr(length: Int, n_buffers: Int) -> CArrowArray:
    var a = CArrowArray()
    a.length = Int64(length)
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
    var p = alloc[UInt8](max(len(values), 1)).unsafe_origin_cast[MutUntrackedOrigin]()
    for i in range(len(values)):
        (p + i).unsafe_write(UInt8(values[i] & 0xFF))
    return p.bitcast[NoneType]()


def _i64s(values: List[Int]) -> _AP:
    var a = _arr(len(values), 2)
    var b = List[Int]()
    for i in range(len(values)):
        for k in range(8):
            b.append((values[i] >> (8 * k)) & 0xFF)
    (a.buffers + 1).unsafe_write(_bytes(b))
    return _ha(a^)


def _struct_of(kid_s: _SP, kid_a: _AP, rows: Int) -> Tuple[_SP, _AP]:
    """A one-child STRUCT schema and array around `kid_s` / `kid_a`."""
    var s = _sch("+s", "s")
    _skids(s, [kid_s])
    var a = _arr(rows, 1)
    _akids(a, [kid_a])
    return (_hs(s^), _ha(a^))


def _sparse_union(fmt: String, types: List[Int]) -> Tuple[_SP, _AP]:
    """A sparse union of two INT64 children over the row type ids `types`."""
    var u = _sch(fmt, "u")
    _skids(u, [_hs(_sch("l", "a")), _hs(_sch("l", "b"))])
    var n = len(types)
    var a = _arr(n, 1)
    (a.buffers + 0).unsafe_write(_bytes(types))
    var av = List[Int]()
    var bv = List[Int]()
    for i in range(n):
        av.append(10 + i)
        bv.append(20 + i)
    _akids(a, [_i64s(av), _i64s(bv)])
    return (_hs(u^), _ha(a^))


# --- union type ids -----------------------------------------------------------


def test_nested_union_keeps_its_declared_type_ids() raises:
    var u = _sparse_union("+us:3,9", [3, 9, 3])
    var sa = _struct_of(u[0], u[1], 3)
    var s = _import_column(sa[1][], ArrowType.STRUCT, 0, 0, sa[0])
    ref uc = s.child_at(0)
    assert_true(uc.arrow_type == ArrowType.UNION_SPARSE)
    assert_equal(len(uc.type_ids()), 2)
    assert_equal(uc.type_ids()[0], 3)
    assert_equal(uc.type_ids()[1], 9)
    assert_equal(Int(uc._data.read_u8_at(1)), 9)


def test_union_type_id_count_must_match_the_children() raises:
    # Nested: "+us:3" declares one id for two children.
    var u = _sparse_union("+us:3", [3, 3])
    var sa = _struct_of(u[0], u[1], 2)
    var msg = String("")
    try:
        _ = _import_column(sa[1][], ArrowType.STRUCT, 0, 0, sa[0])
    except e:
        msg = String(e)
    assert_equal(
        msg, String("from_arrow_c_stream: union format '+us:3' declares 1 type ids for 2 children")
    )
    # Top level, through the drain's path.
    var top = _sparse_union("+us:", [0, 1])
    var r = _sch("+s")
    _skids(r, [top[0]])
    var rs = _hs(r^)
    var ra = _arr(2, 1)
    _akids(ra, [top[1]])
    var info = _read_root_schema(rs)
    msg = String("")
    try:
        _ = _import_record_batch(_ha(ra^), info, _build_schema_from_info(info), rs)
    except e:
        msg = String(e)
    assert_equal(
        msg, String("from_arrow_c_stream: union format '+us:' declares 0 type ids for 2 children")
    )


# --- through export and import -------------------------------------------------


def _shell(t: ArrowType, n: Int, offsets: List[Int] = List[Int]()) -> Column[HeapRegion]:
    var data = OwnedAlignedBuffer(1)
    data.set_length(0)
    var off = Optional[OwnedAlignedBuffer](None)
    if len(offsets) > 0:
        var b = OwnedAlignedBuffer(len(offsets) * 4)
        b.set_length(Int64(len(offsets) * 4))
        for i in range(len(offsets)):
            b.write_i32_le_at(i * 4, Int32(offsets[i]))
        off = b^
    return Column[HeapRegion](
        arrow_type=t, data=data^, offsets=off^, validity=None,
        length=n, null_count=0, offset=0,
    )


def _col_i64(values: List[Int]) -> Column[HeapRegion]:
    var b = OwnedAlignedBuffer(max(len(values) * 8, 1))
    b.set_length(Int64(len(values) * 8))
    for i in range(len(values)):
        b.write_i64_le_at(i * 8, Int64(values[i]))
    return Column[HeapRegion](
        arrow_type=ArrowType.INT64, data=b^, offsets=None, validity=None,
        length=len(values), null_count=0, offset=0,
    )


def _kid(mut parent: Column[HeapRegion], var kid: Column[HeapRegion], name: String):
    parent._children.append(kid^)
    parent._field_names.append(name)


def _round_trip(var col: Column[HeapRegion], rows: Int) raises -> Slab[RecordBatch]:
    var sb = SchemaBuilder()
    sb.add_field(Field("s", ArrowType.STRUCT, True))
    var schema = sb.build()
    var slab = Slab[Column[HeapRegion]].with_capacity(1)
    slab.append(col^)
    var b = RecordBatch()
    b.schema = schema.copy()
    b._columns = slab^
    b._num_rows = rows
    var bs = Slab[RecordBatch].with_capacity(1)
    bs.append(b^)
    var sp = alloc[CArrowArrayStream](1).unsafe_origin_cast[MutUntrackedOrigin]()
    sp.unsafe_write(CArrowArrayStream())
    build_record_batch_stream(bs^, schema^, sp)
    var out = drain_record_batch_stream(sp)
    sp.free()
    return out^


def test_nested_union_and_sorted_map_round_trip() raises:
    var s = _shell(ArrowType.STRUCT, 3)
    var tb = OwnedAlignedBuffer(3)
    tb.set_length(3)
    var types = [3, 9, 3]
    for i in range(3):
        tb.set_typed[Int8](i, Int8(types[i]))
    var u = Column[HeapRegion](
        arrow_type=ArrowType.UNION_SPARSE, data=tb^, offsets=None, validity=None,
        length=3, null_count=0, offset=0,
    )
    u._type_ids = [3, 9]
    _kid(u, _col_i64([1, 2, 3]), "a")
    _kid(u, _col_i64([4, 5, 6]), "b")
    _kid(s, u^, "u")
    var m = _shell(ArrowType.MAP, 3, [0, 1, 1, 2])
    var e = _shell(ArrowType.STRUCT, 2)
    var keys: List[String] = ["k1", "k2"]
    _kid(e, Column.from_string(StringArray.from_strings(keys)), "key")
    _kid(e, _col_i64([7, 8]), "value")
    _kid(m, e^, "entries")
    m._keys_sorted = True
    _kid(s, m^, "m")
    var out = _round_trip(s^, 3)
    ref b = out[0]
    ref su = b.column_at(0).child_at(0)
    assert_equal(len(su.type_ids()), 2)
    assert_equal(su.type_ids()[0], 3, "nested union ids survive")
    assert_equal(su.type_ids()[1], 9, "nested union ids survive")
    assert_equal(Int(su._data.read_u8_at(1)), 9)
    assert_true(b.column_at(0).child_at(1).keys_sorted(), "nested MAP_KEYS_SORTED survives")


def test_nested_map_keys_sorted_flag_is_read() raises:
    for is_sorted in [False, True]:
        var e = _arr(0, 1)
        _akids(e, [_ha(_arr(0, 3)), _ha(_arr(0, 2))])
        var m = _arr(0, 2)
        _akids(m, [_ha(e^)])
        var es = _sch("+s", "entries")
        _skids(es, [_hs(_sch("u", "key")), _hs(_sch("l", "value"))])
        var ms = _sch("+m", "m", ARROW_FLAG_MAP_KEYS_SORTED if is_sorted else 0)
        _skids(ms, [_hs(es^)])
        var sa = _struct_of(_hs(ms^), _ha(m^), 0)
        var s = _import_column(sa[1][], ArrowType.STRUCT, 0, 0, sa[0])
        assert_equal(s.child_at(0).keys_sorted(), is_sorted)


# --- decimal ------------------------------------------------------------------


def _decimal_error(fmt: String) -> String:
    try:
        _ = _parse_decimal_format(fmt)
    except e:
        return String(e)
    return String("(accepted)")


def test_decimal_formats_that_are_refused() raises:
    var fmts: List[String] = [
        "d:40,2", "d:0,2", "d:80,2,256", "d:39,0,128", "d:x,2", "d:10", "d:10,",
        "d:,2", "d:10,2,", "d:10,2,256,1", "d:10,2x", "d:", "d:-5,2", "d:10,--2",
        "d:5,7", "d:10,-2", "d:10,2,64",
    ]
    var want: List[String] = [
        "from_arrow_c_stream: decimal format 'd:40,2': precision 40 is outside [1, 38] for a 128-bit decimal",
        "from_arrow_c_stream: decimal format 'd:0,2': precision 0 is outside [1, 38] for a 128-bit decimal",
        "from_arrow_c_stream: decimal format 'd:80,2,256': precision 80 is outside [1, 76] for a 256-bit decimal",
        "from_arrow_c_stream: decimal format 'd:39,0,128': precision 39 is outside [1, 38] for a 128-bit decimal",
    ]
    for f in ["d:x,2", "d:10", "d:10,", "d:,2", "d:10,2,", "d:10,2,256,1", "d:10,2x", "d:", "d:-5,2", "d:10,--2"]:
        want.append(
            "from_arrow_c_stream: malformed decimal format '" + String(f)
            + "' (expected d:P,S or d:P,S,W)"
        )
    want.append(
        "UnsupportedArrowCABIType: decimal format 'd:5,7': scale 7 exceeds"
        " precision 5; such scales are not supported"
    )
    want.append(
        "UnsupportedArrowCABIType: decimal format 'd:10,-2': scale -2 is"
        " negative; negative scales are not supported"
    )
    want.append("UnsupportedArrowCABIType: decimal bitwidth '64' (only 128 and 256 supported)")
    assert_equal(len(fmts), len(want))
    for i in range(len(fmts)):
        assert_equal(_decimal_error(fmts[i]), want[i], fmts[i])


def test_decimal_formats_at_the_bounds() raises:
    var fmts: List[String] = ["d:1,0", "d:38,38", "d:38,0,128", "d:76,76,256", "d:1,1,256", "d:10,2"]
    var want_p = [1, 38, 38, 76, 1, 10]
    var want_s = [0, 38, 0, 76, 1, 2]
    for i in range(len(fmts)):
        var ps = _parse_decimal_format(fmts[i])
        assert_equal(ps[0], want_p[i], fmts[i])
        assert_equal(ps[1], want_s[i], fmts[i])


def test_a_bad_decimal_is_refused_at_every_depth() raises:
    # Top level: the root schema read.
    var r = _sch("+s")
    _skids(r, [_hs(_sch("d:40,2", "x"))])
    var msg = String("")
    try:
        _ = _read_root_schema(_hs(r^))
    except e:
        msg = String(e)
    assert_true(msg.startswith("from_arrow_c_stream: decimal format 'd:40,2'"), msg)
    # A STRUCT child.
    var sa = _struct_of(_hs(_sch("d:10,-2", "y")), _ha(_arr(0, 2)), 0)
    msg = String("")
    try:
        _ = _import_column(sa[1][], ArrowType.STRUCT, 0, 0, sa[0])
    except e:
        msg = String(e)
    assert_true(msg.startswith("UnsupportedArrowCABIType: decimal format 'd:10,-2'"), msg)


# --- the Null type ------------------------------------------------------------


def test_the_null_type_is_refused_on_import() raises:
    var want = String(
        "UnsupportedArrowCABIType: the Null type ('n') is not in the supported drain subset"
    )
    var r = _sch("+s")
    _skids(r, [_hs(_sch("n", "z"))])
    var msg = String("")
    try:
        _ = _read_root_schema(_hs(r^))
    except e:
        msg = String(e)
    assert_equal(msg, want, "top level")
    var sa = _struct_of(_hs(_sch("n", "z")), _ha(_arr(0, 0)), 0)
    msg = String("")
    try:
        _ = _import_column(sa[1][], ArrowType.STRUCT, 0, 0, sa[0])
    except e:
        msg = String(e)
    assert_equal(msg, want, "a STRUCT child")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
