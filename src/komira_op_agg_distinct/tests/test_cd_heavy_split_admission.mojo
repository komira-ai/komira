# =============================================================================
# The heavy-group split: which groups are split, and the pair bucket
# =============================================================================
#
# The grouped COUNT(DISTINCT) driver owns every row by its GROUP hash, so a
# group holding 90% of the rows is one worker's job. A group whose sampled
# share passes the admission is instead owned PER DISTINCT PAIR
# (`cd_pair_bucket(group hash, value, K)`), and the driver folds its
# per-worker partial counts back into one row (`agg_cd_heavy_split`).
#
# These are the pure pieces of that split:
#   * `cd_heavy_groups` (the fused route's admission): a share above 2/K is
#     heavy, one at or below is not, K < 2 has nothing to spread across, the
#     list is capped at `CD_HEAVY_MAX`, heaviest first, ties broken by hash;
#   * `cd_split_groups` (the driver's admission): above 1/(4K), not at it;
#   * `cd_pair_bucket`: in [0, K), a pure function of (group, value), and one
#     group's pairs spread evenly over every worker (a bucket that ignored the
#     value would put them all on one worker).
#
# The split through the driver (the busiest worker's rows, the fold back into
# one row per group, the serial twin) is tested with the driver.
# =============================================================================

from std.collections import Dict, List, Set
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import (
    Field, RecordBatch, RecordBatchBuilder, SchemaBuilder,
)

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.runtime import PLACEMENT_FIXED, PerCoreAsyncRuntime

from komira_op_agg_distinct.agg_cd_heavy_split import (
    CD_HEAVY_MAX,
    cd_heavy_groups,
    cd_split_groups,
    cd_heavy_groups_count,
    cd_heavy_merged_count,
    cd_pair_bucket,
    cd_worker_max_rows_last,
    cd_worker_rows_scanned_total_last,
    cd_worker_rows_total_last,
    reset_cd_heavy_counters,
)


# At or above `_PARALLEL_CD_MIN_ROWS` (65_536) — asserted in `_run`, never
# assumed. 80,000 rows at 4 workers resolves K = min(4, 80000 // 16384) = 4.
comptime _N: Int = 80_000
comptime _WORKERS: Int = 4

# Payload stored under a NULL row. Appears nowhere else, so a null-blind path
# answers exactly one too high.
comptime _NULL_PAYLOAD: Int64 = -777_777


def _noop_sink_factory() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


# =============================================================================
# 1. THE PURE PIECES — heavy detection and the pair bucket
# =============================================================================


def test_heavy_detection_takes_groups_above_two_over_k() raises:
    """`cd_heavy_groups` is the ADMISSION of the split, so its three edges are
    asserted directly: a share above 2/K is heavy, one at or below is not, and
    K < 2 has nothing to spread across."""
    var s = List[Int]()
    for i in range(4096):
        s.append(7 if i % 10 != 0 else 100 + i % 50)  # 90% one hash
    var h4 = cd_heavy_groups(s, 4)
    assert_equal(len(h4), 1, "one group at 90% is heavy at K=4 (2/K = 50%)")
    assert_equal(h4[0], 7, "and it is the 90% group")
    assert_equal(len(cd_heavy_groups(s, 1)), 0, "K=1: nothing to spread")

    # 64 even groups: each 1/64 of the sample, under 2/K at every K <= 32.
    var u = List[Int]()
    for i in range(4096):
        u.append(i % 64)
    assert_equal(len(cd_heavy_groups(u, 4)), 0, "uniform groups: none heavy")
    assert_equal(len(cd_heavy_groups(u, 32)), 0, "uniform at K=32: none heavy")

    # Ten groups at 10% each at K=32 (2/K = 6.25%): ten candidates, capped at
    # CD_HEAVY_MAX, ties broken by hash so the list is deterministic.
    var t = List[Int]()
    for i in range(4000):
        t.append(1000 - (i % 10))
    var h32 = cd_heavy_groups(t, 32)
    assert_equal(len(h32), CD_HEAVY_MAX, "capped at CD_HEAVY_MAX")
    assert_equal(h32[0], 991, "ties are broken by hash, ascending")
    assert_equal(h32[3], 994, "... for every slot of the capped list")

    # Heaviest first.
    var o = List[Int]()
    for i in range(1000):
        if i < 600:
            o.append(5)
        elif i < 900:
            o.append(3)
        else:
            o.append(9)
    var ho = cd_heavy_groups(o, 8)  # 2/K = 25%: 60% and 30% qualify, 10% not
    assert_equal(len(ho), 2, "60% and 30% are heavy at K=8, 10% is not")
    assert_equal(ho[0], 5, "heaviest first")
    assert_equal(ho[1], 3, "then the next")


