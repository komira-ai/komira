# =============================================================================
# test_cd_parallel_partition -- the grouped COUNT(DISTINCT) driver's partition
# function, and the driver-level answers that rest on it
# =============================================================================
#
# One `CdDistinctSet` per WORKER is globally correct only because a group never
# spans workers, and a group never spans workers only because
# `_cd_partition_bucket` is a pure function of the composite key hash. The
# merge is a concatenation with no lookup, so if that breaks the answer is a
# silent over-count (the same group once per worker, each copy with a partial
# count). The one stated exception, a HEAVY group, has its own falsifiers in
# `test_cd_parallel_heavy_split.mojo`; the fixtures here are uniform or pure.
#
# What each test catches:
#   * `test_two_count_distinct_slots_do_not_share_a_pair_set`: a pair key that
#     drops the aggregate slot (two COUNT(DISTINCT)s dedup against each other);
#   * `test_null_rows_never_occupy_a_pair_slot`: a NULL value admitted, an
#     all-NULL group dropped or counted 1;
#   * `test_output_row_count_equals_the_distinct_key_count`: a duplicate group,
#     invisible to every per-group value assertion;
#   * pure: a bucket that depends on anything but (hash, K);
#   * partition: a row claimed by no worker (under-count) or two (over-count);
#   * identity: a change of the map (pinned to a verbatim copy of the
#     multiply-shift and of the mix), an out-of-range bucket, and two
#     non-vacuity counts (mixes negative as a signed Int, where a signed
#     spelling goes out of range; pairs where the map differs from the `%`
#     division it replaced, so the pin cannot degrade back into it);
#   * balance: a map collapsed onto one worker or half of them, which still
#     answers correctly and so no value oracle can see;
#   * control: the same keys split by ROW RANGE must put every key on several
#     workers, or the laws above prove nothing about the hash split;
#   * end to end: every group appears in every contiguous 1/K block of the
#     input, through the real driver with K >= 2 derived, not assumed;
#   * extremes: -1 (the empty-slot sentinel's bit pattern), Int64.MIN and
#     Int64.MAX as values through the driver.
#
# The oracles are linear scans over the raw fixture lists.
# =============================================================================

from std.collections import Dict, List, Set
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import (
    Field, RecordBatch, RecordBatchBuilder, SchemaBuilder,
)
from komira_plan_expr.agg_expr import count_distinct
from komira_plan_expr.col_expr import col
from komira_plan_ir.logical_plan import AggExprArray, ExprArray
from komira_physical_plan.physical_plan import AggSinkData
from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.runtime import PLACEMENT_FIXED, PerCoreAsyncRuntime

from komira_op_agg_distinct.agg_count_distinct_parallel import (
    _execute_count_distinct_agg_parallel,
    _should_use_parallel_count_distinct,
)
from komira_op_agg_distinct.cd_parallel_state import (
    _cd_partition_bucket,
    _cd_partition_mix,
    _PARALLEL_CD_MAX_K,
    _PARALLEL_CD_MIN_ROWS_PER_WORKER,
)

comptime _ABOVE: Int = 70_000
comptime _WORKERS: Int = 4
comptime _NULL_PAYLOAD: Int64 = -777_777


def _noop_sink_factory() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


# =============================================================================
# Fixture + oracle for the driver-level cases
# =============================================================================


struct _Fx(Movable):
    """The raw arrays the batch was built from. The oracle reads THESE."""

    var keys: List[Int64]
    var vals: List[Int64]
    var nulls: List[Bool]

    def __init__(
        out self, var keys: List[Int64], var vals: List[Int64],
        var nulls: List[Bool],
    ):
        self.keys = keys^
        self.vals = vals^
        self.nulls = nulls^

    def n(self) -> Int:
        return len(self.keys)


def _skewed_fixture(n: Int) raises -> _Fx:
    """One group holds ~90% of the rows and its values repeat heavily. Each group draws from a DIFFERENT-SIZED value set, so a
    run that attributed rows to the wrong group is caught by the counts and not
    only by the group set."""
    var keys = List[Int64](capacity=n)
    var vals = List[Int64](capacity=n)
    var nulls = List[Bool](capacity=n)
    for i in range(n):
        var g: Int
        if i % 10 == 0:
            g = 1 + (i % 3)  # groups 1,2,3 get ~10% between them
        else:
            g = 0  # group 0 gets ~90%
        keys.append(Int64(g))
        # group 0 -> 17 distinct values, 1 -> 3, 2 -> 5, 3 -> 7
        var span = 17 if g == 0 else (2 * g + 1)
        vals.append(Int64(i % span))
        nulls.append(False)
    return _Fx(keys^, vals^, nulls^)


