# =============================================================================
# SINK_COLLECT
# =============================================================================
#
# `CollectSink` is driven by hand: workers consume morsels of the sample table
# into their own slots, the sink is combined once, and the output is taken.
# What these tests prove:
#
#   * The output is ordered by the position the source stamped on each morsel,
#     (partition id, origin hint), whichever worker held it and whatever order
#     they arrived in; a hundred morsels arriving in reverse order, across
#     several workers, come out in order.
#   * Morsels with the same position keep the order of their workers' slots.
#   * A morsel carrying a selection mask contributes only its selected rows; a
#     morsel with no rows contributes nothing.
#   * With no morsel at all the output is a batch of no rows with the schema the
#     sink was built with; built with no schema, the sink refuses by name.
#   * The output is read only after `combine`, and a worker id outside the
#     sized slots is refused.

from std.testing import (
    TestSuite,
    assert_equal,
    assert_raises,
    assert_true,
)

from komira_arrow.boolean_array import BooleanArray
from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import RecordBatch, Schema
from komira_morsel.morsel import Morsel
from komira_morsel.pipeline_execution import PipelineExecution
from komira_pipeline_exec.plan_harness import (
    column_names,
    int64_column,
    sample_batch,
)
from komira_pipeline_exec.sink_collect import CollectSink

comptime WORKERS = 4


def _sink(var schema: Optional[Schema] = None) -> CollectSink:
    var sink = CollectSink(schema^)
    sink.resize_worker_state(WORKERS)
    return sink^


def _finish(mut sink: CollectSink) raises -> RecordBatch:
    var pipeline = PipelineExecution(WORKERS, 0)
    sink.combine(pipeline)
    sink.finalize()
    return sink.take_output()


def _expect(got: List[Int], want: List[Int]) raises:
    assert_equal(len(got), len(want))
    for i in range(len(want)):
        assert_equal(got[i], want[i], "element " + String(i))


def test_morsels_come_out_in_the_order_of_their_positions() raises:
    var sink = _sink()
    # Three morsels of two rows, arriving 3, 1, 2 over two workers.
    sink.consume(0, Morsel(sample_batch(4, 2), 0, 3))
    sink.consume(1, Morsel(sample_batch(0, 2), 1, 1))
    sink.consume(0, Morsel(sample_batch(2, 2), 2, 2))
    var out = _finish(sink)
    _expect(int64_column(out, 0), [0, 1, 2, 3, 4, 5])


def test_origin_hint_orders_the_morsels_of_one_partition() raises:
    var sink = _sink()
    sink.consume(2, Morsel(sample_batch(4, 2), 0, 7, 2))
    sink.consume(1, Morsel(sample_batch(0, 2), 1, 7, 0))
    sink.consume(3, Morsel(sample_batch(2, 2), 2, 7, 1))
    var out = _finish(sink)
    _expect(int64_column(out, 0), [0, 1, 2, 3, 4, 5])


def test_equal_positions_keep_the_order_of_the_worker_slots() raises:
    var sink = _sink()
    # All at one position: worker 0's morsels (in arrival order), then worker 2's.
    sink.consume(2, Morsel(sample_batch(20, 1), 0, 5))
    sink.consume(0, Morsel(sample_batch(10, 1), 1, 5))
    sink.consume(0, Morsel(sample_batch(11, 1), 2, 5))
    sink.consume(2, Morsel(sample_batch(21, 1), 3, 5))
    var out = _finish(sink)
    _expect(int64_column(out, 0), [10, 11, 20, 21])


def test_a_hundred_morsels_in_reverse_order_come_out_in_order() raises:
    var sink = _sink()
    for k in range(100):
        var p = 99 - k
        # Two morsels share each position, so equal keys are exercised too.
        sink.consume(k % WORKERS, Morsel(sample_batch(p * 4, 2), k, p // 2))
    var out = _finish(sink)
    var got = int64_column(out, 0)
    assert_equal(len(got), 200)
    # Positions are non-decreasing: the first row of each morsel is p * 4.
    var last_pos = -1
    for i in range(0, 200, 2):
        var p = got[i] // 4
        assert_true(p // 2 >= last_pos, "row " + String(i))
        last_pos = p // 2


def test_a_masked_morsel_contributes_only_its_selected_rows() raises:
    var sink = _sink()
    var batch = sample_batch(0, 6)
    var mask = BooleanArray.allocate(6)
    mask.set(1, True)
    mask.set(4, True)
    batch.set_selection_mask(mask^)
    sink.consume(0, Morsel(batch^, 0, 0))
    sink.consume(0, Morsel(sample_batch(6, 0), 1, 1))
    sink.consume(0, Morsel(sample_batch(10, 2), 2, 2))
    var out = _finish(sink)
    assert_true(not out.has_selection_mask())
    _expect(int64_column(out, 0), [1, 4, 10, 11])


def test_with_no_rows_the_output_has_the_schema_it_was_built_with() raises:
    var schema = sample_batch(0, 1).schema.copy()
    var sink = _sink(Optional(schema^))
    var out = _finish(sink)
    assert_equal(out.num_rows(), 0)
    assert_equal(out.num_columns(), 3)
    var names = column_names(out)
    assert_equal(names[0], "a")
    assert_equal(names[1], "b")
    assert_equal(names[2], "s")
    assert_true(out.schema.field_arrow_type(2) == ArrowType.STRING)

    # Morsels that carry no selected row leave the sink empty too.
    var sink2 = _sink(Optional(sample_batch(0, 1).schema.copy()))
    var batch = sample_batch(0, 3)
    batch.set_selection_mask(BooleanArray.allocate(3))
    sink2.consume(1, Morsel(batch^, 0, 0))
    assert_equal(_finish(sink2).num_rows(), 0)


def test_with_no_rows_and_no_schema_the_sink_refuses() raises:
    var sink = _sink()
    with assert_raises(contains="output schema could not be derived"):
        _ = _finish(sink)


def test_the_output_is_not_read_before_combine() raises:
    var sink = _sink()
    sink.consume(0, Morsel(sample_batch(0, 2), 0, 0))
    with assert_raises(contains="before it was combined"):
        _ = sink.take_output()


def test_a_worker_outside_the_slots_is_refused() raises:
    var sink = _sink()
    with assert_raises(contains="worker slots"):
        sink.consume(WORKERS, Morsel(sample_batch(0, 2), 0, 0))
    with assert_raises(contains="worker slots"):
        sink.consume(-1, Morsel(sample_batch(0, 2), 0, 0))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
