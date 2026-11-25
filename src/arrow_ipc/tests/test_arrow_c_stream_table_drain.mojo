# =============================================================================
# test_arrow_c_stream_table_drain.mojo: drain_record_batch_stream_table, an
# Arrow C stream taken by reference and drained into one Table
# =============================================================================
#
# The producer is a counting wrapper: its get_schema and get_next delegate to
# a stream komira exported (build_record_batch_stream), so the buffers are
# real, and its own release callback counts each call, releases the inner
# stream and marks the wrapper released. That count is what the tests read.
#
# The contract checked: the table holds every chunk in order with the
# stream's schema; a stream of no chunk is a table of no chunk that still has
# its schema; the stream is released exactly once on success, when
# get_schema fails, when get_next fails and when the import refuses a chunk
# after an earlier one was read; a stream released already is refused by
# name and its release is not called again.
#
# FFI-BOUNDARY: this file stands in for a foreign producer of the Arrow C
# Stream Interface: its abi("C") callbacks and the CArrowArrayStream
# pointers they are handed are spelled with MutUntrackedOrigin, as the C ABI
# spells them (tests/pointer_lint_ffi.tsv lists this file). Ownership: each
# test allocates the wrapper struct, its two-word private block and the inner
# stream struct in `_counting_stream`, and frees all three in `_free`; the
# drain borrows the wrapper and calls `_counting_release`, which releases the
# inner stream's contents, never a struct.
# =============================================================================

from std.memory import alloc
from std.testing import TestSuite, assert_equal, assert_true

from arrow.arrow_types import ArrowType
from arrow.column import Column
from arrow.primitive_array import PrimitiveArray
from arrow.schema import Field, RecordBatch, RecordBatchBuilder, Schema, SchemaBuilder
from arrow.string_array import StringArray
from arrow.table import Table
from arrow_ipc.c_data_stream import (
    CArrowArray,
    CArrowArrayStream,
    CArrowSchema,
    build_record_batch_stream,
    release_c_stream,
)
from arrow_ipc.c_stream_table import drain_record_batch_stream_table
from containers.slab import Slab

comptime _VP = UnsafePointer[NoneType, MutUntrackedOrigin]
comptime _SP = UnsafePointer[CArrowSchema, MutUntrackedOrigin]
comptime _AP = UnsafePointer[CArrowArray, MutUntrackedOrigin]
comptime _STP = UnsafePointer[CArrowArrayStream, MutUntrackedOrigin]
comptime _Words = UnsafePointer[Int, MutUntrackedOrigin]
comptime _StreamReleaseFn = def (_STP) thin -> None

# The wrapper's private block: word 0 is the inner stream's address, word 1
# the number of times the wrapper's release ran.
comptime _INNER = 0
comptime _RELEASES = 1


def _null_vp() -> _VP:
    # SAFETY: `Optional[UnsafePointer[...]]` is layout-compatible with the
    # bare pointer and `None` is the all-zero bit pattern, so this reads NULL.
    # The value is only stored as a released `release` slot, never called.
    var none: Optional[_VP] = None
    return UnsafePointer(to=none).bitcast[_VP]()[]


def _inner_of(stream: _VP) -> _STP:
    # SAFETY: `stream` is a wrapper built by `_counting_stream`, whose
    # private block holds the inner stream's address in word `_INNER`; the
    # block and the inner struct live until `_free`.
    var words = stream.bitcast[CArrowArrayStream]()[].private_data.bitcast[Int]()
    return words.bitcast[_STP]()[_INNER]


def _counting_get_schema(stream: _VP, out_schema: _SP) abi("C") -> Int32:
    var inner = _inner_of(stream)
    return inner[].get_schema(inner.bitcast[NoneType](), out_schema)


def _counting_get_next(stream: _VP, out_array: _AP) abi("C") -> Int32:
    var inner = _inner_of(stream)
    return inner[].get_next(inner.bitcast[NoneType](), out_array)


def _counting_get_last_error(stream: _VP) abi("C") -> UnsafePointer[Int8, MutUntrackedOrigin]:
    var inner = _inner_of(stream)
    return inner[].get_last_error(inner.bitcast[NoneType]())


def _counting_release(stream: _STP) -> None:
    """Count the call, release the inner stream and mark the wrapper
    released, as the Arrow C Stream Interface asks of a release callback."""
    var words = stream[].private_data.bitcast[Int]()
    words[_RELEASES] += 1
    release_c_stream(_inner_of(stream.bitcast[NoneType]()))
    stream[].release = _null_vp()


def _counting_stream(var batches: Slab[RecordBatch], var schema: Schema) raises -> _STP:
    """A wrapper stream over komira's export of `batches` (heap storage
    throughout: a stack struct is not kept alive across the callbacks)."""
    var inner = alloc[CArrowArrayStream](1).unsafe_origin_cast[MutUntrackedOrigin]()
    inner.unsafe_write(CArrowArrayStream())
    build_record_batch_stream(batches^, schema^, inner)
    var words = alloc[Int](2).unsafe_origin_cast[MutUntrackedOrigin]()
    words.bitcast[_STP]()[_INNER] = inner
    words[_RELEASES] = 0
    var outer = alloc[CArrowArrayStream](1).unsafe_origin_cast[MutUntrackedOrigin]()
    outer.unsafe_write(CArrowArrayStream())
    outer[].get_schema = _counting_get_schema
    outer[].get_next = _counting_get_next
    outer[].get_last_error = _counting_get_last_error
    outer[].private_data = words.bitcast[NoneType]()
    var f: _StreamReleaseFn = _counting_release
    outer[].release = UnsafePointer(to=f).bitcast[_VP]()[]
    return outer