def test_split_groups_take_groups_above_one_over_four_k() raises:
    """⭐ CD-SCAN LEVER 2 (2026-09-25): the DRIVER splits above 1/(4K)
    (`cd_split_groups`), while the fused route's decline test keeps 2/K
    (`cd_heavy_groups`, asserted above and unchanged). cbq11's shape at K=20:
    79.2%, 4.16%, 2.27% and 1.67% groups over a long tail — under 2/K = 10%
    except the first, but all four over 1/(4K) = 1.25%."""
    var q = List[Int]()
    for i in range(4096):
        var m = (i * 10_000) // 4096  # spread 4,096 samples over 0..9,997
        if m < 7_920:
            q.append(11)
        elif m < 8_336:
            q.append(22)
        elif m < 8_563:
            q.append(33)
        elif m < 8_730:
            q.append(44)
        else:
            q.append(1000 + i % 97)  # the tail, each ~0.13%
    var split = cd_split_groups(q, 20)
    assert_equal(len(split), 4, "all four groups above 1.25% are split")
    assert_equal(split[0], 11, "the 79.2% group first")
    assert_equal(split[1], 22, "then 4.16%")
    assert_equal(split[2], 33, "then 2.27%")
    assert_equal(split[3], 44, "then 1.67%")
    var heavy = cd_heavy_groups(q, 20)
    assert_equal(len(heavy), 1, "the fused route's 2/K test names only 79.2%")
    assert_equal(len(cd_split_groups(q, 1)), 0, "K=1: nothing to spread")
    # The edge: at K=16 a 1/64 share IS 1/(4K) — at the edge is NOT split.
    var u = List[Int]()
    for i in range(4096):
        u.append(i % 64)
    assert_equal(len(cd_split_groups(u, 16)), 0, "at 1/(4K) exactly: not split")
    assert_equal(len(cd_split_groups(u, 17)), 4, "above 1/(4K): split, capped")


def test_pair_bucket_is_pure_in_range_and_spreads_one_group() raises:
    """ONE group's pairs must reach EVERY worker, evenly — that is the whole
    point of the split — and each pair must have exactly one owner (purity).
    A bucket that ignored the value (group-only) would put every pair on one
    worker; one that ignored the group would still spread, so the purity and
    range laws are asked at several groups too."""
    var ks = List[Int]()
    ks.append(2)
    ks.append(3)
    ks.append(4)
    ks.append(20)
    ks.append(32)
    var groups = List[Int]()
    groups.append(0x811C9DC5 * 0x01000193)
    groups.append(-12345678901)
    groups.append(7)
    for gi in range(len(groups)):
        var g = groups[gi]
        for ki in range(len(ks)):
            var k = ks[ki]
            var load = List[Int](length=k, fill=0)
            var oob = 0
            var impure = 0
            var nvals = 8192
            for v in range(nvals):
                var val = v * 2654435761 - 1_000_000  # negative values too
                var b = cd_pair_bucket(g, val, k)
                if b < 0 or b >= k:
                    oob += 1
                    continue
                if cd_pair_bucket(g, val, k) != b:
                    impure += 1
                load[b] += 1
            assert_equal(oob, 0, "pair bucket out of [0, K) at K=" + String(k))
            assert_equal(impure, 0, "pair bucket not pure at K=" + String(k))
            var mean = nvals // k
            for w in range(k):
                assert_true(
                    load[w] * 2 >= mean and load[w] <= mean * 2,
                    "one group's pairs are not spread evenly: worker "
                    + String(w) + " of K=" + String(k) + " owns "
                    + String(load[w]) + " around a mean of " + String(mean),
                )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
