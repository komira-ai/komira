# =============================================================================
# CD-DENSE-GID — the DENSE DIRECT-INDEX group map, and the Dict it replaces
# =============================================================================
#
# ★ WHAT THIS FILE IS FOR. `WorkerCDState.consume_batch` resolved every row's
#   group key through a generic `Dict[Int, Int]`, probed TWICE per row
#   (`if key in self.group_map` then `self.group_map[key]`). Measured over
#   `SELECT os, count(DISTINCT user_id)
#   ... GROUP BY os`, 99,997,497 rows onto 91 groups — those two probes are
#   49.05% of `consume_batch`'s cycles and 17.73% of the whole query's: 35.9
#   cycles per row to turn an integer whose entire domain is [0,159] into a
#   number in [0,91). CD-DENSE-GID replaces them with a flat `List[Int32]`
#   indexed at `key - dense_lo`.
#
# ★★ THE OBLIGATION THIS FILE DISCHARGES IS BYTE-EQUIVALENCE, NOT SPEED. The
#   change moves GROUP IDENTITY RESOLUTION, which is the one thing in this sink
#   that decides which output row a value lands in. So every case here runs the
#   SAME fixture through BOTH arms of one struct — `dense_gid_off = False` (the
#   default route) and `dense_gid_off = True` (the Dict-only route) — and
#   asserts they are indistinguishable in every field the finalize reads:
#   `group_keys` INDEX FOR INDEX, `group_key_null`, `null_gid`, and each
#   group's value buffer ELEMENT FOR ELEMENT AND IN ORDER.
#
# ⚠⚠ AND AN EQUALITY TEST ALONE WOULD BE VACUOUS. Two arms that are both the
#   Dict agree perfectly. So every case ALSO asserts WHICH ROUTE RAN, off the
#   structural counters `stat_gid_dense` / `stat_gid_dict` — which PARTITION
#   the non-null key rows, so they are a conservation check and not two
#   independent readings. `_assert_conservation` pins the partition itself.
#   Delete the route assertions and this file stops testing the change.
#
# ============================ REVERT-AND-RED =================================
#
# Set `dense_gid_off = True` on the arm this file calls DENSE and §1-§3 go RED
# on the counter assertions while every equality assertion stays green — which
# is the point: equality is necessary and not sufficient. Remove the
# `dense_frozen` assignment from `_gid_for_key_slow` and FOUR cases go RED —
# MEASURED, not predicted: `test_over_cap_domain_falls_back_to_the_dict_and_
# still_agrees`, `test_a_key_beyond_the_cap_freezes_rather_than_allocating`,
# `test_one_key_one_home_after_the_freeze` and
# `test_the_window_does_not_grow_after_the_freeze`, 8 passed / 4 failed.
#
# ⚠ AND THE HONEST READING OF THAT RESULT, WHICH IS NOT THE ONE THIS HEADER
#   FIRST CLAIMED. All four red on the "is it frozen" assertion; NOT ONE reds on
#   a group count. Removing the freeze does not, today, hand any key a second
#   home — `_dense_reshape` sizes itself off an occupied range that only widens,
#   so a key it has refused once it refuses forever, and that alone is enough.
#   The freeze is what makes one-key-one-home hold INDEPENDENTLY of the sizing
#   policy, and the sizing policy is the part of this design that has already
#   been rewritten once (see `test_all_negative_keys`). So the group-count
#   assertions below are a guard against the NEXT sizing change, not a
#   falsifier of this one — and saying otherwise would be claiming coverage this
#   file does not have.
#
# ============================ THE ORACLE =====================================
#
# The Dict arm of the SAME struct, over the SAME fixture, in the SAME process.
# Deliberately not a hand-written model: the claim under test is "these two
# routes are one function", and a third implementation would only add a third
# thing that can be wrong. §1's `test_first_seen_gid_order_is_preserved` is the
# exception and reads the FIXTURE directly, so a bug shared by both routes
# cannot pass unnoticed.
#
# =============================================================================

