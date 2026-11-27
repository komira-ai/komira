# =============================================================================
# The closed variants of source, operator and sink
# =============================================================================
#
# What these tests prove:
#
#   * A source variant calls the member of the slot its tag names: the first
#     slot gives a fake source's morsel and hints, the second a published-batch
#     source's chunk and hints, and the tag reads back as the slot.
#   * A slot filled with `NoSource`, `NoOperator` or `NoSink` raises when used
#     instead of doing nothing.
#   * An operator variant runs the member of its slot: the same morsel through
#     an adding member and a multiplying member gives different values.
#   * The fourth operator slot works as the first three do: a variant built
#     with `fourth` reports OP_TAG_FOURTH and forwards `execute` and
#     `metrics_snapshot` to its member (a multiplying fake, and a join probe
#     whose metrics are empty before a morsel and not after). The default
#     fourth slot is `NoOperator`, which raises when used, and the three-slot
#     name is unchanged.
#   * A sink variant forwards the whole life of a sink to its member: sized,
#     consumed by two workers, combined in worker id order, finalized and taken.
#   * The fourth sink slot works as the first three do: a variant built with
#     `fourth` reports SINK_TAG_FOURTH and forwards `resize_worker_state`,
#     `consume`, `combine`, `finalize` and `take_output` to its member (the
#     same rows as the first slot gives, tallied by the member), the other
#     slots still reach their own members, and the default fourth slot is
#     `NoSink`, which raises when used.
#   * The fifth sink slot works as the fourth does: a variant built with
#     `fifth` reports SINK_TAG_FIFTH and forwards the same five calls to its
#     member, a fourth-slot member of the same name still reaches its own
#     member, and the default fifth slot is `NoSink`, which raises when used.
#   * Each hook of the source trait that takes no pointer reaches the member of
#     the slot: bypass columns, dictionary preservation, prefetch and count only
#     each change what the member recorded.
#   * The hook that sets rows per morsel and the decode-filter query reach the
#     member's defaults without error.

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from morsel.pipeline_execution import PipelineExecution
from pipeline_exec.join_harness import (
    customer_batch,
    expect_rows,
    expected_rows,
    key_names,
    orders_batch,
    probe_op,
    rows_of,
)
from pipeline_exec.fake_members import (
    FakeBatchSource,
    FakeCountSink,
    FakeOp,
    FakeSink,
    FakeSource,
    OP_ADD,
    OP_MUL,
    SOURCE_CURSOR,
)
from pipeline_exec.fake_support import (
    SLOT_COMBINES,
    SLOT_CONSUMED_MORSELS,
    SLOT_FINALIZES,
    SLOT_TAKES,
    SLOT_CONSUMED_ROWS,
    SLOT_HOOKS_SEEN,
    Tally,
    batch_values,
    fake_values,
    int64_batch,
)
from pipeline_exec.op_hash_probe import HashProbeOp, HashProbeShared
from pipeline_exec.op_variant import (
    OP_TAG_FIRST,
    OP_TAG_FOURTH,
    OP_TAG_SECOND,
    OP_TAG_THIRD,
    OpVariant,
)
from pipeline_exec.pipeline_sink import (
    SINK_TAG_FIRST,
    SINK_TAG_FIFTH,
    SINK_TAG_FOURTH,
    SINK_TAG_SECOND,
    SINK_TAG_THIRD,
    PipelineSink,
)
from pipeline_exec.source_variant import (
    SOURCE_TAG_FIRST,
    SOURCE_TAG_SECOND,
    SOURCE_TAG_THIRD,
    SourceVariant,
)
from pipeline_exec.unused_members import NoOperator, NoSink, NoSource
from morsel.morsel import Morsel