def _null_fixture(n: Int) raises -> _Fx:
    """Four groups; group 3 is ENTIRELY NULL, and every other group carries at
    least one NULL row so no group's answer is right by accident."""
    var keys = List[Int64](capacity=n)
    var vals = List[Int64](capacity=n)
    var nulls = List[Bool](capacity=n)
    for i in range(n):
        var g = i % 4
        keys.append(Int64(g))
        if g == 3 or (i % 7) == 0:
            vals.append(_NULL_PAYLOAD)
            nulls.append(True)
        else:
            vals.append(Int64(100 * g + (i % (g + 1))))
            nulls.append(False)
    return _Fx(keys^, vals^, nulls^)


def _build_batch(imm f: _Fx) raises -> RecordBatch:
    """A 3-column batch: INT64 key `k`, INT64 value `v` (nullable iff the
    fixture has a null), and a SECOND value column `w` used by the two-agg
    case. `w` is deliberately a DIFFERENT function of the row than `v`, so two
    CD slots sharing one pair set would produce a visibly wrong number."""
    var n = f.n()
    var karr = PrimitiveArray[DType.int64].allocate(n)
    for i in range(n):
        karr.store[1](i, Scalar[DType.int64](f.keys[i]))

    var any_null = False
    for i in range(n):
        if f.nulls[i]:
            any_null = True
            break

    var rbb = RecordBatchBuilder.with_capacity(3)
    rbb.add_column(Column.from_primitive[DType.int64](karr^))
    if any_null:
        var varr = PrimitiveArray[DType.int64].allocate_nullable(n)
        for i in range(n):
            varr.store[1](i, Scalar[DType.int64](f.vals[i]))
        for i in range(n):
            if f.nulls[i]:
                varr._set_null(i)
        rbb.add_column(Column.from_primitive[DType.int64](varr^))
    else:
        var varr = PrimitiveArray[DType.int64].allocate(n)
        for i in range(n):
            varr.store[1](i, Scalar[DType.int64](f.vals[i]))
        rbb.add_column(Column.from_primitive[DType.int64](varr^))

    var warr = PrimitiveArray[DType.int64].allocate(n)
    for i in range(n):
        warr.store[1](i, Scalar[DType.int64](_w_of(i)))
    rbb.add_column(Column.from_primitive[DType.int64](warr^))

    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.INT64, False))
    sb.add_field(Field("v", ArrowType.INT64, any_null))
    sb.add_field(Field("w", ArrowType.INT64, False))
    return rbb.build(sb.build())


def _w_of(i: Int) -> Int64:
    """The second value column. Chosen so its per-group distinct count differs
    from `v`'s — a two-slot key collision would show up as one column's answer
    appearing under the other's name."""
    return Int64(i % 23)


def _sink_grouped() raises -> AggSinkData:
    """SELECT k, COUNT(DISTINCT v) FROM t GROUP BY k."""
    var group_by = ExprArray()
    group_by.append(col("k").copy_expr())
    var aggs = AggExprArray()
    aggs.append(count_distinct(col("v")))
    var osb = SchemaBuilder()
    osb.add_field(Field("k", ArrowType.INT64, False))
    osb.add_field(Field("cdv", ArrowType.INT64, False))
    return AggSinkData(group_by^, aggs^, osb.build())


def _sink_grouped_two_cd() raises -> AggSinkData:
    """SELECT k, COUNT(DISTINCT v), COUNT(DISTINCT w) FROM t GROUP BY k."""
    var group_by = ExprArray()
    group_by.append(col("k").copy_expr())
    var aggs = AggExprArray()
    aggs.append(count_distinct(col("v")))
    aggs.append(count_distinct(col("w")))
    var osb = SchemaBuilder()
    osb.add_field(Field("k", ArrowType.INT64, False))
    osb.add_field(Field("cdv", ArrowType.INT64, False))
    osb.add_field(Field("cdw", ArrowType.INT64, False))
    return AggSinkData(group_by^, aggs^, osb.build())