from std.collections import List
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import (
    Field, RecordBatch, RecordBatchBuilder, SchemaBuilder,
)

from komira_op_agg_distinct.streaming_agg_count_distinct import (
    _CD_DENSE_GID_DOMAIN_CAP,
    _CD_DENSE_GID_SEED_SLOTS,
    WorkerCDState,
)


# =============================================================================
# Fixture
# =============================================================================


struct _Fx(Copyable, Movable):
    """The raw arrays a batch is built from. Every expectation reads THESE, so
    none of them is inherited from a column builder."""

    var keys: List[Int64]
    var vals: List[Int64]
    var key_nulls: List[Bool]

    def __init__(
        out self, var keys: List[Int64], var vals: List[Int64],
        var key_nulls: List[Bool],
    ):
        self.keys = keys^
        self.vals = vals^
        self.key_nulls = key_nulls^

    def n(self) -> Int:
        return len(self.keys)

    def n_non_null_keys(self) -> Int:
        var c = 0
        for i in range(len(self.key_nulls)):
            if not self.key_nulls[i]:
                c += 1
        return c


def _fx(var keys: List[Int64]) raises -> _Fx:
    """Non-nullable key column. The value is derived from the ROW INDEX, so a
    value that lands in the wrong group's buffer is visible in the buffer
    comparison instead of hiding behind equal payloads."""
    var n = len(keys)
    var vals = List[Int64](capacity=n)
    var nulls = List[Bool](capacity=n)
    for i in range(n):
        vals.append(Int64(1_000 + i))
        nulls.append(False)
    return _Fx(keys^, vals^, nulls^)


def _build_batch(imm f: _Fx) raises -> RecordBatch:
    """A 2-column batch: INT64 key `k` + INT64 value `v`.

    `k` gets a validity bitmap ONLY when the fixture has a null key, so the
    ABSENT-lane fast path (a non-nullable key column) is what every other case
    exercises rather than being an untested branch."""
    var n = f.n()

    var any_key_null = False
    for i in range(n):
        if f.key_nulls[i]:
            any_key_null = True
            break

    var rbb = RecordBatchBuilder.with_capacity(2)
    if any_key_null:
        var karr = PrimitiveArray[DType.int64].allocate_nullable(n)
        for i in range(n):
            karr.store[1](i, Scalar[DType.int64](f.keys[i]))
        for i in range(n):
            if f.key_nulls[i]:
                karr._set_null(i)
        rbb.add_column(Column.from_primitive[DType.int64](karr^))
    else:
        var karr = PrimitiveArray[DType.int64].allocate(n)
        for i in range(n):
            karr.store[1](i, Scalar[DType.int64](f.keys[i]))
        rbb.add_column(Column.from_primitive[DType.int64](karr^))

    var varr = PrimitiveArray[DType.int64].allocate(n)
    for i in range(n):
        varr.store[1](i, Scalar[DType.int64](f.vals[i]))
    rbb.add_column(Column.from_primitive[DType.int64](varr^))

    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.INT64, any_key_null))
    sb.add_field(Field("v", ArrowType.INT64, False))
    return rbb.build(sb.build())


def _run(imm f: _Fx, dense: Bool) raises -> WorkerCDState:
    """Drive `WorkerCDState.consume_batch` once, on the named arm."""
    var st = WorkerCDState(1)
    st.dense_gid_off = not dense
    var val_idx = List[Int]()
    val_idx.append(1)
    var batch = _build_batch(f)
    st.consume_batch(batch, 0, val_idx)
    return st^


