# =============================================================================
# Arrow C Data Interface export: a refused nested column frees what was
# built before the refusal.
#
# The schema and array builders allocate a child struct, its format and name
# strings, a children array and a buffers array for every child of a nested
# column before they reach the child that is refused. Nothing outside the
# builder can reach those allocations once it raises, so each refusal leaked
# them, and a consumer that retries `get_schema` / `get_next` leaks again on
# every call.
#
# The tests make a STRUCT of 64 INT64 children, each with a 2 KiB name,
# followed by one child of a type outside the C ABI subset, has the builders
# refuse it many times, and reads the process's resident set (`VmRSS` of
# `/proc/self/status`) before and after. A schema refusal that leaks its 64
# children leaks their names (about 130 KiB), an array refusal about 7 KiB of
# child structs and buffers arrays; a refusal that frees them reuses the same
# heap blocks and leaves the resident set flat. The rounds are chosen so a
# leak grows it by at least 4 MiB, well past the 1.5 MiB bound. The root
# schema builder is driven the same way through `get_schema`, over a stream of
# 64 such columns and one it refuses.
#
# Linux only: `/proc/self/status` is the measurement.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from std.memory import alloc

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.dictionary_array import StringDictionaryArray
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import Field, RecordBatch, SchemaBuilder
from komira_arrow.string_array import StringArray
from komira_arrow_ipc.c_data_stream import (
    CArrowArrayStream,
    CArrowSchema,
    build_record_batch_stream,
    release_c_schema,
    release_c_stream,
    _build_column_array,
    _build_column_schema_from_column,
    _build_column_schema_from_field_and_column,
)
from komira_buffer.heap_region import HeapRegion
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_collections.slab import Slab

comptime _KIDS = 64
comptime _SCHEMA_ROUNDS = 30
comptime _ARRAY_ROUNDS = 600
comptime _BOUND_BYTES = 3 * 512 * 1024


def _resident_bytes() raises -> Int:
    """`VmRSS` of `/proc/self/status`, in bytes (the file gives kB)."""
    var text: String
    with open("/proc/self/status", "r") as f:
        text = f.read()
    var key = String("VmRSS:")
    var i = text.find(key)
    if i < 0:
        raise Error("/proc/self/status has no VmRSS")
    var b = text.as_bytes()
    var j = i + key.byte_length()
    while j < len(b) and (b[j] == 32 or b[j] == 9):
        j += 1
    var v = 0
    while j < len(b) and b[j] >= 48 and b[j] <= 57:
        v = v * 10 + Int(b[j] - 48)
        j += 1
    return v * 1024


def _i64(n: Int) -> Column[HeapRegion]:
    var b = OwnedAlignedBuffer(max(n * 8, 1))
    b.set_length(Int64(n * 8))
    return Column[HeapRegion](
        arrow_type=ArrowType.INT64, data=b^, offsets=None, validity=None,
        length=n, null_count=0, offset=0,
    )


def _pad() -> String:
    var pad = String("")
    for _ in range(2048):
        pad += "n"
    return pad^


def _refused_struct() -> Column[HeapRegion]:
    """A STRUCT of `_KIDS` INT64 children with 2 KiB names, then one
    FIXED_SIZE_BINARY child, which no builder exports."""
    var data = OwnedAlignedBuffer(1)
    data.set_length(0)
    var s = Column[HeapRegion](
        arrow_type=ArrowType.STRUCT, data=data^, offsets=None, validity=None,
        length=1, null_count=0, offset=0,
    )
    var pad = _pad()
    for i in range(_KIDS):
        s._children.append(_i64(1))
        s._field_names.append(String(i) + pad)
    var bad = _i64(1)
    bad.arrow_type = ArrowType.FIXED_SIZE_BINARY
    s._children.append(bad^)
    s._field_names.append("bad")
    return s^


def _refuse_schema(ref col: Column[HeapRegion], mode: Int) -> String:
    try:
        if mode == 0:
            _ = _build_column_schema_from_column(col, "s", True)
        else:
            _ = _build_column_schema_from_field_and_column(
                Field("s", ArrowType.STRUCT, True), col
            )
    except e:
        return String(e)
    return String("(built)")