def _oracle_v(imm f: _Fx) raises -> Dict[Int64, Int]:
    var sets = Dict[Int64, Set[Int64]]()
    for i in range(f.n()):
        var k = f.keys[i]
        if k not in sets:
            sets[k] = Set[Int64]()
        if not f.nulls[i]:
            sets[k].add(f.vals[i])
    var out = Dict[Int64, Int]()
    for e in sets.items():
        out[e.key] = len(e.value)
    return out^


def _oracle_w(imm f: _Fx) raises -> Dict[Int64, Int]:
    var sets = Dict[Int64, Set[Int64]]()
    for i in range(f.n()):
        var k = f.keys[i]
        if k not in sets:
            sets[k] = Set[Int64]()
        sets[k].add(_w_of(i))
    var out = Dict[Int64, Int]()
    for e in sets.items():
        out[e.key] = len(e.value)
    return out^


def _result_col(imm b: RecordBatch, agg_col: Int) raises -> Dict[Int64, Int]:
    var m = Dict[Int64, Int]()
    var keys = b.column_as_primitive_int64(0)
    var counts = b.column_as_primitive_int64(agg_col)
    for r in range(b.num_rows()):
        m[keys.get(r)] = Int(counts.get(r))
    return m^


def _assert_matches(
    imm got: Dict[Int64, Int], imm want: Dict[Int64, Int], imm msg: String
) raises:
    assert_equal(len(got), len(want), msg + ": group COUNT")
    for e in want.items():
        assert_true(e.key in got, msg + ": missing group key " + String(e.key))
        assert_equal(
            got[e.key], e.value, msg + ": count for group " + String(e.key)
        )


def _run_parallel(
    imm f: _Fx, two_cd: Bool
) raises -> RecordBatch:
    var n = f.n()
    assert_true(
        _should_use_parallel_count_distinct(n, _WORKERS),
        "PRECONDITION: n=" + String(n) + " must be at or above"
        " _PARALLEL_CD_MIN_ROWS, where production selects this driver",
    )
    var batch = _build_batch(f)
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_workers(_WORKERS, _noop_sink_factory, BACKEND_MOCK)
    rt.start()
    ref disp = rt.dispatcher()
    var ct = CancellationToken.new()
    if two_cd:
        return _execute_count_distinct_agg_parallel(
            disp, ct.clone(), batch, _sink_grouped_two_cd(), 1, 2, n
        )
    return _execute_count_distinct_agg_parallel(
        disp, ct.clone(), batch, _sink_grouped(), 1, 1, n
    )


# =============================================================================
# Two COUNT(DISTINCT) slots — the pair key carries the slot
# =============================================================================


def test_two_count_distinct_slots_do_not_share_a_pair_set() raises:
    """ONE per-worker pair set serves every aggregate slot, so the slot index
    is packed into the key. Drop it and `count(DISTINCT v)` and
    `count(DISTINCT w)` would dedup against each other — every value present in
    both columns would be counted once across the pair instead of once per
    aggregate. Two columns with DIFFERENT per-group cardinalities make that
    visible in both directions."""
    var f = _skewed_fixture(_ABOVE)
    var want_v = _oracle_v(f)
    var want_w = _oracle_w(f)
    var got = _run_parallel(f, two_cd=True)
    _assert_matches(_result_col(got, 1), want_v, "count(DISTINCT v)")
    _assert_matches(_result_col(got, 2), want_w, "count(DISTINCT w)")
    # The fixture is only able to see a shared-set defect if the two columns
    # disagree somewhere. Assert that property of the fixture itself.
    var differs = False
    for e in want_v.items():
        if want_w[e.key] != e.value:
            differs = True
            break
    assert_true(
        differs,
        "FIXTURE PROPERTY: the two CD columns must have different per-group"
        " distinct counts somewhere, or a shared pair set would pass here",
    )


# =============================================================================
# NULL and the all-NULL group
# =============================================================================