comptime Sources = SourceVariant[FakeSource, FakeBatchSource, NoSource]
comptime Ops = OpVariant[FakeOp, FakeOp, NoOperator]
comptime FourOps = OpVariant[FakeOp, FakeOp, NoOperator, FakeOp]
comptime JoinOps = OpVariant[FakeOp, FakeOp, NoOperator, HashProbeOp]
comptime Sinks = PipelineSink[FakeSink, FakeCountSink, NoSink]
comptime FourSinks = PipelineSink[FakeSink, FakeCountSink, NoSink, FakeCountSink]
comptime FiveSinks = PipelineSink[
    FakeSink, FakeCountSink, NoSink, FakeSink, FakeCountSink
]


def test_source_variant_calls_the_member_of_its_slot() raises:
    var first = Sources.first(
        FakeSource(SOURCE_CURSOR, 3, 2, Tally())
    )
    assert_equal(Int(first.tag()), Int(SOURCE_TAG_FIRST))
    assert_equal(first.row_count_hint(), 6)
    assert_equal(first.partition_hint(), 3)
    var first_pull = first.next_morsel(0)
    var m = first_pull.take()
    assert_equal(m.morsel_id, 0)
    var got = batch_values(m.batch)
    var want = fake_values(0, 2)
    assert_equal(len(got), len(want))
    for i in range(len(want)):
        assert_equal(got[i], want[i])

    var vals = List[Int64]()
    for i in range(7):
        vals.append(Int64(i))
    var second = Sources.second(FakeBatchSource(vals^, 4, Tally()))
    assert_equal(Int(second.tag()), Int(SOURCE_TAG_SECOND))
    assert_equal(second.row_count_hint(), 7)
    assert_equal(second.partition_hint(), 1)
    var chunk_pull = second.next_morsel(0)
    var chunk = chunk_pull.take()
    assert_equal(chunk.num_rows(), 4)
    var tail_pull = second.next_morsel(0)
    var tail = tail_pull.take()
    assert_equal(tail.num_rows(), 3)
    assert_false(Bool(second.next_morsel(0)))

    second.set_morsel_rows(16)
    assert_false(second.has_decode_filter())


def test_source_variant_forwards_every_hook_that_takes_no_pointer() raises:
    var tally = Tally()
    var src = Sources.first(FakeSource(SOURCE_CURSOR, 1, 1, tally.share()))
    src.set_bypass_columns(List[Int]())
    assert_equal(tally.get(SLOT_HOOKS_SEEN), 1)
    src.set_dict_preservation(True)
    assert_equal(tally.get(SLOT_HOOKS_SEEN), 3)
    src.set_prefetch_enabled(True)
    assert_equal(tally.get(SLOT_HOOKS_SEEN), 7)
    src.set_count_only(True)
    assert_equal(tally.get(SLOT_HOOKS_SEEN), 15)


def test_unused_source_slot_raises() raises:
    var third = Sources.third(NoSource())
    assert_equal(Int(third.tag()), Int(SOURCE_TAG_THIRD))
    try:
        _ = third.next_morsel(0)
        assert_true(False, "an unused source slot must raise")
    except e:
        assert_true("source slot is unused" in String(e), String(e))
    assert_equal(third.row_count_hint(), 0)
    assert_equal(third.partition_hint(), 0)


def test_operator_variant_runs_the_member_of_its_slot() raises:
    var add = Ops.first(FakeOp(OP_ADD, 5, Tally()))
    var mul = Ops.second(FakeOp(OP_MUL, 5, Tally()))
    assert_equal(Int(add.tag()), Int(OP_TAG_FIRST))
    assert_equal(Int(mul.tag()), Int(OP_TAG_SECOND))
    var a = Morsel(int64_batch(fake_values(1, 3)), 1, 0)
    var b = Morsel(int64_batch(fake_values(1, 3)), 1, 0)
    assert_true(add.execute(a).is_need_more_input())
    assert_true(mul.execute(b).is_need_more_input())
    var av = batch_values(a.batch)
    var bv = batch_values(b.batch)
    for r in range(3):
        assert_equal(av[r], Int64(100 + r + 5))
        assert_equal(bv[r], Int64((100 + r) * 5))
    assert_equal(add.metrics_snapshot().count(), 0)