def _run_batched(imm fs: List[_Fx], dense: Bool) raises -> WorkerCDState:
    """Drive `consume_batch` once per fixture into ONE state — the window has
    to survive a batch boundary, which is where a per-batch reset would hide."""
    var st = WorkerCDState(1)
    st.dense_gid_off = not dense
    var val_idx = List[Int]()
    val_idx.append(1)
    for i in range(len(fs)):
        var batch = _build_batch(fs[i])
        st.consume_batch(batch, 0, val_idx)
    return st^


# =============================================================================
# The comparison — every field the merge/finalize in `agg_sink_count_distinct`
# actually reads
# =============================================================================


def _assert_states_identical(
    imm dense: WorkerCDState, imm dict_arm: WorkerCDState, imm what: String
) raises:
    """★ THE BYTE-EQUIVALENCE ASSERTION.

    The merge in `agg_sink_count_distinct` walks `group_keys` IN GID ORDER and
    asks `group_is_null(g)`; the finalize then MOVES `cd_bufs[a][g]` into the
    radix driver. So gid order, the key at each gid, the null flag at each gid,
    and each buffer's contents IN ORDER are the complete observable surface —
    anything equal here is equal downstream. `group_map` is read by NOTHING
    outside this struct, which is why replacing it is a local decision."""
    assert_equal(
        len(dense.group_keys), len(dict_arm.group_keys),
        what + ": the two arms disagree on the GROUP COUNT",
    )
    assert_equal(
        dense.null_gid, dict_arm.null_gid,
        what + ": the two arms disagree on which gid is the NULL-key group",
    )
    for g in range(len(dense.group_keys)):
        assert_equal(
            dense.group_keys[g], dict_arm.group_keys[g],
            what + ": gid " + String(g) + " holds a DIFFERENT KEY on the two"
            " arms — group identity resolution has moved, which is exactly"
            " what this change may not do",
        )
        assert_equal(
            Int(dense.group_is_null(g)), Int(dict_arm.group_is_null(g)),
            what + ": gid " + String(g) + " disagrees on NULL-ness",
        )
        assert_equal(
            len(dense.cd_bufs[0][g]), len(dict_arm.cd_bufs[0][g]),
            what + ": gid " + String(g) + " buffered a different NUMBER of"
            " values — a row landed in the wrong group",
        )
        for i in range(len(dense.cd_bufs[0][g])):
            assert_equal(
                dense.cd_bufs[0][g][i], dict_arm.cd_bufs[0][g][i],
                what + ": gid " + String(g) + " value " + String(i)
                + " differs between the arms",
            )


def _assert_conservation(
    imm st: WorkerCDState, imm f: _Fx, imm what: String
) raises:
    """`stat_gid_dense + stat_gid_dict` must be the NON-NULL key row count.

    This is what makes the two counters a conservation check rather than two
    numbers that can both be wrong in the same direction — the same contract
    `stat_appends` / `stat_set_inserts` already carry in this struct."""
    assert_equal(
        st.stat_gid_dense + st.stat_gid_dict, f.n_non_null_keys(),
        what + ": the route counters do not PARTITION the non-null key rows,"
        " so neither of them can be read as evidence of which route ran",
    )


# =============================================================================
# §1 A SMALL DENSE KEY DOMAIN — the case being bought
# =============================================================================


def test_dense_domain_agrees_with_the_dict_and_takes_the_dense_route() raises:
    """91 groups over 4000 rows — the small-dense-domain shape at test scale.

    Both halves matter: the arms agree (byte-equivalence) AND every row went
    through the dense table (the change actually applies here). Either one
    alone is worthless."""
    var keys = List[Int64](capacity=4000)
    for i in range(4000):
        keys.append(Int64(i % 91))
    var f = _fx(keys^)

    var d = _run(f, dense=True)
    var m = _run(f, dense=False)
    _assert_states_identical(d, m, "small dense domain (91 groups)")
    assert_equal(len(d.group_keys), 91, "the fixture must produce 91 groups")

    assert_equal(
        d.stat_gid_dense, f.n(),
        "★ every row must resolve through the DENSE table on a domain of 91"
        " contiguous keys — if this reads 0 the change is inert and the"
        " equality above proves nothing",
    )
    assert_equal(d.stat_gid_dict, 0, "no row may reach the Dict here")
    assert_equal(
        m.stat_gid_dense, 0,
        "the kill-switch arm must take the Dict for EVERY row — it is the"
        " pre-change route and it is this file's oracle",
    )
    assert_equal(m.stat_gid_dict, f.n(), "the Dict arm must count every row")
    _assert_conservation(d, f, "dense arm")
    _assert_conservation(m, f, "dict arm")