def test_null_rows_never_occupy_a_pair_slot() raises:
    """A NULL row is skipped BEFORE `admit`, and group 3 — entirely NULL —
    still appears in the output with a distinct count of 0. Both halves matter:
    0 is not NULL, and the group must not be DROPPED (it has rows)."""
    var f = _null_fixture(_ABOVE)
    var want = _oracle_v(f)
    var got = _result_col(_run_parallel(f, two_cd=False), 1)
    _assert_matches(got, want, "grouped count(DISTINCT v) with NULLs")
    assert_true(Int64(3) in got, "the ALL-NULL group must still be EMITTED")
    assert_equal(
        got[Int64(3)], 0,
        "an ALL-NULL group's distinct count is 0 — not 1 (an"
        " empty-set-that-counts-as-one) and not a dropped row",
    )


# =============================================================================
# The output shape
# =============================================================================


def test_output_row_count_equals_the_distinct_key_count() raises:
    """A DUPLICATE GROUP IS INVISIBLE TO EVERY PER-GROUP VALUE ASSERTION —
    it emits the right answer twice, and a Dict-keyed comparison silently folds
    the two rows together. The ROW COUNT of the batch is the only oracle that
    sees it, so it is asserted directly rather than through `_result_col`."""
    var f = _skewed_fixture(_ABOVE)
    var want = _oracle_v(f)
    var got = _run_parallel(f, two_cd=False)
    assert_equal(
        got.num_rows(), len(want),
        "one output row per DISTINCT group key — a duplicate group would be"
        " invisible to every count assertion in this file",
    )




comptime _HASH_POP: Int = 4096


def _k_ladder() -> List[Int]:
    """The K values every partition law is asked at, built by append. 1 is
    included deliberately — the degenerate partition
    must still satisfy coverage-and-disjointness, and it is the value at which
    [end to end] would be vacuous."""
    var ks = List[Int]()
    ks.append(1)
    ks.append(2)
    ks.append(3)
    ks.append(4)
    ks.append(8)
    ks.append(20)
    ks.append(32)
    return ks^


def _pop_hashes(n: Int) -> List[Int]:
    """A deterministic population of composite key hashes, built with the
    SAME FNV-1a shape the driver's key loop produces (`h = 0x811C9DC5`, then
    `h = (h ^ kv) * 0x01000193` per key) over a two-key row. Deterministic and
    seedless — this test may never be probabilistic."""
    var out = List[Int](capacity=n)
    for i in range(n):
        var h: Int = 0x811C9DC5
        h = (h ^ i) * 0x01000193
        h = (h ^ (i * 2_654_435_761)) * 0x01000193
        out.append(h)
    return out^


def _pinned_mix(group_key_hash: Int) -> Int:
    """The secondary mix, copied verbatim. Do NOT "tidy" it into a call to
    production code: it is the fixed point the identity test compares against, and a copy that tracks the code under
    test can only ever agree with it."""
    var part_hash = (group_key_hash * 0x9E3779B97F4A7C15) ^ (group_key_hash >> 17)
    return part_hash


def _division_bucket(group_key_hash: Int, num_workers_local: Int) -> Int:
    """The bucket by 64-bit division (`%`) that the multiply-shift replaced: a
    `divq` per row per worker. It is the fixed point the identity test asserts
    the production map DIFFERS from, so the pin below cannot silently degrade back into the
    division."""
    var part_hash = _pinned_mix(group_key_hash)
    var bucket = Int(UInt(part_hash) % UInt(num_workers_local))
    return bucket


def _divfree_bucket(group_key_hash: Int, num_workers: Int) -> Int:
    """The multiply-shift bucket, copied verbatim from
    `_cd_partition_bucket`'s body — Lemire multiply-shift over the unsigned
    mix. Do NOT "tidy" it into a call to production code: it is the FIXED
    POINT the identity test compares against. If a future edit changes the partition ON
    PURPOSE, it must change this copy too, in the same commit that carries
    that change's measurement: a partition change moves every CD cell's
    per-worker load, so it is a performance change and may not ride in under
    a refactor."""
    var p = UInt(_pinned_mix(group_key_hash))
    return Int(((p >> 32) * UInt(num_workers)) >> 32)