def test_unused_operator_slot_raises() raises:
    var none = Ops.third(NoOperator())
    var m = Morsel(int64_batch(fake_values(0, 1)), 0, 0)
    try:
        _ = none.execute(m)
        assert_true(False, "an unused operator slot must raise")
    except e:
        assert_true("operator slot is unused" in String(e), String(e))


def test_operator_variant_runs_the_member_of_its_fourth_slot() raises:
    var mul = FourOps.fourth(FakeOp(OP_MUL, 7, Tally()))
    assert_equal(Int(mul.tag()), Int(OP_TAG_FOURTH))
    var m = Morsel(int64_batch(fake_values(1, 3)), 1, 0)
    assert_true(mul.execute(m).is_need_more_input())
    var got = batch_values(m.batch)
    for r in range(3):
        assert_equal(got[r], Int64((100 + r) * 7))
    assert_equal(mul.metrics_snapshot().count(), 0)
    var first = FourOps.first(FakeOp(OP_ADD, 5, Tally()))
    assert_equal(Int(first.tag()), Int(OP_TAG_FIRST))
    var again = Morsel(int64_batch(fake_values(1, 3)), 1, 0)
    assert_true(first.execute(again).is_need_more_input())
    assert_equal(batch_values(again.batch)[0], Int64(105))


def test_operator_variant_forwards_a_probe_in_its_fourth_slot() raises:
    var spec = probe_op(1, key_names("o_custkey"), key_names("c_custkey"))
    var shared = HashProbeShared(spec, customer_batch(10))
    var op = JoinOps.fourth(shared.make())
    assert_equal(Int(op.tag()), Int(OP_TAG_FOURTH))
    assert_equal(op.metrics_snapshot().count(), 0)
    var m = Morsel(orders_batch(0, 30), 0, 0)
    assert_true(op.execute(m).is_need_more_input())
    var want = expected_rows(
        orders_batch(0, 30),
        customer_batch(10),
        key_names("o_custkey"),
        key_names("c_custkey"),
    )
    assert_true(len(want) > 0)
    expect_rows(rows_of(m.batch), want, "fourth slot probe")
    assert_true(op.metrics_snapshot().count() > 0)


def test_the_default_fourth_operator_slot_raises_and_the_slot_tags_are_unchanged() raises:
    assert_equal(Int(OP_TAG_FIRST), 0)
    assert_equal(Int(OP_TAG_SECOND), 1)
    assert_equal(Int(OP_TAG_THIRD), 2)
    assert_equal(Int(OP_TAG_FOURTH), 3)
    var none = Ops.fourth(NoOperator())
    assert_equal(Int(none.tag()), Int(OP_TAG_FOURTH))
    var m = Morsel(int64_batch(fake_values(0, 1)), 0, 0)
    try:
        _ = none.execute(m)
        assert_true(False, "an unused fourth operator slot must raise")
    except e:
        assert_true("operator slot is unused" in String(e), String(e))
    assert_equal(none.metrics_snapshot().count(), 0)


def test_sink_variant_forwards_a_sinks_whole_life() raises:
    var tally = Tally()
    var sink = Sinks.first(FakeSink(tally.share()))
    assert_equal(Int(sink.tag()), Int(SINK_TAG_FIRST))
    sink.resize_worker_state(2)
    sink.consume(1, Morsel(int64_batch(fake_values(7, 2)), 7, 1))
    sink.consume(0, Morsel(int64_batch(fake_values(3, 2)), 3, 0))
    var pipe = PipelineExecution(2, 0)
    sink.combine(pipe)
    sink.finalize()
    var out = sink.take_output()
    var got = batch_values(out)
    assert_equal(len(got), 4)
    # Worker 0's rows come first, whichever worker consumed first.
    assert_equal(got[0], Int64(300))
    assert_equal(got[1], Int64(301))
    assert_equal(got[2], Int64(700))
    assert_equal(got[3], Int64(701))
    assert_equal(tally.get(SLOT_CONSUMED_ROWS), 4)

    var count = Sinks.second(FakeCountSink(Tally()))
    assert_equal(Int(count.tag()), Int(SINK_TAG_SECOND))
    count.resize_worker_state(1)
    count.consume(0, Morsel(int64_batch(fake_values(0, 5)), 0, 0))
    count.consume(0, Morsel(int64_batch(fake_values(1, 4)), 1, 0))
    count.combine(pipe)
    count.finalize()
    var counted = batch_values(count.take_output())
    assert_equal(len(counted), 1)
    assert_equal(counted[0], Int64(9))