def test_first_seen_gid_order_is_preserved() raises:
    """★ THE BYTE-EQUIVALENCE ARGUMENT ITSELF, asserted directly.

    Both routes assign `gid = len(group_keys)` at first sight, so `group_keys`
    must be the keys IN ORDER OF FIRST APPEARANCE. Asserted against the FIXTURE
    rather than against the other arm, so a bug shared by both routes cannot
    pass."""
    var keys: List[Int64] = [7, 3, 7, 9, 3, 1, 9, 7]
    var f = _fx(keys^)
    var d = _run(f, dense=True)

    var want: List[Int] = [7, 3, 9, 1]
    assert_equal(len(d.group_keys), len(want), "group count")
    for g in range(len(want)):
        assert_equal(
            d.group_keys[g], want[g],
            "gid " + String(g) + " must be the key that appeared " + String(g)
            + "-th for the first time",
        )
    var m = _run(f, dense=False)
    _assert_states_identical(d, m, "first-seen order")


# =============================================================================
# §2 NEGATIVES, ZERO-STRADDLING, AND DOWNWARD GROWTH
# =============================================================================


def test_negative_keys_and_a_window_that_straddles_zero() raises:
    """The window is seeded by the FIRST key and then grows DOWNWARD, which
    moves `dense_lo` and shifts every already-assigned slot up. A shift that
    lost or misplaced an entry shows up as a changed gid, which
    `_assert_states_identical` reads.

    Row 0's key is forced POSITIVE so the growth really is downward."""
    var keys = List[Int64](capacity=1000)
    for i in range(1000):
        keys.append(Int64((i % 81) - 40))
    var f = _fx(keys^)
    f.keys[0] = Int64(40)

    var d = _run(f, dense=True)
    var m = _run(f, dense=False)
    _assert_states_identical(d, m, "keys in [-40, 40]")
    assert_equal(len(d.group_keys), 81, "81 distinct keys")
    assert_equal(
        d.stat_gid_dense, f.n(),
        "★ a domain of 81 values spanning zero is DENSE — negative keys must"
        " not push resolution back onto the Dict",
    )
    assert_equal(d.stat_gid_dict, 0, "no Dict probe on a dense signed domain")
    assert_false(d.dense_frozen, "nothing here is out of reach")
    _assert_conservation(d, f, "signed dense arm")


def test_all_negative_keys() raises:
    """Every key negative. `key - dense_lo` is read UNSIGNED, which is what
    makes one compare enough; a naive signed range test breaks here."""
    var keys = List[Int64](capacity=600)
    for i in range(600):
        keys.append(Int64(-1_000_000 - (i % 50)))
    var f = _fx(keys^)
    var d = _run(f, dense=True)
    var m = _run(f, dense=False)
    _assert_states_identical(d, m, "all-negative keys")
    assert_equal(len(d.group_keys), 50, "50 distinct negative keys")
    assert_equal(
        d.stat_gid_dense, f.n(), "all-negative keys must stay dense"
    )
    _assert_conservation(d, f, "all-negative dense arm")