def test_the_partition_is_a_pure_function_of_the_key_hash() raises:
    """[pure]. Same hash, same K, same answer — asked repeatedly and in an
    interleaved order, because the property that matters is that the bucket
    depends on NOTHING ELSE: not the row index, not the calling worker, not
    how many rows have been seen."""
    var pop = _pop_hashes(_HASH_POP)
    var ks = _k_ladder()
    var impure_k = -1
    var impure_i = -1
    for ki in range(len(ks)):
        var k = ks[ki]
        var first = List[Int](capacity=len(pop))
        for i in range(len(pop)):
            first.append(_cd_partition_bucket(pop[i], k))
        # Second pass in REVERSE, interleaved with a foreign K, so a stateful
        # implementation (a counter, a round-robin) cannot reproduce it.
        for j in range(len(pop) - 1, -1, -1):
            _ = _cd_partition_bucket(pop[(j * 7) % len(pop)], k + 1)
            if _cd_partition_bucket(pop[j], k) != first[j]:
                impure_k = k
                impure_i = j
    # Asserted ONCE, outside the loops. An `assert_equal` with a `String`
    # message inside a 4096 x 7 loop builds ~29,000 throwaway Strings on the
    # GREEN path; the diagnostic is identical and the test stays cheap.
    assert_equal(
        impure_i, -1,
        "[pure] the bucket for hash index " + String(impure_i) + " CHANGED"
        " between calls at K=" + String(impure_k) + " — the partition is not a"
        " pure function, so a group can span workers and per-worker dedup is"
        " not globally correct",
    )


def test_every_row_is_claimed_by_exactly_one_worker() raises:
    """[partition]. The driver hands EVERY worker the whole row range and each keeps
    the rows whose bucket equals its own id. So the law is: summed over
    workers, each row is claimed exactly once. 0 claims loses rows (an
    UNDER-count); 2+ claims double-counts a (group, value) pair across two
    independent `CdDistinctSet`s (an OVER-count).

    ONLY THE UNDER-CLAIM DIRECTION IS LIVE HERE. A single-valued function
    cannot name two owners, so `multi` is structurally 0 today; it is asserted
    so that a future multi-owner scheme (say, replicating a hot group) has to delete an assertion to exist, instead
    of inheriting a design that assumes one owner. The under-claim direction is
    the one any out-of-range bucket trips."""
    var pop = _pop_hashes(_HASH_POP)
    var ks = _k_ladder()
    for ki in range(len(ks)):
        var k = ks[ki]
        var multi = 0
        var none = 0
        for i in range(len(pop)):
            var claims = 0
            for wid in range(k):
                if _cd_partition_bucket(pop[i], k) == wid:
                    claims += 1
            if claims == 0:
                none += 1
            elif claims > 1:
                multi += 1
        assert_equal(
            none, 0,
            "[partition] at K=" + String(k) + ": rows claimed by NO worker — those"
            " rows never reach any hash table (UNDER-count)",
        )
        assert_equal(
            multi, 0,
            "[partition] at K=" + String(k) + ": rows claimed by MORE THAN ONE worker"
            " — the same (group, value) pair lands in two independent"
            " CdDistinctSets (OVER-count)",
        )


