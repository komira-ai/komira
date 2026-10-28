# =============================================================================
# CD-LASTKEY — the grouped COUNT(DISTINCT) row loop keeps a
# ONE-ENTRY (key, gid) memo in front of the out-of-window `group_map` probe.
#
# WHAT IS PINNED, against an oracle computed from the raw arrays:
#
#   1. NON-VACUITY. The fixture FREEZES the dense window (its keys span far
#      more than `_CD_DENSE_GID_DOMAIN_CAP`), so its out-of-window rows really
#      take the Dict arm, and the oracle's hit count is > 0.
#   2. THE MEMO RAN EXACTLY AS OFTEN AS IT SHOULD. `stat_gid_lastkey` equals
#      the count of out-of-window rows whose key equals the previous
#      out-of-window row's key IN THE SAME BATCH (the memo is a per-batch
#      local; a dense-window row between two such rows does not disturb it).
#   3. NOTHING ELSE MOVED. The ON and OFF (`lastkey_on = False`) arms
#      produce the SAME `group_keys` index
#      for index and the SAME cell contents value for value — the memo changes
#      how a gid is found, never which gid.
#   4. THE COUNTERS STILL PARTITION. `stat_gid_dense + stat_gid_dict` is the
#      non-NULL key row count on both arms (a memo hit is a Dict-arm row).
# =============================================================================

from std.collections import List
from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import (
    Field, RecordBatch, RecordBatchBuilder, SchemaBuilder,
)

from komira_op_agg_distinct.streaming_agg_count_distinct import (
    WorkerCDState,
)

# The first key seeds the dense window; every other key sits > 65,536 away
# from it and from each other, so the window freezes on the second key and
# only SEED rows ever take the dense branch again.
comptime _SEED: Int64 = 7
comptime _FAR: Int64 = 1_000_000_000_000


def _key_at(i: Int) -> Int64:
    """Runs of 5 rows per key over 4 far keys, with a SEED row every 11th row
    (a dense-window row landing inside an out-of-window run)."""
    if i == 0 or i % 11 == 0:
        return _SEED
    var r = (i // 5) % 4
    if r == 0:
        return _FAR
    if r == 1:
        return -_FAR
    if r == 2:
        return 3 * _FAR
    return 5 * _FAR + 17


def _build(lo: Int, n: Int) raises -> RecordBatch:
    var rbb = RecordBatchBuilder.with_capacity(2)
    var karr = PrimitiveArray[DType.int64].allocate(n)
    var varr = PrimitiveArray[DType.int64].allocate(n)
    for j in range(n):
        karr.store[1](j, Scalar[DType.int64](_key_at(lo + j)))
        varr.store[1](j, Scalar[DType.int64](Int64(((lo + j) // 3) % 13)))
    rbb.add_column(Column.from_primitive[DType.int64](karr^))
    rbb.add_column(Column.from_primitive[DType.int64](varr^))
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.INT64, False))
    sb.add_field(Field("v", ArrowType.INT64, False))
    return rbb.build(sb.build())


def _run(imm spans: List[Int], lastkey: Bool) raises -> WorkerCDState:
    var st = WorkerCDState(1)
    st.lastkey_on = lastkey
    var val_idx = List[Int]()
    val_idx.append(1)
    var lo = 0
    for s in range(len(spans)):
        var batch = _build(lo, spans[s])
        st.consume_batch(batch, 0, val_idx)
        _ = batch^
        lo += spans[s]
    return st^


def _oracle_hits(imm spans: List[Int]) -> Int:
    var hits = 0
    var lo = 0
    for s in range(len(spans)):
        var live = False
        var last = Int64(0)
        for j in range(spans[s]):
            var k = _key_at(lo + j)
            if k == _SEED:
                continue
            if live and k == last:
                hits += 1
            else:
                last = k
                live = True
        lo += spans[s]
    return hits


def _check(imm spans: List[Int], what: String) raises:
    var on = _run(spans, True)
    var off = _run(spans, False)
    var n = 0
    for s in range(len(spans)):
        n += spans[s]
    var want = _oracle_hits(spans)
    # 1. non-vacuity
    assert_true(on.dense_frozen, what + ": the fixture must freeze the window")
    assert_true(want > 0, what + ": vacuity guard — no memo hit is possible")
    # 2. exact hit count, and none on the kill-switch arm
    assert_equal(on.stat_gid_lastkey, want, what + ": memo hits")
    assert_equal(off.stat_gid_lastkey, 0, what + ": OFF arm used the memo")
    # 4. partition, both arms
    assert_equal(on.stat_gid_dense + on.stat_gid_dict, n, what + ": ON partition")
    assert_equal(
        off.stat_gid_dense + off.stat_gid_dict, n, what + ": OFF partition"
    )
    # 3. identical groups and cells
    assert_equal(len(on.group_keys), len(off.group_keys), what + ": groups")
    for g in range(len(off.group_keys)):
        assert_equal(on.group_keys[g], off.group_keys[g], what + ": key order")
        ref a = on.cd_bufs[0][g]
        ref b = off.cd_bufs[0][g]
        assert_equal(len(a), len(b), what + ": cell length, gid " + String(g))
        for i in range(len(b)):
            assert_equal(a[i], b[i], what + ": cell value, gid " + String(g))


def test_the_memo_is_exact_and_changes_no_gid() raises:
    var spans: List[Int] = [4096]
    _check(spans, "one batch")


def test_the_memo_resets_at_a_batch_boundary() raises:
    """Batch sizes that cut runs mid-way: the first out-of-window row of a
    batch is always a MISS (per-batch memo), and the oracle says so too."""
    var spans: List[Int] = [1001, 1003, 997, 7]
    _check(spans, "four batches")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