def test_keys_at_the_extremes_of_the_int64_axis() raises:
    """★ THE OVERFLOW CASE — and the source claims it cannot happen, so it is
    asserted rather than reasoned about.

    `Int64.MIN` and `Int64.MAX` in one key column. Three separate pieces of
    arithmetic are exercised at once, and each is a place a signed subtraction
    would be undefined:

      * the HOT PATH's `key - dense_lo` over a pair whose true difference does
        not fit in Int64. It is computed on `Int64` and read UNSIGNED, which is
        what makes it a total function instead of an overflow — and it is why
        one compare covers negatives, a window straddling zero, and a window
        that wraps;
      * `_dense_reshape`'s REACH TEST, written to ADD to the small end
        (`t_hi <= t_lo + (CAP - 1)`) with `t_lo` proven at most `MAX - CAP`,
        precisely so it never subtracts two arbitrary keys;
      * the `_CD_DENSE_GID_KEY_FLOOR` guard, which stops the slack being placed
        BELOW a base that is already at the bottom of the axis.

    The required answer is the Dict arm's, exactly. A 2^64-wide domain is not
    dense, so the only interesting property here is that it is a FALLBACK and
    not a wrong answer or a crash."""
    var keys = List[Int64]()
    keys.append(Int64.MIN)
    keys.append(Int64.MAX)
    keys.append(Int64.MIN)
    keys.append(Int64(0))
    keys.append(Int64.MAX)
    keys.append(Int64(-1))
    keys.append(Int64.MIN)
    var f = _fx(keys^)

    var d = _run(f, dense=True)
    var m = _run(f, dense=False)
    _assert_states_identical(d, m, "Int64.MIN / Int64.MAX in one column")
    assert_equal(
        len(d.group_keys), 4, "MIN, MAX, 0 and -1 are FOUR distinct keys"
    )
    assert_true(
        d.dense_frozen, "a 2^64-wide domain must freeze the window, not wrap"
    )
    assert_true(
        d.stat_gid_dense > 0,
        "the MIN rows sit in the seeded window and must still be served"
        " densely — if this is 0 the case is only testing the Dict",
    )
    _assert_conservation(d, f, "extreme-key dense arm")


def test_a_dense_window_anchored_at_the_bottom_of_the_axis() raises:
    """Three adjacent keys at `Int64.MIN` — a domain 3 wide that sits on the
    very bottom of the Int64 axis.

    The window must still be built (the domain is dense) and must agree with
    the Dict arm. Its slack cannot be placed below `Int64.MIN`, so the
    `_CD_DENSE_GID_KEY_FLOOR` guard puts all of it above: the window base is
    exactly `Int64.MIN` rather than a base that has wrapped past `Int64.MAX`."""
    var keys = List[Int64]()
    for r in range(4):
        keys.append(Int64.MIN)
        keys.append(Int64.MIN + Int64(1))
        keys.append(Int64.MIN + Int64(2))
    var f = _fx(keys^)

    var d = _run(f, dense=True)
    var m = _run(f, dense=False)
    _assert_states_identical(d, m, "keys at the bottom of the axis")
    assert_equal(len(d.group_keys), 3, "three distinct keys, three groups")
    assert_equal(
        d.dense_lo, Int(Int64.MIN),
        "the window base must sit at Int64.MIN, with all slack above it",
    )
    assert_false(
        d.dense_frozen, "a 3-wide domain must not freeze the window"
    )
    assert_equal(
        d.stat_gid_dense, f.n_non_null_keys(),
        "every row must be served by the dense window",
    )
    assert_equal(d.stat_gid_dict, 0, "no row may fall back to the Dict")
    _assert_conservation(d, f, "bottom-of-axis dense arm")


# =============================================================================
# §3 SPARSE-BUT-IN-CAP, AND THE OVER-CAP FALLBACK
# =============================================================================


