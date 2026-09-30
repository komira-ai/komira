# =============================================================================
# test_arrow_c_stream_table_export.mojo
#   `export_table_as_c_stream` delivers EVERY chunk, in row order, with the
#   TABLE's schema.
# =============================================================================
#
# A chunked result egresses without being stitched. The Arrow C stream is the
# one product egress that never needs a contiguous result: an
# `ArrowArrayStream` IS a sequence of batches and `build_record_batch_stream`
# yields one `get_next` chunk per batch. `export_table_as_c_stream` feeds it
# every chunk of a `Table`.
#
# WHAT THESE PIN, AND WHAT EACH ONE GOES RED AGAINST:
#
#   n == 3   the stream carries THREE chunks, in the table's row order.
#            RED against a helper that concatenates (1 chunk), one that
#            forwards only chunk 0 (1 chunk), and one that drains
#            reverse-then-pop WITHOUT the `reverse()` (3 chunks, wrong order).
#            The row-order leg is the one that matters: chunk COUNT alone is
#            blind to a reversal, and `Table` states its own invariant as
#            "in row order".
#
#   n == 1   byte-for-byte what exporting a single `RecordBatch` produces.
#            This is the shape a single-batch result has.
#
#   n == 0   the schema SURVIVES a chunkless result.
#            `sink.init_sink(rb.schema)` is reachable only from a caller
#            HOLDING a batch; a 0-chunk table has no chunk to read a schema
#            off, which is exactly why `Table` carries the driver's own output
#            schema ("an empty result still has a schema"). RED against any
#            implementation that derives the stream schema from chunk 0 — it
#            exports a 0-column stream, the shape that makes a downstream
#            Project raise `Schema.column_index: no field named '<k>'` instead
#            of returning no rows.
#
# ⚠ THE READ IS `drain_record_batch_stream`, WHICH COPIES. That is fine here
# and would NOT be fine for the ownership tests next door
# (`test_arrow_c_stream_export_independence.mojo` holds the `void*` precisely
# because the import side copies). Nothing here is about lifetime; the question
# is HOW MANY chunks arrive and in WHAT ORDER, and the drain answers it without
# a hand-rolled C walk.
# =============================================================================

from std.memory import alloc

from std.testing import TestSuite, assert_equal

from komira_core.arrow import (
    ArrowType,
    Column,
    Field,
    PrimitiveArray,
    RecordBatch,
    RecordBatchBuilder,
    Schema,
    SchemaBuilder,
)
from komira_core.arrow.c_data_interface import CArrowSchema
from komira_core.arrow.c_data_stream import (
    CArrowArrayStream,
    drain_record_batch_stream,
    release_c_schema,
)
from komira_core.arrow.table import Table
from komira_core.arrow_c_stream_sink import export_table_as_c_stream


def _schema() raises -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.INT64, False))
    return sb.build()


def _chunk(values: List[Scalar[DType.int64]]) raises -> RecordBatch:
    """One single-column INT64 batch holding `values`."""
    var arr = PrimitiveArray[DType.int64].from_list(values)
    var b = RecordBatchBuilder.with_capacity(1)
    b.add_column(Column.from_primitive[DType.int64](arr^))
    return b.build(_schema())


def _out_ptr() -> UnsafePointer[CArrowArrayStream, MutUntrackedOrigin]:
    """A heap-allocated `ArrowArrayStream` for the export to fill.

    HEAP, NOT STACK, and the reason is written down in
    `drain_record_batch_stream`: Mojo does not extend a stack `var`'s lifetime
    through an `UnsafePointer` taken to it, so the slot may be reused before an
    FFI callback writes through the pointer.
    """
    var sp = alloc[CArrowArrayStream](1).unsafe_origin_cast[MutUntrackedOrigin]()
    sp.unsafe_write(CArrowArrayStream())
    return sp