def test_the_bucket_is_identical_to_the_divfree_expression() raises:
    """The partition pin.

    The production map is compared, value for value, against a VERBATIM copy
    of its multiply-shift body (`_divfree_bucket`), and its MIX against a
    verbatim copy of the mix (`_pinned_mix`), over
    4,096 hashes x 7 K. Any future change to which worker a row lands on moves
    every CD cell's per-worker load, so it has to come with its own
    measurement and edit the copy on purpose.

    Four non-vacuity counts make those identities able to see the mutants
    they exist for:
      * `neg_inputs`  — negative HASHES reach `>> 17`, an ARITHMETIC shift,
                        i.e. the sign-dependent half of the mix;
      * `neg_mix`     — mixes that are NEGATIVE as a signed Int. On exactly
                        those, a spelling that drops the `UInt` reading
                        (`((p >> 32) * K) >> 32` in signed Int arithmetic)
                        goes NEGATIVE — out of range, rows dropped. If this
                        were 0 the in-range assertion could not see that
                        mutant;
      * `signed_oob`  — the same, asserted directly: the (hash, K) pairs the
                        signed spelling would put out of range;
      * `differs_from_div` — pairs where the multiply-shift and the `%`
                        division it replaced pick DIFFERENT workers. If this
                        were 0 the pin could be degraded back into the divide
                        without anything going red.
    """
    var pop = _pop_hashes(_HASH_POP)
    var ks = _k_ladder()
    var neg_inputs = 0
    var neg_mix = 0
    var signed_oob = 0
    var differs_from_div = 0
    var mix_drift = 0
    var out_of_range = 0
    var worst_b = 0
    var worst_k = 0
    var drifted = 0
    var first_drift_i = -1
    var first_drift_k = 0
    for i in range(len(pop)):
        var h = pop[i]
        if h < 0:
            neg_inputs += 1
        var p = _pinned_mix(h)
        if _cd_partition_mix(h) != p:
            mix_drift += 1
        if p < 0:
            neg_mix += 1
        for ki in range(len(ks)):
            var k = ks[ki]
            var b = _cd_partition_bucket(h, k)
            if b < 0 or b >= k:
                out_of_range += 1
                worst_b = b
                worst_k = k
            if b != _divfree_bucket(h, k):
                drifted += 1
                if first_drift_i < 0:
                    first_drift_i = i
                    first_drift_k = k
            if b != _division_bucket(h, k):
                differs_from_div += 1
            var sb = ((p >> 32) * k) >> 32
            if sb < 0 or sb >= k:
                signed_oob += 1
    assert_equal(
        mix_drift, 0,
        "[identity] THE SECONDARY MIX MOVED on " + String(mix_drift) + " of "
        + String(len(pop)) + " hashes; a moved mix re-partitions every"
        " COUNT(DISTINCT) cell",
    )
    assert_equal(
        drifted, 0,
        "[identity] THE PARTITION CHANGED on " + String(drifted)
        + " of " + String(len(pop) * len(ks)) + " (hash, K) pairs (first:"
        " hash index " + String(first_drift_i) + " at K="
        + String(first_drift_k) + ") against the pinned multiply-shift. Every"
        " row that moved now lands on a different worker — a performance"
        " change for every CD cell, shipped without its measurement",
    )
    assert_equal(
        out_of_range, 0,
        "[identity] " + String(out_of_range) + " bucket(s) outside [0, K); worst was "
        + String(worst_b) + " at K=" + String(worst_k) + " — an out-of-range"
        " bucket is claimed by NO worker, so its rows are silently dropped",
    )
    assert_true(
        neg_inputs > 0,
        "[identity] NON-VACUITY: not one hash in this population is NEGATIVE, so the"
        " arithmetic `>> 17` half of the mix was never exercised on a"
        " sign-extended input",
    )
    assert_true(
        neg_mix > 0 and signed_oob > 0,
        "[identity] NON-VACUITY: no mix in this population is negative as a signed"
        " Int (neg_mix=" + String(neg_mix) + ", signed_oob="
        + String(signed_oob) + "), so the in-range assertion above could not"
        " see a spelling that drops the unsigned reading",
    )
    assert_true(
        differs_from_div > 0,
        "[identity] NON-VACUITY: the multiply-shift picks the SAME worker as the `%`"
        " division on every (hash, K) pair, so this pin could not tell the"
        " divide-free map from the divide it replaced",
    )


def test_the_divfree_partition_uses_every_bucket_and_is_balanced() raises:
    """[balance]. THE COLLAPSED-MAP GUARD.

    A map that sends every row to worker 0 is pure, in range and claims each
    row exactly once — it passes [pure], [partition] and the in-range half of [identity], and
    every COUNT(DISTINCT) value oracle in the repo, because a single worker
    computes the right answer slowly. The same holds for a map that uses only
    HALF the workers (`>> 33` for `>> 32`). This is the one assertion either
    mutant can fail: over the test population, at every K of the ladder, every
    bucket is used and every bucket's load is within [mean/2, 2*mean].

    The bounds are loose on purpose: at K=32 the mean is 128 rows and a
    binomial's standard deviation is ~11, so [64, 256] is ~6 sigma on either
    side — a real map cannot trip it, and each mutant misses it by a factor.
    """
    var pop = _pop_hashes(_HASH_POP)
    var ks = _k_ladder()
    for ki in range(len(ks)):
        var k = ks[ki]
        var load = List[Int](length=k, fill=0)
        for i in range(len(pop)):
            var b = _cd_partition_bucket(pop[i], k)
            if b >= 0 and b < k:
                load[b] += 1
        var mean = len(pop) // k
        var lo = load[0]
        var hi = load[0]
        var empty = 0
        for w in range(k):
            if load[w] < lo:
                lo = load[w]
            if load[w] > hi:
                hi = load[w]
            if load[w] == 0:
                empty += 1
        assert_equal(
            empty, 0,
            "[balance] at K=" + String(k) + ": " + String(empty) + " worker(s) own"
            " NO hash in a 4,096-hash population — the map collapsed, and its"
            " rows pile onto the others",
        )
        assert_true(
            lo * 2 >= mean and hi <= mean * 2,
            "[balance] at K=" + String(k) + ": per-worker load ranges " + String(lo)
            + ".." + String(hi) + " around a mean of " + String(mean)
            + " — outside [mean/2, 2*mean], so the map is skewed by itself",
        )