def test_sparse_keys_inside_the_cap_still_take_the_dense_route() raises:
    """40 keys at stride 1000 — 40 groups over a span of 39,001, well inside
    `_CD_DENSE_GID_DOMAIN_CAP`. The table is mostly holes, and that is fine:
    the cap is on the SPAN, not on the occupancy."""
    var keys = List[Int64](capacity=800)
    for i in range(800):
        keys.append(Int64(5_000_000 + (i % 40) * 1_000))
    var f = _fx(keys^)
    var d = _run(f, dense=True)
    var m = _run(f, dense=False)
    _assert_states_identical(d, m, "sparse in-cap keys")
    assert_equal(len(d.group_keys), 40, "40 distinct keys")
    assert_equal(
        d.stat_gid_dense, f.n(),
        "★ a 39,001-wide span is under the "
        + String(_CD_DENSE_GID_DOMAIN_CAP) + " cap and must stay dense",
    )


def test_over_cap_domain_falls_back_to_the_dict_and_still_agrees() raises:
    """A span far wider than the cap, interleaved with a tight cluster. The
    first unreachable key FREEZES the window; after that every out-of-window
    key resolves through `group_map`. The answer may not change."""
    var keys = List[Int64](capacity=600)
    for i in range(600):
        if (i % 2) == 0:
            keys.append(Int64(i % 8))
        else:
            keys.append(Int64((i % 11) * 100_000_000))
    var f = _fx(keys^)

    var d = _run(f, dense=True)
    var m = _run(f, dense=False)
    _assert_states_identical(d, m, "over-cap mixed domain")
    assert_true(
        d.stat_gid_dict > 0,
        "★ an over-cap domain MUST reach the Dict — if it did not, the"
        " fallback is unexercised and this case proves nothing",
    )
    assert_true(
        d.stat_gid_dense > 0,
        "the in-cluster keys must still be served densely after the freeze",
    )
    assert_true(
        d.dense_frozen,
        "the window must be FROZEN once a key could not be covered",
    )
    _assert_conservation(d, f, "over-cap dense arm")
    _assert_conservation(m, f, "over-cap dict arm")


def test_a_key_beyond_the_cap_freezes_rather_than_allocating() raises:
    """One key at the origin and one exactly `_CD_DENSE_GID_DOMAIN_CAP` away.
    A window covering both needs cap+1 slots, so it must FREEZE rather than
    round the allocation up past the cap."""
    var keys = List[Int64]()
    keys.append(Int64(0))
    keys.append(Int64(_CD_DENSE_GID_DOMAIN_CAP))
    keys.append(Int64(0))
    keys.append(Int64(_CD_DENSE_GID_DOMAIN_CAP))
    var f = _fx(keys^)
    var d = _run(f, dense=True)
    var m = _run(f, dense=False)
    _assert_states_identical(d, m, "exactly-over-cap pair")
    assert_equal(len(d.group_keys), 2, "two distinct keys")
    assert_true(d.dense_frozen, "a cap+1 span must freeze the window")
    assert_true(
        len(d.dense_idx) <= _CD_DENSE_GID_DOMAIN_CAP,
        "the dense table may never exceed the cap",
    )


def test_a_key_at_the_cap_boundary_still_fits() raises:
    """`cap - 1` away is the WIDEST span that fits: a window of exactly
    `_CD_DENSE_GID_DOMAIN_CAP` slots. The neighbouring case above must freeze
    and this one must not — together they pin the boundary to the cap rather
    than to `cap +/- 1`."""
    var keys = List[Int64]()
    keys.append(Int64(0))
    keys.append(Int64(_CD_DENSE_GID_DOMAIN_CAP - 1))
    keys.append(Int64(0))
    keys.append(Int64(_CD_DENSE_GID_DOMAIN_CAP - 1))
    var f = _fx(keys^)
    var d = _run(f, dense=True)
    var m = _run(f, dense=False)
    _assert_states_identical(d, m, "cap-1 span")
    assert_false(
        d.dense_frozen,
        "★ a span of exactly the cap must be served DENSELY — if this freezes,"
        " the widest supported domain is off by one and the boundary claim in"
        " the source is false",
    )
    assert_equal(d.stat_gid_dense, f.n(), "every row dense at the boundary")
    assert_equal(
        len(d.dense_idx), _CD_DENSE_GID_DOMAIN_CAP,
        "the window must be exactly the cap here",
    )