def test_three_chunks_arrive_as_three_stream_chunks_in_row_order() raises:
    """The whole point: a chunked result egresses WITHOUT being stitched.

    RED against a concatenating helper (1 chunk back), against one that
    forwards chunk 0 only (1 chunk back), and against a reverse-then-pop drain
    missing its `reverse()` (3 chunks, rows 30/20/10).
    """
    var chunks = List[RecordBatch]()
    chunks.append(_chunk([Scalar[DType.int64](10), Scalar[DType.int64](11)]))
    chunks.append(_chunk([Scalar[DType.int64](20)]))
    chunks.append(_chunk([Scalar[DType.int64](30), Scalar[DType.int64](31)]))
    var t = Table.from_chunks(chunks^, _schema())
    assert_equal(t.num_chunks(), 3, "fixture: three chunks")
    assert_equal(t.num_rows(), 5, "fixture: five rows")

    var sp = _out_ptr()
    export_table_as_c_stream(t^, sp)
    var got = drain_record_batch_stream(sp)
    sp.free()

    assert_equal(len(got), 3, "the stream carries one chunk per table chunk")
    assert_equal(got[0].num_rows(), 2, "chunk 0 rows")
    assert_equal(got[1].num_rows(), 1, "chunk 1 rows")
    assert_equal(got[2].num_rows(), 2, "chunk 2 rows")
    # ROW ORDER — the leg a chunk-count assertion is blind to.
    assert_equal(Int(got[0].column_value(0, 0)), 10, "row 0")
    assert_equal(Int(got[0].column_value(0, 1)), 11, "row 1")
    assert_equal(Int(got[1].column_value(0, 0)), 20, "row 2")
    assert_equal(Int(got[2].column_value(0, 0)), 30, "row 3")
    assert_equal(Int(got[2].column_value(0, 1)), 31, "row 4")


def test_one_chunk_is_what_the_open_coded_block_produced() raises:
    """The single-batch shape — a result that is one `RecordBatch`.

    Must be value-identical to exporting that batch directly.
    """
    var chunks = List[RecordBatch]()
    chunks.append(
        _chunk([
            Scalar[DType.int64](7),
            Scalar[DType.int64](8),
            Scalar[DType.int64](9),
        ])
    )
    var t = Table.from_chunks(chunks^, _schema())

    var sp = _out_ptr()
    export_table_as_c_stream(t^, sp)
    var got = drain_record_batch_stream(sp)
    sp.free()

    assert_equal(len(got), 1, "one chunk in, one chunk out")
    assert_equal(got[0].num_rows(), 3, "row count")
    assert_equal(got[0].schema.num_columns(), 1, "column count")
    assert_equal(got[0].schema.field_name(0), String("k"), "column name")
    assert_equal(Int(got[0].column_value(0, 0)), 7, "row 0")
    assert_equal(Int(got[0].column_value(0, 1)), 8, "row 1")
    assert_equal(Int(got[0].column_value(0, 2)), 9, "row 2")


def test_a_chunkless_table_still_exports_its_schema() raises:
    """⭐ THE SCHEMA OF A CHUNKLESS RESULT.

    `sink.init_sink(rb.schema.copy())` needs a batch in hand. A 0-chunk table
    has none, and the schema still has to reach the consumer — otherwise a
    zero-row answer arrives with NO COLUMNS, and a downstream Project raises
    `Schema.column_index: no field named 'k'` rather than returning no rows.

    ⚠ THE ASSERTION IS ON `get_schema`, NOT ON THE DRAIN. A drain of a
    chunkless stream returns an EMPTY `Slab` whatever the schema says, so
    `len(got) == 0` is TRUE for a correct export and for a schema-less one
    alike — which is why this test reads the C struct the way a consumer does.
    RED against any implementation that derives the stream schema from chunk 0:
    `n_children` comes back 0 instead of 1.
    """
    var t = Table.from_chunks(List[RecordBatch](), _schema())
    assert_equal(t.num_chunks(), 0, "fixture: no chunks")

    var sp = _out_ptr()
    export_table_as_c_stream(t^, sp)

    # `get_schema` into a heap-allocated struct — same shape, and the same
    # stack-lifetime reason, as `_out_ptr` above.
    var cs = alloc[CArrowSchema](1).unsafe_origin_cast[MutUntrackedOrigin]()
    cs.unsafe_write(CArrowSchema())
    ref st = sp[]
    var rc = st.get_schema(sp.bitcast[NoneType](), cs)
    assert_equal(Int(rc), 0, "get_schema rc")
    assert_equal(
        Int(cs[].n_children), 1, "the chunkless stream still declares 1 column"
    )
    # Release the schema the producer allocated — the consumer's obligation.
    release_c_schema(cs)
    cs.free()

    # The drain is still exercised, but only as the second leg: it must accept
    # a chunkless stream rather than raise.
    var got = drain_record_batch_stream(sp)
    sp.free()
    assert_equal(len(got), 0, "no chunks to deliver")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
