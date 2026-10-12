# =============================================================================
# The all-COUNT(DISTINCT) row loop carries NO passenger lane
# =============================================================================
#
# ★ THE DEFECT. A change gave `WorkerCDState.consume_batch` a
#   fixed-aggregate PASSENGER LANE (SUM / COUNT / MIN / MAX / MEAN folded on the
#   gid the COUNT(DISTINCT) lane already resolved) and kept a 3-argument
#   all-CD overload "so the existing call sites are untouched". That overload
#   forwarded into the fused body with an EMPTY fixed list, so EVERY grouped
#   COUNT(DISTINCT) batch built the passenger lane's per-batch state and carried
#   its per-row block through the hottest loop in the engine. Measured in the
#   built runner: `consume_batch` 11,431 -> 13,176 B, 90 -> 122 backedges,
#   126 -> 169 calls; an all-CD query +4.32%.
#
# ★ THE FIX. `consume_batch[has_fixed: Bool]` — the all-CD entry instantiates
#   `has_fixed=False`, in which every passenger-lane statement is compiled out.
#
# ⛔ NO VALUE ASSERTION CAN SEE THE DEFECT. Both instantiations produce the same
#   COUNT(DISTINCT) answers; the defect was never a wrong answer. What CAN see
#   it is the state's own per-batch route counters: `stat_fx_batches` counts
#   the batches that ran the passenger-lane setup, and on the all-CD entry it
#   must read 0. Before the fix it equalled `stat_batches`. `stat_batches` is
#   asserted beside it so a zero cannot come from a loop that never ran.
#
# =============================================================================

from std.collections import List
from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import (
    Field, RecordBatch, RecordBatchBuilder, SchemaBuilder,
)
from komira_plan_expr.agg_expr import AGG_SUM

from komira_op_agg_distinct.streaming_agg_count_distinct import (
    WorkerCDState,
)


# Keys 7, 3, 9; values chosen so the per-group distinct counts are 2, 3, 3 and
# do not read the same reversed (a positional-pairing defect cannot pass).
def _keys() -> List[Int64]:
    return [Int64(7), 7, 7, 3, 3, 3, 9, 9, 9, 3]


def _vals() -> List[Int64]:
    return [Int64(100), 100, 101, 200, 201, 200, 100, 300, 301, 202]


def _batch() raises -> RecordBatch:
    var ks = _keys()
    var vs = _vals()
    var n = len(ks)
    var karr = PrimitiveArray[DType.int64].allocate(n)
    var varr = PrimitiveArray[DType.int64].allocate(n)
    for i in range(n):
        karr.store[1](i, Scalar[DType.int64](ks[i]))
        varr.store[1](i, Scalar[DType.int64](vs[i]))
    var rbb = RecordBatchBuilder.with_capacity(2)
    rbb.add_column(Column.from_primitive[DType.int64](karr^))
    rbb.add_column(Column.from_primitive[DType.int64](varr^))
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.INT64, False))
    sb.add_field(Field("v", ArrowType.INT64, False))
    return rbb.build(sb.build())


def _oracle_distinct(key: Int64) -> Int:
    """Linear scan over the RAW lists — no kernel, no hash table."""
    var ks = _keys()
    var vs = _vals()
    var seen = List[Int64]()
    for i in range(len(ks)):
        if ks[i] != key:
            continue
        var found = False
        for j in range(len(seen)):
            if seen[j] == vs[i]:
                found = True
                break
        if not found:
            seen.append(vs[i])
    return len(seen)


def _state_distinct(imm st: WorkerCDState, key: Int64) -> Int:
    """Distinct count of group `key`'s buffered values (the grouped path's
    default append store; the dedup itself runs at finalize)."""
    for g in range(len(st.group_keys)):
        if Int64(st.group_keys[g]) != key:
            continue
        var seen = List[Int64]()
        for i in range(len(st.cd_bufs[0][g])):
            var v = st.cd_bufs[0][g][i]
            var found = False
            for j in range(len(seen)):
                if seen[j] == v:
                    found = True
                    break
            if not found:
                seen.append(v)
        return len(seen)
    return -1


def test_the_all_distinct_entry_runs_no_passenger_lane() raises:
    """⭐ THE REGRESSION TEST. Two batches through the all-CD entry: both are
    counted as grouped batches, and NEITHER may have run the passenger lane.
    Before the fix `stat_fx_batches` read 2 here."""
    var st = WorkerCDState(1)
    var val_idx = List[Int]()
    val_idx.append(1)
    for _ in range(2):
        var batch = _batch()
        st.consume_batch(batch, 0, val_idx)
        _ = batch^
    assert_equal(
        st.stat_batches, 2,
        "vacuity guard: the all-CD entry did not consume both batches, so a"
        " zero passenger count below would prove nothing",
    )
    assert_equal(
        st.stat_fx_batches, 0,
        "the all-COUNT(DISTINCT) entry ran the MIXEDFUSE passenger-lane setup."
        " It must instantiate consume_batch[has_fixed=False], in which the"
        " passenger lane does not exist.",
    )
    assert_equal(st.num_fixed, 0)
    assert_equal(len(st.fx_cells), 0)


def test_the_all_distinct_entry_still_answers_every_group() raises:
    """The specialisation must not change what the all-CD lane stores: every
    row appended, three groups, per-group distinct sets equal to the oracle."""
    var st = WorkerCDState(1)
    var val_idx = List[Int]()
    val_idx.append(1)
    var batch = _batch()
    st.consume_batch(batch, 0, val_idx)
    _ = batch^
    assert_equal(len(st.group_keys), 3)
    # CD-ADJDEDUP (2026-09-26): key 7's second `100` equals its cell's tail
    # and is dropped, not appended — the counters still PARTITION every row.
    assert_equal(st.stat_appends + st.stat_adj_skipped, len(_keys()))
    assert_equal(st.stat_adj_skipped, 1)
    var ks: List[Int64] = [Int64(7), 3, 9]
    for i in range(len(ks)):
        assert_equal(_state_distinct(st, ks[i]), _oracle_distinct(ks[i]))


def test_an_armed_state_refuses_the_all_distinct_entry() raises:
    """A state armed with a fixed slot must NOT be fed through the all-CD
    instantiation: that instantiation has no passenger lane, so it would grow
    groups whose fixed cells are never created and never folded. It REFUSES
    rather than silently answering the fixed aggregate with nothing."""
    var st = WorkerCDState(1)
    var funcs = List[UInt8]()
    funcs.append(AGG_SUM)
    var is_int = List[Bool]()
    is_int.append(True)
    st.configure_fixed(funcs, is_int)
    var val_idx = List[Int]()
    val_idx.append(1)
    var batch = _batch()
    var raised = False
    try:
        st.consume_batch(batch, 0, val_idx)
    except:
        raised = True
    _ = batch^
    assert_true(
        raised,
        "an ARMED state was consumed through the all-CD entry without error;"
        " its fixed cells would be silently empty",
    )
    assert_equal(len(st.group_keys), 0, "the refusal must precede any group")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