# =============================================================================
# §4 ★ ONE KEY, ONE HOME — the invariant the whole fallback rests on
# =============================================================================


def test_one_key_one_home_after_the_freeze() raises:
    """★ THE SHARPEST CASE IN THIS FILE.

    Sequence: `0` seeds a `_CD_DENSE_GID_SEED_SLOTS`-slot window; `200_000`
    cannot be covered and FREEZES it, taking the Dict; `100` is then outside
    the frozen window and ALSO takes the Dict — even though, had the window
    still been allowed to grow, 100 would have been covered densely.

    That is the point. If the window could grow after `200_000` had been
    written into `group_map`, a later key could become reachable from BOTH
    stores and be handed a SECOND gid — its rows splitting across two output
    rows behind a correct-looking row count. The repeated `100` and `200_000`
    rows are what would catch it: each key must land in exactly one group.

    ⚠ MEASURED CAVEAT, so this docstring does not overclaim: with the freeze
    deleted this case still reds — but on the `dense_frozen` assertion, not on
    the group count, because `_dense_reshape`'s occupied range only widens and
    therefore refuses `200_000` every time. The group-count assertions are a
    guard against a FUTURE sizing policy that could shrink or re-centre in a way
    that makes a refused key reachable again; they are not evidence that today's
    freeze is load-bearing for correctness on its own."""
    var keys: List[Int64] = [0, 200_000, 100, 100, 200_000, 0, 100, 200_000]
    var f = _fx(keys^)

    var d = _run(f, dense=True)
    var m = _run(f, dense=False)
    _assert_states_identical(d, m, "freeze then a would-have-fit key")

    assert_equal(
        len(d.group_keys), 3,
        "★ THREE keys, THREE groups. FOUR would mean a key got a second home",
    )
    assert_true(d.dense_frozen, "200_000 must have frozen the window")
    assert_equal(
        d.group_keys[1], 200_000, "gid 1 is the key that froze the window"
    )
    assert_equal(d.group_keys[2], 100, "gid 2 is the would-have-fit key")
    assert_equal(
        len(d.cd_bufs[0][2]), 3,
        "all three rows of key 100 must share ONE group",
    )
    assert_equal(
        len(d.cd_bufs[0][1]), 3,
        "all three rows of key 200_000 must share ONE group",
    )
    _assert_conservation(d, f, "freeze case")


def test_the_window_does_not_grow_after_the_freeze() raises:
    """The same invariant, read off the table's SIZE. After the freeze a long
    run of keys that would each have extended the window must leave it
    untouched."""
    var keys = List[Int64](capacity=300)
    keys.append(Int64(0))
    keys.append(Int64(10_000_000))  # freezes the window
    for i in range(298):
        keys.append(Int64(i % 200))  # would have grown it to 200 slots
    var f = _fx(keys^)
    var d = _run(f, dense=True)
    var m = _run(f, dense=False)
    _assert_states_identical(d, m, "no post-freeze growth")
    assert_true(d.dense_frozen, "the window must be frozen")
    assert_equal(
        len(d.dense_idx), _CD_DENSE_GID_SEED_SLOTS,
        "★ the window must still be its SEED size — any growth after a key has"
        " been routed to the Dict can give that key a second home",
    )


# =============================================================================
# §5 NULL KEYS, AND THE BATCH BOUNDARY
# =============================================================================