def test_a_row_range_split_violates_the_invariant_the_hash_split_holds() raises:
    """[control]. THE PLANTED CONTROL, WITH AN INVERTED VERDICT.

    [pure]–[identity] would all pass under partitionings that are WRONG for this design,
    so on their own they do not establish that hash partitioning is what buys
    the correctness. Here the SAME key population is split the other way — by
    contiguous row range, the shape this file's prose claimed for months — and
    the assertion is that it FAILS the [partition] law at the level that matters: one
    GROUP KEY reaches more than one worker.

    The two splits answer different questions, which is why the control is
    stated over KEYS and not rows. A row-range split does claim each ROW once;
    what it cannot do is keep each KEY inside one worker, and that is the
    clause `CdDistinctSet`-per-worker depends on."""
    var k = 4
    var n_keys = 64
    var n_rows = 4096
    var pop = _pop_hashes(n_keys)

    # Arm A — HASH split: workers a key's rows land on, over a row stream in
    # which every key recurs throughout the input.
    var hash_span = Dict[Int, Set[Int]]()
    var range_span = Dict[Int, Set[Int]]()
    var rows_per_worker = n_rows // k
    for row in range(n_rows):
        var key = row % n_keys
        var h = pop[key]
        if key not in hash_span:
            hash_span[key] = Set[Int]()
            range_span[key] = Set[Int]()
        hash_span[key].add(_cd_partition_bucket(h, k))
        # Arm B — ROW-RANGE split, the reverted shape.
        var rr = row // rows_per_worker
        if rr >= k:
            rr = k - 1
        range_span[key].add(rr)

    var hash_multi = 0
    var range_multi = 0
    for e in hash_span.items():
        if len(e.value) > 1:
            hash_multi += 1
    for e in range_span.items():
        if len(e.value) > 1:
            range_multi += 1

    assert_equal(
        hash_multi, 0,
        "[control] HASH split: " + String(hash_multi) + " group key(s) reached more"
        " than one worker — a group SPANNED workers, so per-worker dedup is"
        " not globally correct and the concat-merge over-counts",
    )
    assert_equal(
        range_multi, n_keys,
        "[control] CONTROL IS VACUOUS: the ROW-RANGE split was supposed to put every"
        " one of the " + String(n_keys) + " keys on several workers, and it"
        " put " + String(range_multi) + " there. If this number is 0 the"
        " fixture stopped spreading keys across the input and [control] proves"
        " nothing about the hash split",
    )


def _spread_fixture(n: Int) raises -> _Fx:
    """Every group recurs every 64 rows, so EVERY group appears in EVERY
    contiguous 1/K block for any K a 70,000-row input can produce. Under a
    row-range split that means every group lands in every worker. Each group
    draws from a different-sized value set so a mis-attributed row is caught
    by a COUNT and not only by the group set."""
    var keys = List[Int64](capacity=n)
    var vals = List[Int64](capacity=n)
    var nulls = List[Bool](capacity=n)
    for i in range(n):
        var g = i % 64
        keys.append(Int64(g))
        vals.append(Int64(i % (g + 3)))
        nulls.append(False)
    return _Fx(keys^, vals^, nulls^)