def _refuse_array(ref col: Column[HeapRegion]) -> String:
    try:
        _ = _build_column_array(col)
    except e:
        return String(e)
    return String("(built)")


def _growth[mode: Int](ref col: Column[HeapRegion]) raises -> Int:
    """Resident-set growth over many refusals; mode 0/1 the two schema
    builders, 2 the array builder. One warm-up refusal first, so the baseline
    already holds whatever the first call allocates for good."""
    var first = _refuse_array(col) if mode == 2 else _refuse_schema(col, mode)
    assert_true(
        first.startswith("UnsupportedArrowCABIType: Arrow type 'fixed_size_binary'"), first
    )
    var before = _resident_bytes()
    for _ in range(_ARRAY_ROUNDS if mode == 2 else _SCHEMA_ROUNDS):
        if mode == 2:
            _ = _refuse_array(col)
        else:
            _ = _refuse_schema(col, mode)
    return _resident_bytes() - before


def test_a_refused_child_schema_frees_its_siblings() raises:
    var col = _refused_struct()
    var g = _growth[0](col)
    assert_true(g < _BOUND_BYTES, "column-only schema builder grew by " + String(g))


def test_a_refused_field_schema_frees_its_children() raises:
    var col = _refused_struct()
    var g = _growth[1](col)
    assert_true(g < _BOUND_BYTES, "field schema builder grew by " + String(g))


def test_a_refused_child_array_frees_its_siblings() raises:
    var col = _refused_struct()
    var g = _growth[2](col)
    assert_true(g < _BOUND_BYTES, "array builder grew by " + String(g))


def _refused_stream() raises -> UnsafePointer[CArrowArrayStream, MutUntrackedOrigin]:
    """A stream of `_KIDS` INT64 columns with 2 KiB names, then a dictionary
    column whose Field declares INT8 indices over a Column holding 4-byte
    ones, which `get_schema` refuses after building the other columns."""
    var sb = SchemaBuilder()
    var cols = Slab[Column[HeapRegion]].with_capacity(_KIDS + 1)
    var pad = _pad()
    for i in range(_KIDS):
        sb.add_field(Field(String(i) + pad, ArrowType.INT64, True))
        cols.append(_i64(1))
    sb.add_field(Field.dictionary("d", ArrowType.INT8, True))
    var idx = PrimitiveArray[DType.int32].from_list([Int32(0)])
    var vals: List[String] = ["x"]
    cols.append(
        Column.from_dictionary(
            StringDictionaryArray.from_parts(idx^, StringArray.from_strings(vals))
        )
    )
    var schema = sb.build()
    var b = RecordBatch()
    b.schema = schema.copy()
    b._columns = cols^
    b._num_rows = 1
    var bs = Slab[RecordBatch].with_capacity(1)
    bs.append(b^)
    var sp = alloc[CArrowArrayStream](1).unsafe_origin_cast[MutUntrackedOrigin]()
    sp.unsafe_write(CArrowArrayStream())
    build_record_batch_stream(bs^, schema^, sp)
    return sp


def _get_schema_rc(sp: UnsafePointer[CArrowArrayStream, MutUntrackedOrigin]) -> Int:
    var sb = alloc[CArrowSchema](1).unsafe_origin_cast[MutUntrackedOrigin]()
    sb.unsafe_write(CArrowSchema())
    var rc = Int(sp[].get_schema(sp.bitcast[NoneType](), sb))
    release_c_schema(sb)
    sb.free()
    return rc


def test_a_refused_root_schema_frees_the_columns_before_it() raises:
    var sp = _refused_stream()
    assert_equal(_get_schema_rc(sp), 5, "get_schema refuses the dictionary column")
    var before = _resident_bytes()
    for _ in range(_SCHEMA_ROUNDS):
        _ = _get_schema_rc(sp)
    var g = _resident_bytes() - before
    release_c_stream(sp)
    sp.free()
    assert_true(g < _BOUND_BYTES, "root schema builder grew by " + String(g))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
