# =============================================================================
# check_record_batch_stream: a stream that will fail inside get_schema or
# get_next is refused before it is handed out, naming the column
# =============================================================================
#
# What each test proves, and the defect it would catch:
#   * test_a_stream_that_exports_passes_and_leaves_nothing_held: two batches
#     of INT64 and STRING pass, and afterwards every column buffer is held by
#     its batch and the test's probe share alone (strong count 2), so the
#     schema and arrays the check built were released. Catches a check that
#     leaks what it builds (a count above 2), and a check that refuses a good
#     stream.
#   * test_a_column_type_outside_the_interface_is_refused_by_name: a
#     UTF8_VIEW field is refused naming the column and its type, with no batch
#     at all. Catches a check that only looks at the data.
#   * test_an_empty_stream_of_flat_columns_passes: no batch and flat columns
#     pass (get_schema builds such a schema from the fields).
#   * test_an_empty_stream_with_a_nested_column_is_refused: no batch and a
#     LIST column is refused with get_schema's own message. Catches a check
#     that does not build the schema get_schema builds.
#   * test_a_batch_with_a_selection_mask_is_refused: a batch that still
#     carries a mask is refused naming the batch. Catches the rows the mask
#     drops crossing the boundary.
#   * test_a_batch_whose_columns_are_not_the_schemas_is_refused: a second
#     batch with fewer columns than the schema is refused naming the counts.
#   * test_a_sliced_string_column_is_refused_and_nothing_is_held: a STRING
#     column with a non-zero offset in the second batch is refused naming the
#     column, its type and the batch, and afterwards the buffers of both
#     batches are held by their batches alone. Catches a refusal found only at
#     get_next, and a leak on the refusal path.
#   * test_a_dictionary_whose_index_width_is_not_the_fields_is_refused: a
#     dictionary column with INT32 indices under a field declaring INT64
#     indices is refused naming the column. Catches a check that skips the
#     dictionary check get_next makes.

from std.testing import TestSuite, assert_equal, assert_true

from arrow.arrow_types import ArrowType
from arrow.boolean_array import BooleanArray
from arrow.column import Column
from arrow.dictionary_array import StringDictionaryArray
from arrow.primitive_array import PrimitiveArray
from arrow.schema import Field, RecordBatch, RecordBatchBuilder, Schema, SchemaBuilder
from arrow.string_array import StringArray
from arrow_ipc.c_data_stream_check import check_record_batch_stream
from byte_buffer.heap_region import HeapRegion
from byte_buffer.shared_aligned_buffer import SharedAlignedBuffer
from containers.slab import Slab


def _schema() raises -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.INT64, nullable=False))
    sb.add_field(Field("s", ArrowType.STRING, nullable=True))
    return sb.build()


def _batch(base: Int64) raises -> RecordBatch:
    var rbb = RecordBatchBuilder.with_capacity(2)
    rbb.add_column(
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list([base, base + 1, base + 2])
        )
    )
    rbb.add_column(
        Column.from_string(
            StringArray.from_strings_with_validity(
                [String("a"), String("b"), String("c")], [True, False, True]
            )
        )
    )
    return rbb.build(_schema())


def _sliced_string_batch() raises -> RecordBatch:
    """Rows 1 and 2 of a three-row STRING column, as a non-zero offset."""
    var s = Column.from_string(
        StringArray.from_strings([String("x"), String("y"), String("z")])
    )
    s._offset = 1
    s._length = 2
    var rbb = RecordBatchBuilder.with_capacity(2)
    rbb.add_column(
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list([Int64(7), Int64(8)])
        )
    )
    rbb.add_column(s^)
    return rbb.build(_schema())


def _probes(ref batches: Slab[RecordBatch]) raises -> List[SharedAlignedBuffer[HeapRegion]]:
    """One share of every column's data buffer: its strong count is 2 while
    only the batch and the probe hold it."""
    var out = List[SharedAlignedBuffer[HeapRegion]]()
    for b in range(len(batches)):
        for c in range(batches[b].num_columns()):
            out.append(batches[b].column_at(c)._data.share())
    return out^


def _assert_held_by_batches_alone(imm probes: List[SharedAlignedBuffer[HeapRegion]]) raises:
    for i in range(len(probes)):
        assert_equal(
            Int(probes[i]._region.count()),
            2,
            "buffer " + String(i) + " is held by more than its batch and the probe",
        )