def test_a_group_never_spans_workers_through_the_real_driver() raises:
    """[end to end]. The end-to-end arm. Every group appears in every contiguous 1/K
    block of the input, so under a row-range split the concat-merge emits each
    group K times with K partial counts. Asserted on BOTH oracles a duplicate
    group can be seen through — the batch's ROW COUNT (a Dict-keyed comparison
    folds duplicates away) and the per-group values.

    K IS DERIVED, NOT ASSUMED. At K=1 every one of these assertions holds
    for a row-range split too, so the test would be vacuous and green."""
    var n = _ABOVE
    var by_min_rows = n // _PARALLEL_CD_MIN_ROWS_PER_WORKER
    if by_min_rows < 1:
        by_min_rows = 1
    var k = _WORKERS
    if by_min_rows < k:
        k = by_min_rows
    if k > _PARALLEL_CD_MAX_K:
        k = _PARALLEL_CD_MAX_K
    assert_true(
        k >= 2,
        "[end to end] NON-VACUITY: the driver resolves K=" + String(k) + " for n="
        + String(n) + " at " + String(_WORKERS) + " workers. At K=1 there is"
        " only one partition and every assertion below passes under a"
        " row-range split as well — this case would prove nothing",
    )

    var f = _spread_fixture(n)
    var want = _oracle_v(f)
    assert_equal(
        len(want), 64, "[end to end] fixture: 64 distinct group keys expected"
    )
    var batch = _run_parallel(f, two_cd=False)
    assert_equal(
        batch.num_rows(), len(want),
        "[end to end] the output has " + String(batch.num_rows()) + " rows for "
        + String(len(want)) + " distinct group keys. A group spanned workers:"
        " the concat-merge emitted it once per worker, and each copy carries"
        " only the distinct values THAT worker saw",
    )
    _assert_matches(
        _result_col(batch, 1), want,
        "[end to end] per-group COUNT(DISTINCT) with every group present in every"
        " contiguous 1/K block",
    )


# =============================================================================
# Negative and extreme values
# =============================================================================
#
# `CdDistinctSet` marks an empty slot with -1 in the TAG word and never
# inspects the VALUE for occupancy. The values below include -1 (the
# sentinel's exact bit pattern, in the other word), Int64.MIN / Int64.MAX
# (the two ends a signed hash mix or a `>>` can mishandle) and 0.


def _extreme_values() -> List[Int64]:
    var v = List[Int64]()
    v.append(Int64(-1))
    v.append(Int64.MIN)
    v.append(Int64.MAX)
    v.append(Int64(0))
    v.append(Int64(-2))
    v.append(Int64.MIN + 1)
    v.append(Int64.MAX - 1)
    v.append(_NULL_PAYLOAD)
    return v^


def _extreme_fixture(n: Int) raises -> _Fx:
    """Eight groups; group g draws from the first `g + 1` extreme values, so
    the per-group distinct counts are 1..8 and a swallowed extreme value
    changes a COUNT, not only the group set."""
    var ext = _extreme_values()
    var keys = List[Int64](capacity=n)
    var vals = List[Int64](capacity=n)
    var nulls = List[Bool](capacity=n)
    for i in range(n):
        var g = i % 8
        keys.append(Int64(g))
        vals.append(ext[(i // 8) % (g + 1)])
        nulls.append(False)
    return _Fx(keys^, vals^, nulls^)


def test_negative_and_extreme_values_through_the_real_driver() raises:
    """The extreme values through the driver, against the raw-array oracle, with the output ROW COUNT asserted so a
    duplicate group cannot hide behind a Dict-keyed comparison."""
    var f = _extreme_fixture(_ABOVE)
    var want = _oracle_v(f)
    assert_equal(len(want), 8, "fixture: 8 group keys expected")
    for g in range(8):
        assert_equal(
            want[Int64(g)], g + 1,
            "FIXTURE PROPERTY: group " + String(g) + " must draw g+1"
            " distinct extreme values, or a swallowed value could go unseen",
        )
    var batch = _run_parallel(f, two_cd=False)
    assert_equal(
        batch.num_rows(), len(want),
        "one output row per distinct group key",
    )
    _assert_matches(
        _result_col(batch, 1), want,
        "PARALLEL count(DISTINCT) over -1 / Int64.MIN / Int64.MAX / 0",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
