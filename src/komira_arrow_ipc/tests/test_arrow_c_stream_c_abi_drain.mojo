# =============================================================================
# test_arrow_c_stream_c_abi_drain.mojo: drain_c_abi_record_batch_stream, the
# drain that takes a foreign producer's four callbacks as C function pointers
# =============================================================================
#
# The producer is a komira stream (build_record_batch_stream); its callbacks
# are handed over one by one as `abi("C")` function pointers with the stream
# itself as `self`, which is what a foreign shared library does. The release
# callback is a test-local C-ABI function releasing that stream.
#
# The contract checked: the drained batches equal the exported ones; and
# `release(self)` runs on every exit path (success, get_schema failing, a
# root schema the import refuses, get_next failing, a chunk the import
# refuses), observed as the stream being in the released state afterwards.
# Each failure names the step and carries the producer's error text.
#
# FFI-BOUNDARY: this file stands in for a foreign producer of the Arrow C
# Stream Interface: its abi("C") callbacks and the CArrowArrayStream pointers
# they are handed are spelled with MutUntrackedOrigin, as the C ABI and
# drain_c_abi_record_batch_stream spell them (tests/pointer_lint_ffi.tsv
# lists this file). Ownership: each test allocates its stream struct in
# `_export` and frees it with `sp.free()`; the drain borrows it and calls
# `_release_cb`, which releases what the stream holds, never the struct.
# =============================================================================

from std.memory import alloc
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.schema import Field, RecordBatch, Schema, SchemaBuilder
from komira_arrow.string_array import StringArray
from komira_arrow.primitive_array import PrimitiveArray
from komira_buffer.heap_region import HeapRegion
from komira_collections.slab import Slab
from komira_arrow_ipc.c_data_stream import (
    CArrowArrayStream,
    CArrowSchema,
    build_record_batch_stream,
    drain_c_abi_record_batch_stream,
    release_c_stream,
    _copy_string_to_c_int8,
    _set_schema_release,
)

comptime _VP = UnsafePointer[NoneType, MutUntrackedOrigin]
comptime _SP = UnsafePointer[CArrowSchema, MutUntrackedOrigin]
comptime _STP = UnsafePointer[CArrowArrayStream, MutUntrackedOrigin]


def _release_cb(self_ptr: _VP) abi("C") -> None:
    release_c_stream(self_ptr.bitcast[CArrowArrayStream]())


def _int_root_get_schema(stream: _VP, out_schema: _SP) abi("C") -> Int32:
    """A producer whose root schema is `i`, not the struct `+s`."""
    _ = stream
    var s = CArrowSchema()
    s.format = _copy_string_to_c_int8(String("i"))
    _set_schema_release(s)
    out_schema.unsafe_write(s^)
    return Int32(0)


def _schema(with_list: Bool = False) raises -> Schema:
    var sb = SchemaBuilder()
    if with_list:
        sb.add_field(Field.list_of("l", ArrowType.INT64, nullable=True))
    else:
        sb.add_field(Field("n", ArrowType.INT64, False))
        sb.add_field(Field("s", ArrowType.STRING, True))
    return sb.build()


def _batch(base: Int, offset: Int = 0) raises -> RecordBatch:
    """Rows (base, "x<base>"), (base + 1, "x<base+1>"); with `offset` 1
    the INT64 column is a slice starting at its second value."""
    var ints = List[Int64]()
    if offset == 1:
        ints.append(Int64(base - 1))
    ints.append(Int64(base))
    ints.append(Int64(base + 1))
    var c0 = Column.from_primitive[DType.int64](
        PrimitiveArray[DType.int64].from_list(ints)
    )
    if offset == 1:
        c0._offset = 1
        c0._length = 2
    var strs = List[String]()
    strs.append(String("x") + String(base))
    strs.append(String("x") + String(base + 1))
    var b = RecordBatch()
    b.schema = _schema()
    var cols = Slab[Column[HeapRegion]].with_capacity(2)
    cols.append(c0^)
    cols.append(Column.from_string(StringArray.from_strings(strs)))
    b._columns = cols^
    b._num_rows = 2
    return b^