def test_unused_sink_slot_raises() raises:
    var none = Sinks.third(NoSink())
    assert_equal(Int(none.tag()), Int(SINK_TAG_THIRD))
    try:
        none.consume(0, Morsel(int64_batch(fake_values(0, 1)), 0, 0))
        assert_true(False, "an unused sink slot must raise")
    except e:
        assert_true("sink slot is unused" in String(e), String(e))
    try:
        none.finalize()
        assert_true(False, "an unused sink slot must raise")
    except e:
        assert_true("sink slot is unused" in String(e), String(e))
    try:
        _ = none.take_output()
        assert_true(False, "an unused sink slot must raise")
    except e:
        assert_true("not implemented" in String(e), String(e))


def test_sink_variant_forwards_a_sinks_whole_life_from_its_fourth_slot() raises:
    var tally = Tally()
    var sink = FourSinks.fourth(FakeCountSink(tally.share()))
    assert_equal(Int(sink.tag()), Int(SINK_TAG_FOURTH))
    sink.resize_worker_state(2)
    sink.consume(1, Morsel(int64_batch(fake_values(7, 2)), 7, 1))
    sink.consume(0, Morsel(int64_batch(fake_values(3, 5)), 3, 0))
    var pipe = PipelineExecution(2, 0)
    sink.combine(pipe)
    sink.finalize()
    var counted = batch_values(sink.take_output())
    assert_equal(len(counted), 1)
    assert_equal(counted[0], Int64(7))
    assert_equal(tally.get(SLOT_CONSUMED_MORSELS), 2)
    assert_equal(tally.get(SLOT_CONSUMED_ROWS), 7)
    assert_equal(tally.get(SLOT_COMBINES), 1)
    assert_equal(tally.get(SLOT_FINALIZES), 1)
    assert_equal(tally.get(SLOT_TAKES), 1)
    var first_tally = Tally()
    var first = FourSinks.first(FakeSink(first_tally.share()))
    assert_equal(Int(first.tag()), Int(SINK_TAG_FIRST))
    first.resize_worker_state(1)
    first.consume(0, Morsel(int64_batch(fake_values(1, 3)), 1, 0))
    first.combine(pipe)
    first.finalize()
    assert_equal(len(batch_values(first.take_output())), 3)
    assert_equal(first_tally.get(SLOT_CONSUMED_ROWS), 3)
    assert_equal(tally.get(SLOT_CONSUMED_ROWS), 7)


def test_the_default_fourth_sink_slot_raises_and_the_slot_tags_are_unchanged() raises:
    assert_equal(Int(SINK_TAG_FIRST), 0)
    assert_equal(Int(SINK_TAG_SECOND), 1)
    assert_equal(Int(SINK_TAG_THIRD), 2)
    assert_equal(Int(SINK_TAG_FOURTH), 3)
    var none = Sinks.fourth(NoSink())
    assert_equal(Int(none.tag()), Int(SINK_TAG_FOURTH))
    try:
        none.consume(0, Morsel(int64_batch(fake_values(0, 1)), 0, 0))
        assert_true(False, "an unused fourth sink slot must raise")
    except e:
        assert_true("sink slot is unused" in String(e), String(e))
    try:
        none.finalize()
        assert_true(False, "an unused fourth sink slot must raise")
    except e:
        assert_true("sink slot is unused" in String(e), String(e))
    try:
        _ = none.take_output()
        assert_true(False, "an unused fourth sink slot must raise")
    except e:
        assert_true("not implemented" in String(e), String(e))