def _refusal(schema: Schema, ref batches: Slab[RecordBatch]) raises -> String:
    try:
        check_record_batch_stream(schema, batches)
    except e:
        return String(e)
    raise Error("the check passed a stream it must refuse")


def test_a_stream_that_exports_passes_and_leaves_nothing_held() raises:
    var batches = Slab[RecordBatch].with_capacity(2)
    batches.append(_batch(1))
    batches.append(_batch(10))
    var probes = _probes(batches)
    _assert_held_by_batches_alone(probes)
    check_record_batch_stream(_schema(), batches)
    _assert_held_by_batches_alone(probes)


def test_a_column_type_outside_the_interface_is_refused_by_name() raises:
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.INT64, nullable=False))
    sb.add_field(Field("v", ArrowType.UTF8_VIEW, nullable=True))
    var msg = _refusal(sb.build(), Slab[RecordBatch]())
    var head = (
        "ArrowCStreamExport: column 'v' ("
        + String(ArrowType.UTF8_VIEW)
        + ") cannot cross the Arrow C Data Interface: UnsupportedArrowCABIType: "
    )
    assert_true(msg.startswith(head), msg)


def test_an_empty_stream_of_flat_columns_passes() raises:
    check_record_batch_stream(_schema(), Slab[RecordBatch]())


def test_an_empty_stream_with_a_nested_column_is_refused() raises:
    var sb = SchemaBuilder()
    sb.add_field(Field.list_of("l", ArrowType.INT64, nullable=True))
    var msg = _refusal(sb.build(), Slab[RecordBatch]())
    assert_true(
        msg.startswith("ArrowCStream: empty stream with nested column 'l'"), msg
    )


def test_a_batch_with_a_selection_mask_is_refused() raises:
    var batch = _batch(1)
    var mask = BooleanArray.allocate(3)
    mask.set(0, True)
    batch.set_selection_mask(mask^)
    var batches = Slab[RecordBatch].with_capacity(1)
    batches.append(batch^)
    assert_equal(
        _refusal(_schema(), batches),
        "ArrowCStreamExport: batch 0 carries a selection mask; materialize it"
        " before the export, which reads every row",
    )


def test_a_batch_whose_columns_are_not_the_schemas_is_refused() raises:
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.INT64, nullable=False))
    var rbb = RecordBatchBuilder.with_capacity(1)
    rbb.add_column(
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list([Int64(5)])
        )
    )
    var batches = Slab[RecordBatch].with_capacity(2)
    batches.append(_batch(1))
    batches.append(rbb.build(sb.build()))
    assert_equal(
        _refusal(_schema(), batches),
        "ArrowCStreamExport: batch 1 has 1 columns and the schema 2",
    )


def test_a_sliced_string_column_is_refused_and_nothing_is_held() raises:
    var batches = Slab[RecordBatch].with_capacity(2)
    batches.append(_batch(1))
    batches.append(_sliced_string_batch())
    var probes = _probes(batches)
    var msg = _refusal(_schema(), batches)
    var head = (
        "ArrowCStreamExport: column 's' ("
        + String(ArrowType.STRING)
        + ") of batch 1: UnsupportedArrowCABIType: variable-length"
    )
    assert_true(msg.startswith(head), msg)
    _assert_held_by_batches_alone(probes)


def test_a_dictionary_whose_index_width_is_not_the_fields_is_refused() raises:
    var sb = SchemaBuilder()
    sb.add_field(Field.dictionary("d", ArrowType.INT64, nullable=False))
    var rbb = RecordBatchBuilder.with_capacity(1)
    rbb.add_column(
        Column.from_dictionary(
            StringDictionaryArray(
                PrimitiveArray[DType.int32].from_list([Int32(1), Int32(0)]),
                StringArray.from_strings([String("p"), String("q")]),
                2,
            )
        )
    )
    var sb2 = SchemaBuilder()
    sb2.add_field(Field.dictionary("d", ArrowType.INT32, nullable=False))
    var batches = Slab[RecordBatch].with_capacity(1)
    batches.append(rbb.build(sb2.build()))
    var msg = _refusal(sb.build(), batches)
    var head = (
        "ArrowCStreamExport: column 'd' ("
        + String(ArrowType.DICTIONARY)
        + ") of batch 0: "
    )
    assert_true(msg.startswith(head), msg)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