def _releases(stream: _STP) -> Int:
    return stream[].private_data.bitcast[Int]()[_RELEASES]


def _free(stream: _STP):
    """Free the wrapper, its private block and the inner stream struct."""
    var words = stream[].private_data.bitcast[Int]()
    _inner_of(stream.bitcast[NoneType]()).free()
    words.free()
    stream.free()


def _schema(with_list: Bool = False) raises -> Schema:
    var sb = SchemaBuilder()
    if with_list:
        sb.add_field(Field.list_of("l", ArrowType.INT64, nullable=True))
    else:
        sb.add_field(Field("n", ArrowType.INT64, False))
        sb.add_field(Field("s", ArrowType.STRING, True))
    return sb.build()


def _batch(base: Int) raises -> RecordBatch:
    """Rows (base, "x<base>") and (base + 1, "x<base+1>")."""
    var rbb = RecordBatchBuilder.with_capacity(2)
    rbb.add_column(
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list([Int64(base), Int64(base + 1)])
        )
    )
    rbb.add_column(
        Column.from_string(
            StringArray.from_strings(
                [String("x") + String(base), String("x") + String(base + 1)]
            )
        )
    )
    return rbb.build(_schema())


def _drain_error(stream: _STP) -> String:
    try:
        _ = drain_record_batch_stream_table(stream[])
    except e:
        return String(e)
    return String("(drained)")


def test_the_table_holds_every_chunk_in_order_and_the_stream_is_released_once() raises:
    var batches = Slab[RecordBatch].with_capacity(2)
    batches.append(_batch(10))
    batches.append(_batch(20))
    var sp = _counting_stream(batches^, _schema())
    var table = drain_record_batch_stream_table(sp[])
    assert_equal(_releases(sp), 1)
    assert_true(sp[].is_released())
    _free(sp)
    assert_equal(table.num_chunks(), 2)
    assert_equal(table.num_rows(), 4)
    assert_equal(table.num_columns(), 2)
    assert_equal(table.schema().field_name(0), String("n"))
    assert_equal(table.schema().field_name(1), String("s"))
    assert_equal(table.value_i64(0, 0), Int64(10))
    assert_equal(table.value_i64(0, 3), Int64(21))
    assert_equal(table.value_str(1, 2), String("x20"))


def test_a_stream_of_no_chunk_is_an_empty_table_with_the_schema() raises:
    var sp = _counting_stream(Slab[RecordBatch].with_capacity(1), _schema())
    var table = drain_record_batch_stream_table(sp[])
    assert_equal(_releases(sp), 1)
    _free(sp)
    assert_equal(table.num_chunks(), 0)
    assert_equal(table.num_rows(), 0)
    assert_equal(table.num_columns(), 2)
    assert_equal(table.schema().field_name(1), String("s"))
    assert_true(table.schema().field_arrow_type(0) == ArrowType.INT64)
    assert_true(table.schema().field_arrow_type(1) == ArrowType.STRING)


def test_a_failing_get_schema_releases_the_stream_once() raises:
    """komira's export refuses the schema of an empty stream of a
    list<int64> field at get_schema (EIO, 5), with error text."""
    var sp = _counting_stream(Slab[RecordBatch].with_capacity(1), _schema(True))
    var msg = _drain_error(sp)
    assert_true(
        msg.startswith("from_arrow_c_stream: get_schema failed (rc=5): "), msg
    )
    assert_equal(_releases(sp), 1)
    _free(sp)


def test_a_failing_get_next_releases_the_stream_once() raises:
    """A sliced STRING column: komira's get_next refuses a non-zero
    logical offset on a variable-length column."""
    var b = _batch(1)
    b._columns[1]._offset = 1
    b._columns[1]._length = 1
    var batches = Slab[RecordBatch].with_capacity(1)
    batches.append(b^)
    var sp = _counting_stream(batches^, _schema())
    var msg = _drain_error(sp)
    assert_true(
        msg.startswith(
            "from_arrow_c_stream: get_next failed (rc=5): UnsupportedArrowCABIType:"
        ),
        msg,
    )
    assert_equal(_releases(sp), 1)
    _free(sp)


def test_a_chunk_the_import_refuses_after_a_good_one_releases_the_stream_once() raises:
    """The second chunk's INT64 column is a slice, which komira exports with
    its offset and the import refuses."""
    var sliced = _batch(5)
    sliced._columns[0]._offset = 1
    sliced._columns[0]._length = 1
    sliced._columns[1]._length = 1
    sliced._num_rows = 1
    var batches = Slab[RecordBatch].with_capacity(2)
    batches.append(_batch(1))
    batches.append(sliced^)
    var sp = _counting_stream(batches^, _schema())
    var msg = _drain_error(sp)
    assert_equal(
        msg,
        "from_arrow_c_stream: child array with non-zero offset (1) — not"
        " supported",
    )
    assert_equal(_releases(sp), 1)
    _free(sp)


def test_a_released_stream_is_refused_and_not_released_again() raises:
    var batches = Slab[RecordBatch].with_capacity(1)
    batches.append(_batch(1))
    var sp = _counting_stream(batches^, _schema())
    _counting_release(sp)
    assert_equal(_releases(sp), 1)
    var msg = _drain_error(sp)
    assert_equal(msg, "from_arrow_c_stream: stream is already released")
    assert_equal(_releases(sp), 1)
    _free(sp)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