def test_null_keys_are_one_group_on_both_arms() raises:
    """CD-KEY-NULL's group is deliberately NOT in `group_map`, and it is not in
    the dense table either — it is `null_gid`. Both arms must agree on which
    gid it is, and the route counters must count only the NON-NULL rows."""
    var keys = List[Int64](capacity=500)
    var vals = List[Int64](capacity=500)
    var knulls = List[Bool](capacity=500)
    for i in range(500):
        keys.append(Int64(i % 37))
        vals.append(Int64(9_000 + i))
        knulls.append((i % 13) == 5)
    var f = _Fx(keys^, vals^, knulls^)

    assert_true(
        f.n_non_null_keys() < f.n(),
        "the fixture must actually contain NULL keys, or this case is blind",
    )

    var d = _run(f, dense=True)
    var m = _run(f, dense=False)
    _assert_states_identical(d, m, "nullable key column")
    assert_true(d.null_gid >= 0, "the NULL-key group must exist")
    assert_true(
        Int(d.group_is_null(d.null_gid)) == 1,
        "null_gid must point at the NULL group",
    )
    assert_equal(
        d.stat_gid_dense, f.n_non_null_keys(),
        "★ every NON-NULL row goes dense, and a NULL row goes through"
        " neither route — the counters may not charge it to one",
    )
    _assert_conservation(d, f, "nullable-key dense arm")
    _assert_conservation(m, f, "nullable-key dict arm")


def test_the_window_survives_a_batch_boundary() raises:
    """The window is per-STATE, not per-batch: a key first seen in batch 3 must
    join the window batch 1 seeded, and a key seen in two batches must keep its
    gid across the boundary."""
    var fs = List[_Fx]()
    var a: List[Int64] = [50, 51, 52, 50]
    var b: List[Int64] = [10, 51, 11, 90]
    var c: List[Int64] = [90, 50, 12, 10]
    fs.append(_fx(a^))
    fs.append(_fx(b^))
    fs.append(_fx(c^))

    var d = _run_batched(fs, dense=True)
    var m = _run_batched(fs, dense=False)
    _assert_states_identical(d, m, "three batches into one state")
    # First-seen order across the three batches: 50, 51, 52, 10, 11, 90, 12.
    assert_equal(len(d.group_keys), 7, "seven distinct keys over 3 batches")
    assert_equal(d.group_keys[0], 50, "gid 0 is batch 1's first key")
    assert_equal(d.group_keys[3], 10, "gid 3 is batch 2's first NEW key")
    assert_equal(d.group_keys[6], 12, "gid 6 is batch 3's only NEW key")
    assert_equal(
        d.stat_gid_dense, 12,
        "all twelve rows span [10, 90] — one window, every row dense",
    )


def test_hot_path_assignments_widen_the_occupied_range() raises:
    """★ THE SHAPE THE REST OF THIS FILE NEVER DRIVES.

    Keys ASCEND to fill the seed window through the HOT path (so the occupied
    range grows without `_gid_for_key_slow` ever running), and THEN one key
    below the window forces a DOWNWARD reshape. `_dense_reshape` sizes itself
    off `[dense_key_lo, dense_key_hi]`, so if a hot-path assignment does not
    widen that pair the rebuilt window is too SMALL for the slots it has to
    re-home and the re-home loop writes past the end of the fresh table."""
    var keys = List[Int64]()
    for i in range(9):
        keys.append(Int64(i))       # 0 seeds a 16-slot window; 1..8 hot-assign
    keys.append(Int64(-8))          # one below the window -> downward reshape
    for i in range(9):
        keys.append(Int64(i))       # every key must still hold its own gid
    var f = _fx(keys^)
    var d = _run(f, dense=True)
    var m = _run(f, dense=False)
    _assert_states_identical(d, m, "hot-path widening then downward growth")
    assert_equal(len(d.group_keys), 10, "ten distinct keys, ten groups")
    assert_false(d.dense_frozen, "a 17-wide domain is well inside the cap")
    assert_equal(
        d.stat_gid_dense, f.n(), "every row must stay on the dense route"
    )
    _assert_conservation(d, f, "hot-path widening case")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