def test_sink_variant_forwards_a_sinks_whole_life_from_its_fifth_slot() raises:
    var tally = Tally()
    var sink = FiveSinks.fifth(FakeCountSink(tally.share()))
    assert_equal(Int(sink.tag()), Int(SINK_TAG_FIFTH))
    sink.resize_worker_state(2)
    sink.consume(1, Morsel(int64_batch(fake_values(7, 2)), 7, 1))
    sink.consume(0, Morsel(int64_batch(fake_values(3, 5)), 3, 0))
    var pipe = PipelineExecution(2, 0)
    sink.combine(pipe)
    sink.finalize()
    var counted = batch_values(sink.take_output())
    assert_equal(len(counted), 1)
    assert_equal(counted[0], Int64(7))
    assert_equal(tally.get(SLOT_CONSUMED_MORSELS), 2)
    assert_equal(tally.get(SLOT_CONSUMED_ROWS), 7)
    assert_equal(tally.get(SLOT_COMBINES), 1)
    assert_equal(tally.get(SLOT_FINALIZES), 1)
    assert_equal(tally.get(SLOT_TAKES), 1)
    # The fourth slot of the same variant holds a FakeSink: every row comes
    # back, and the fifth slot's member sees none of them.
    var fourth_tally = Tally()
    var fourth = FiveSinks.fourth(FakeSink(fourth_tally.share()))
    assert_equal(Int(fourth.tag()), Int(SINK_TAG_FOURTH))
    fourth.resize_worker_state(1)
    fourth.consume(0, Morsel(int64_batch(fake_values(1, 3)), 1, 0))
    fourth.combine(pipe)
    fourth.finalize()
    assert_equal(len(batch_values(fourth.take_output())), 3)
    assert_equal(fourth_tally.get(SLOT_CONSUMED_ROWS), 3)
    assert_equal(tally.get(SLOT_CONSUMED_ROWS), 7)


def test_the_default_fifth_sink_slot_raises() raises:
    assert_equal(Int(SINK_TAG_FIFTH), 4)
    var none = Sinks.fifth(NoSink())
    assert_equal(Int(none.tag()), Int(SINK_TAG_FIFTH))
    none.resize_worker_state(1)
    try:
        none.consume(0, Morsel(int64_batch(fake_values(0, 1)), 0, 0))
        assert_true(False, "an unused fifth sink slot must raise")
    except e:
        assert_true("sink slot is unused" in String(e), String(e))
    try:
        none.finalize()
        assert_true(False, "an unused fifth sink slot must raise")
    except e:
        assert_true("sink slot is unused" in String(e), String(e))
    # The trait's default combine does nothing, so it reaches NoSink quietly.
    var pipe = PipelineExecution(1, 0)
    none.combine(pipe)
    try:
        _ = none.take_output()
        assert_true(False, "an unused fifth sink slot must raise")
    except e:
        assert_true("not implemented" in String(e), String(e))


def main() raises:
    var suite = TestSuite()
    suite.test[test_source_variant_calls_the_member_of_its_slot]()
    suite.test[test_source_variant_forwards_every_hook_that_takes_no_pointer]()
    suite.test[test_unused_source_slot_raises]()
    suite.test[test_operator_variant_runs_the_member_of_its_slot]()
    suite.test[test_unused_operator_slot_raises]()
    suite.test[test_operator_variant_runs_the_member_of_its_fourth_slot]()
    suite.test[test_operator_variant_forwards_a_probe_in_its_fourth_slot]()
    suite.test[
        test_the_default_fourth_operator_slot_raises_and_the_slot_tags_are_unchanged
    ]()
    suite.test[test_sink_variant_forwards_a_sinks_whole_life]()
    suite.test[test_unused_sink_slot_raises]()
    suite.test[test_sink_variant_forwards_a_sinks_whole_life_from_its_fourth_slot]()
    suite.test[
        test_the_default_fourth_sink_slot_raises_and_the_slot_tags_are_unchanged
    ]()
    suite.test[test_sink_variant_forwards_a_sinks_whole_life_from_its_fifth_slot]()
    suite.test[test_the_default_fifth_sink_slot_raises]()
    suite^.run()