def _export(var batches: Slab[RecordBatch], var schema: Schema) raises -> _STP:
    var sp = alloc[CArrowArrayStream](1).unsafe_origin_cast[MutUntrackedOrigin]()
    sp.unsafe_write(CArrowArrayStream())
    build_record_batch_stream(batches^, schema^, sp)
    return sp


def _drain(sp: _STP) raises -> Slab[RecordBatch]:
    return drain_c_abi_record_batch_stream(
        sp.bitcast[NoneType](),
        sp[].get_schema,
        sp[].get_next,
        sp[].get_last_error,
        _release_cb,
    )


def _drain_error(sp: _STP) -> String:
    try:
        _ = _drain(sp)
    except e:
        return String(e)
    return String("(drained)")


def test_drain_returns_every_batch_and_releases() raises:
    var batches = Slab[RecordBatch].with_capacity(2)
    batches.append(_batch(10))
    batches.append(_batch(20))
    var sp = _export(batches^, _schema())
    var out = _drain(sp)
    assert_true(sp[].is_released())
    sp.free()
    assert_equal(len(out), 2)
    assert_equal(out[0].num_rows(), 2)
    assert_equal(out[1].schema.field_name(1), String("s"))
    assert_equal(Int(out[0].column_value(0, 1)), 11)
    assert_equal(Int(out[1].column_value(0, 0)), 20)
    assert_equal(out[1].column_at(1).as_string().get(1), String("x21"))


def test_drain_of_an_empty_stream_is_empty_and_releases() raises:
    var sp = _export(Slab[RecordBatch].with_capacity(1), _schema())
    var out = _drain(sp)
    assert_equal(len(out), 0)
    assert_true(sp[].is_released())
    sp.free()


def test_a_failing_get_schema_releases_and_names_the_step() raises:
    """An empty stream of a list<int64> field: komira's get_schema refuses
    it (EIO, 5) with error text."""
    var sp = _export(Slab[RecordBatch].with_capacity(1), _schema(True))
    var msg = _drain_error(sp)
    assert_true(
        msg.startswith("c_abi_scan_stream: get_schema failed (rc=5): "), msg
    )
    assert_true(msg.byte_length() > 46, msg)
    assert_true(sp[].is_released())
    sp.free()


def test_a_root_the_import_refuses_releases() raises:
    var batches = Slab[RecordBatch].with_capacity(1)
    batches.append(_batch(1))
    var sp = _export(batches^, _schema())
    var msg = String("")
    try:
        _ = drain_c_abi_record_batch_stream(
            sp.bitcast[NoneType](),
            _int_root_get_schema,
            sp[].get_next,
            sp[].get_last_error,
            _release_cb,
        )
    except e:
        msg = String(e)
    assert_equal(
        msg,
        "from_arrow_c_stream: top-level ArrowSchema must be a struct ('+s'),"
        " got 'i'",
    )
    assert_true(sp[].is_released())
    sp.free()


def test_a_failing_get_next_releases_and_names_the_step() raises:
    """A sliced STRING column: komira's get_next refuses a non-zero
    logical offset on a variable-length column."""
    var b = _batch(1)
    b._columns[1]._offset = 1
    b._columns[1]._length = 1
    var batches = Slab[RecordBatch].with_capacity(1)
    batches.append(b^)
    var sp = _export(batches^, _schema())
    var msg = _drain_error(sp)
    assert_true(
        msg.startswith(
            "c_abi_scan_stream: get_next failed (rc=5): UnsupportedArrowCABIType:"
        ),
        msg,
    )
    assert_true(sp[].is_released())
    sp.free()


def test_a_chunk_the_import_refuses_releases() raises:
    """A sliced INT64 column exports its offset; the import refuses it, after
    a first good batch was already drained."""
    var batches = Slab[RecordBatch].with_capacity(2)
    batches.append(_batch(1))
    batches.append(_batch(5, offset=1))
    var sp = _export(batches^, _schema())
    var msg = _drain_error(sp)
    assert_equal(
        msg,
        "from_arrow_c_stream: child array with non-zero offset (1) — not"
        " supported",
    )
    assert_true(sp[].is_released())
    sp.free()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
