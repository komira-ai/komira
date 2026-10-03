# =============================================================================
# test_join_chunk_plan_byte_budget.mojo
#
# Guard for the BYTE-budget join output chunk planner
# (`komira_join_assembly.join_chunk_plan`).
#
# WHAT THIS EXISTS TO FALSIFY
# ---------------------------
# The obvious-but-wrong implementation of "chunk the join output" is a ROW
# constant, or a row count derived from the AVERAGE bytes/row. Both pass a
# uniform-width fixture and both silently break on a SKEWED one — which is the
# shape that actually matters, because wide string keys (48-64 B) are common
# and any real varchar join is skewed.
#
# `test_skew_defeats_an_average_derived_row_count` is the DISCRIMINATING case:
# its fixture is built so that the mean bytes/row and the WORST-CASE bytes/row
# differ by 20x. A planner that divides the budget by the mean produces a chunk
# that overshoots; the exact accumulator does not. The test asserts the
# per-chunk per-column byte total directly (recomputed from the source columns,
# NOT from the planner's own arithmetic), so it is an INDEPENDENT oracle, not a
# self-consistency check.
#
# MUTANT LOG (every one of these must turn this file RED unless marked):
#   M1  cut on `chunk_rows * mean_bytes` instead of the running total
#       -> `skew_defeats_an_average_derived_row_count` FAILS (chunk over budget)
#   M2  drop the "re-price row r into the new chunk" block
#       -> `no_row_is_lost_or_duplicated` still passes (the CUT is right) but
#          `every_chunk_is_within_budget` FAILS on the skew fixture, because the
#          first row of each chunk stops being counted and chunks creep over.
#   M3  price NULL (-1) indices as if they gathered bytes
#       -> `null_sentinel_costs_nothing` FAILS
#   M4  ignore `_offset` in `Column.string_byte_length_at` (the offset-blind
#       read defect class)
#       -> `offset_bearing_string_column_prices_the_right_rows` FAILS
#
# TILED / PARALLEL PRICING MUTANTS.
# The pricing pass tiles [0, n), computes each tile's byte total on the
# pool, and ABSORBS a tile in O(1) when `running + tile_total <= budget` proves
# no cut can be inside it. The per-row loop is the fallback, so the
# bounds must be BIT-IDENTICAL to the untiled planner for every input — which is
# a far stronger contract than "some valid partition", and is what these pin.
#
# ⚠ WHY `force_price_tiles` EXISTS. Without it every case in this file is tiny
# and has no dispatcher, so all of them take the one-tile inline arm and the
# SEAM LOGIC WOULD BE ENTIRELY UNTESTED while the suite reported green. That is
# the specific failure this parameter prevents. The tile count cannot change the
# ANSWER, only which rows the fast path skips, so pinning it is legitimate.
#
#   M5  drop the fast-absorb's per-column loop and absorb on column 0 alone
#       -> `tiled_pricing_matches_the_serial_oracle` FAILS (a chunk overruns
#          budget on the column that was not checked)
#   M6  absorb the tile but forget `chunk_rows += thi - tlo`
#       -> `tiled_pricing_matches_the_serial_oracle` FAILS: `chunk_rows == 0`
#          suppresses the `over` test on the next descended row, so the first
#          cut after an absorbed run goes missing
#   M7  tile with `tile_lo[t] = t * (n // n_tiles)` (the natural-looking
#       formula) instead of `(t * n) // n_tiles`
#       -> `tiled_pricing_matches_the_serial_oracle` FAILS on a prime n: the
#          last tile stops short and the tail rows are never priced -> ROW LOSS
#   M8  price `-1` in `_TilePriceWork` (drop the `if ix < 0: continue`)
#       -> ⚠ **NOT FALSIFIABLE — THE SUITE STAYS GREEN UNDER IT.**
#          Recorded here rather than quietly dropped, because a mutant log that
#          only lists the mutants that worked is a log you cannot trust.
#          WHY it cannot fail: the fast-absorb is sound in ONE direction only.
#          Arrow offsets are non-decreasing, so pricing a sentinel only ever
#          ADDS bytes -> the tile total is too BIG -> the tile fails `fits` and
#          goes down the DESCENT, which is the per-row code and gets
#          the answer right. An over-count costs parallelism, never
#          correctness. The guard is therefore an OUT-OF-BOUNDS-READ guard
#          (`col_offset == 0` makes `row = -1` read before the buffer) plus a
#          silent-deparallelisation guard, and NEITHER is visible in bounds.
#          `tiled_pricing_honors_the_null_sentinel` below pins what CAN be
#          pinned — oracle agreement on sentinel-bearing lists — and says so.
#   M9  drop `col_offset` in `_TilePriceWork` (M4 on the parallel arm)
#       -> `tiled_pricing_honors_the_column_slice_base` FAILS. This one IS
#          falsifiable precisely because it UNDER-counts, which is the only
#          direction that can produce a wrong ABSORB. The M8/M9 asymmetry is
#          the whole safety argument for the fast path, stated as two mutants.
#   (There is no per-chunk index-list copy to mutate: the chunked terminal
#   passes the borrowed lists plus an `(index_lo, index_count)` window, and the
#   window's own mutants — "shift the window / mis-size the count" and "delete
#   the window validation" — belong to the tests of
#   `assemble_join_result_dispatch`, which owns the range check.)
#
# DESCENT-HOIST MUTANTS.
# Five loop-invariants (RecordBatch column-list base reload, 400-byte `Column`
# stride `imul`, `Optional[_offsets]` discriminant + its per-row RAISE edge,
# `_offset` add, offsets base load) are hoisted out of BOTH the parallel
# pricing wave and the serial DESCENT: the descent reads a `_ResolvedCol`
# resolved ONCE per column per call, through the SAME `byte_len_at` the wave's
# worker uses.
#
#   M11 ★ THE BYTE-IDENTICAL MUTANT — the one this lever actually needed.
#       Un-hoist: give `_price_rows_serial` the two `RecordBatch`es back and
#       read `left.column_at(pc.col).string_byte_length_at(idx)` per row again.
#       -> ⚠ **EVERY VALUE ASSERTION IN THIS FILE STAYS GREEN UNDER IT.** It
#          is the same arithmetic on the same operands, so the bounds are
#          identical on every input and no value assertion anywhere can see it.
#          That is exactly the "the lever silently stopped applying" shape, and
#          it is why a correctness-only guard is not enough here.
#          WHAT DOES CATCH IT — structure, both ways:
#            (a) `_price_rows_serial` does not take the batches, so the revert
#                must add parameters, and this file's call — which passes
#                resolved columns and NOTHING else — then fails to compile
#                ("invalid call to '_price_rows_serial': missing required
#                positional argument"). A test target that does not build is
#                RED.
#            (b) with `ref` (rather than `read`) batch parameters the un-hoist
#                does not even compile in the SOURCE — Mojo's exclusivity check
#                rejects it: "argument of '_price_rows_serial' call allows
#                reading a memory location previously writable through another
#                aliased argument", because the descent also takes `running` /
#                `bounds` as `mut`.
#          An all-green run under M11 requires ALSO adapting this file's call
#          site; that adaptation is the thing a reviewer has to refuse.
#   M12 drop `col_offset` from `_ResolvedCol.byte_len_at` (M4/M9 on the hoisted
#       descent — the offset-blind-read defect class)
#       -> `descent_reads_through_the_resolved_column` FAILS, and so does
#          `tiled_pricing_honors_the_column_slice_base`, whose
#          `force_price_tiles=1` ORACLE arm is itself the descent.
#   M13 hoist `_offsets.value()` out of the row loop WITHOUT restating the
#       fail-loud (delete the `is_plain_string()` refusal in
#       `_resolve_priced_cols` and let `.value()` speak for itself)
#       -> the run **ABORTS** — "`Optional.value()` called on empty
#          `Optional`" — i.e. a process kill, not a catchable error. The target
#          is RED either way, and the explicit `raise` is what turns a hard
#          abort into an error a caller can handle. Moving a RAISE out of a loop
#          is the one part of this hoist that can turn a fail-loud into a silent
#          wrong answer, so the refusal is asserted directly.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import SchemaBuilder, Field, RecordBatchBuilder
from komira_arrow.string_array import StringArray
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.offset_overflow import ARROW_INT64_OFFSET_MAX
from komira_join_assembly.join_chunk_plan import (
    join_output_chunk_bounds,
    DEFAULT_JOIN_CHUNK_BUDGET_BYTES,
    ARROW_INT32_OFFSET_LIMIT,
    # Imported so the O(1)
    # cannot-bind predicate can be tested as a PREDICATE — at the int64 ceiling
    # a black-box bounds comparison cannot tell "answered in O(1)" from
    # "walked 200 rows and found no cut", and those differ by the whole lever.
    _budget_can_bind,
    # DESCENT-HOIST internals. Imported ON PURPOSE (mutants M11-M13): the hoist
    # is invisible in `join_output_chunk_bounds`' output, so the guard has to
    # reach the descent and the resolver directly.
    _collect_priced_cols,
    _resolve_priced_cols,
    _price_rows_serial,
)


def _str_batch(name: String, values: List[String]) raises -> RecordBatch:
    """One-column plain-STRING RecordBatch."""
    var sb = SchemaBuilder()
    sb.add_field(Field(name, ArrowType.STRING, False))
    var bb = RecordBatchBuilder.with_capacity(1)
    bb.add_column(Column.from_string(StringArray.from_strings(values)^))
    return bb.build(sb.build())


def _i64_batch(name: String, n: Int) raises -> RecordBatch:
    """One-column INT64 RecordBatch of `n` rows — a side with NOTHING to price.

    The VALUES are irrelevant to the byte budget (a fixed-width column has no
    offsets buffer at all); only the LAYOUT matters, so they are a plain iota."""
    var vals = List[Scalar[DType.int64]](capacity=n)
    for i in range(n):
        vals.append(Scalar[DType.int64](i))
    var sb = SchemaBuilder()
    sb.add_field(Field(name, ArrowType.INT64, False))
    var bb = RecordBatchBuilder.with_capacity(1)
    bb.add_column(Column.from_primitive(PrimitiveArray[DType.int64].from_list(vals)))
    return bb.build(sb.build())


def _one_str(v: String) -> List[String]:
    var out = List[String]()
    out.append(v)
    return out^


def _rep(c: String, n: Int) -> String:
    var s = String("")
    for _ in range(n):
        s += c
    return s^


def _iota(n: Int) -> List[Int]:
    var out = List[Int](capacity=n)
    for i in range(n):
        out.append(i)
    return out^


def _measure_chunk_bytes(
    ref batch: RecordBatch, col: Int, indices: List[Int], lo: Int, hi: Int
) raises -> Int:
    """INDEPENDENT oracle: total UTF-8 bytes chunk [lo, hi) gathers from
    `batch.column(col)`. Recomputed from the SOURCE column via the StringArray
    accessor — deliberately NOT `string_byte_length_at`, so a bug in the
    accessor the planner uses cannot cancel itself out here."""
    var arr = batch.column_as_string(col)
    var total = 0
    for r in range(lo, hi):
        var idx = indices[r]
        if idx < 0:
            continue
        total += arr.get_length(idx)
    return total


def _assert_bounds_wellformed(bounds: List[Int], n: Int) raises:
    assert_true(len(bounds) >= 2, "at least one chunk")
    assert_equal(bounds[0], 0, "first bound is 0")
    assert_equal(bounds[len(bounds) - 1], n, "last bound is n_out")
    for k in range(len(bounds) - 1):
        assert_true(
            bounds[k] <= bounds[k + 1],
            "bounds ascend at k=" + String(k),
        )


def test_unlimited_budget_is_one_chunk() raises:
    """budget <= 0 means UNLIMITED: exactly one chunk, i.e. the chunked terminal
    degenerates to the unchunked one. This is the arm that keeps every
    unbudgeted join byte-identical to the unchunked terminal."""
    var vals = List[String]()
    for i in range(64):
        vals.append(_rep(String("x"), 1 + (i % 7)))
    var left = _str_batch(String("s"), vals)
    var right = _i64_batch(String("v"), 3)
    var li = _iota(64)
    var ri = List[Int](capacity=64)
    for _ in range(64):
        ri.append(0)

    var b = join_output_chunk_bounds(left, right, li, ri, 0)
    _assert_bounds_wellformed(b, 64)
    assert_equal(len(b) - 1, 1, "unlimited budget yields ONE chunk")

    var bneg = join_output_chunk_bounds(left, right, li, ri, -1)
    assert_equal(len(bneg) - 1, 1, "negative budget also means unlimited")


def test_no_priced_column_is_one_chunk() raises:
    """Two fixed-width sides cannot overflow an int32 offset (they have no
    offsets buffer), so the planner must NOT chunk them however small the
    budget. Over-chunking here would split every numeric join."""
    var left = _i64_batch(String("a"), 4)
    var right = _i64_batch(String("b"), 4)
    var li = _iota(4)
    var ri = _iota(4)
    var b = join_output_chunk_bounds(left, right, li, ri, 1)
    assert_equal(len(b) - 1, 1, "no plain-STRING column => one chunk")


def test_empty_result_still_yields_one_chunk() raises:
    """A 0-row join must produce ONE 0-row chunk, not zero chunks — otherwise
    the caller loses the output SCHEMA and downstream sees no columns."""
    var left = _str_batch(String("s"), _one_str(String("a")))
    var right = _i64_batch(String("v"), 1)
    var b = join_output_chunk_bounds(
        left, right, List[Int](), List[Int](), 1024
    )
    assert_equal(len(b), 2, "exactly two bounds")
    assert_equal(b[0], 0, "empty chunk starts at 0")
    assert_equal(b[1], 0, "empty chunk ends at 0")


def test_every_chunk_is_within_budget() raises:
    """The core invariant, checked against the INDEPENDENT byte oracle."""
    var vals = List[String]()
    for i in range(200):
        vals.append(_rep(String("k"), 10 + (i % 5)))  # 10..14 bytes
    var left = _str_batch(String("s"), vals)
    var right = _i64_batch(String("v"), 1)
    var li = _iota(200)
    var ri = List[Int](capacity=200)
    for _ in range(200):
        ri.append(0)

    comptime BUDGET = 100
    var b = join_output_chunk_bounds(left, right, li, ri, BUDGET)
    _assert_bounds_wellformed(b, 200)
    assert_true(len(b) - 1 > 1, "a 2400-byte column at budget 100 must split")

    for k in range(len(b) - 1):
        var got = _measure_chunk_bytes(left, 0, li, b[k], b[k + 1])
        assert_true(
            got <= BUDGET,
            "chunk "
            + String(k)
            + " rows ["
            + String(b[k])
            + ","
            + String(b[k + 1])
            + ") holds "
            + String(got)
            + " B > budget "
            + String(BUDGET),
        )


def test_skew_defeats_an_average_derived_row_count() raises:
    """★ THE DISCRIMINATING CASE (mutant M1/M2).

    Fixture: 100 rows, 95 of them 1 byte and 5 of them 100 bytes, all five long
    rows ADJACENT. Mean = 5.95 B/row. A planner that sizes a chunk as
    `budget // mean` with budget=120 would take 20 rows per chunk; the chunk
    containing the five adjacent 100-byte rows then holds 5*100 + 15*1 = 515 B,
    4.3x over budget. The exact accumulator cuts that region into chunks of at
    most one long row plus filler.

    This is the whole reason the budget is in BYTES and accumulated exactly."""
    var vals = List[String]()
    for i in range(100):
        if i >= 40 and i < 45:
            vals.append(_rep(String("L"), 100))
        else:
            vals.append(String("s"))
    var left = _str_batch(String("s"), vals)
    var right = _i64_batch(String("v"), 1)
    var li = _iota(100)
    var ri = List[Int](capacity=100)
    for _ in range(100):
        ri.append(0)

    comptime BUDGET = 120
    var b = join_output_chunk_bounds(left, right, li, ri, BUDGET)
    _assert_bounds_wellformed(b, 100)

    var worst = 0
    for k in range(len(b) - 1):
        var got = _measure_chunk_bytes(left, 0, li, b[k], b[k + 1])
        if got > worst:
            worst = got
        assert_true(
            got <= BUDGET,
            "SKEW: chunk "
            + String(k)
            + " ["
            + String(b[k])
            + ","
            + String(b[k + 1])
            + ") holds "
            + String(got)
            + " B > budget "
            + String(BUDGET)
            + " — an average-derived row count would land here",
        )
    # Sanity that the fixture really is adversarial: the 20-row window an
    # average-based planner would pick DOES overshoot.
    var avg_window = _measure_chunk_bytes(left, 0, li, 40, 60)
    assert_true(
        avg_window > BUDGET,
        "fixture must be adversarial: rows[40,60) = "
        + String(avg_window)
        + " B should exceed budget "
        + String(BUDGET),
    )


def test_no_row_is_lost_or_duplicated() raises:
    """Chunk boundaries must PARTITION [0, n): contiguous, no gap, no overlap.
    A join terminal that drops or repeats rows here would still 'run' and would
    still produce plausible row counts — this is the guard that makes value
    verification of a chunked join meaningful."""
    var vals = List[String]()
    for i in range(137):
        vals.append(_rep(String("z"), 1 + (i % 23)))
    var left = _str_batch(String("s"), vals)
    var right = _str_batch(String("t"), vals)
    var li = _iota(137)
    var ri = _iota(137)

    var b = join_output_chunk_bounds(left, right, li, ri, 64)
    _assert_bounds_wellformed(b, 137)

    var seen = 0
    for k in range(len(b) - 1):
        assert_equal(
            b[k + 1] - b[k] >= 0, True, "non-negative chunk at " + String(k)
        )
        seen += b[k + 1] - b[k]
    assert_equal(seen, 137, "chunk row counts sum to n_out")

    # And the windows themselves reconstruct the original index list in order.
    # (This walks the bounds directly — the terminal windows the borrowed list
    # instead of copying it.)
    var rebuilt = List[Int]()
    for k in range(len(b) - 1):
        for i in range(b[k], b[k + 1]):
            rebuilt.append(li[i])
    assert_equal(len(rebuilt), 137, "rebuilt length")
    for i in range(137):
        assert_equal(rebuilt[i], li[i], "rebuilt[" + String(i) + "]")


def test_null_sentinel_costs_nothing() raises:
    """Mutant M3. An outer-join `-1` index gathers NO bytes, so it must not be
    priced. If it were priced (e.g. by reading row 0, or by charging a mean),
    an all-NULL right side would chunk needlessly — and worse, `index -1` read
    as a row index is an out-of-bounds offsets read."""
    var vals = List[String]()
    for _ in range(50):
        vals.append(_rep(String("q"), 20))
    var left = _i64_batch(String("v"), 1)
    var right = _str_batch(String("s"), vals)

    var li = List[Int](capacity=50)
    var ri = List[Int](capacity=50)
    for _ in range(50):
        li.append(0)
        ri.append(-1)  # every right row is NULL

    var b = join_output_chunk_bounds(left, right, li, ri, 8)
    assert_equal(
        len(b) - 1, 1, "all-NULL right side gathers 0 bytes => ONE chunk"
    )


def test_offset_bearing_string_column_prices_the_right_rows() raises:
    """Mutant M4 — the offset-blind-read defect class.

    `Column.as_string()` reads `_offsets[0 .. _length]` and IGNORES `_offset`,
    so a planner built on it prices an offset-bearing
    column from the WRONG rows. `string_byte_length_at` adds `_offset`; this
    pins that contract.

    ⚠ WHY THE STATE IS CONSTRUCTED BY HAND rather than via `Column.slice`:
    `slice()` currently RAISES for plain STRING, because
    `supports_zero_copy_slice()` deliberately excludes it — precisely on the
    grounds that "as_string/as_binary read offsets from position 0, IGNORING
    `_offset`". So today no public path can hand this accessor an
    `_offset > 0` STRING column, and a test written through `slice()` would
    only assert that the gate still refuses (which the zero-copy-slice tests
    already do).

    That makes this test forward-looking on purpose: it is the guard that has
    to already be GREEN before anyone admits STRING to
    `supports_zero_copy_slice()`. Writing the accessor offset-blind "because
    nothing slices STRING yet" is exactly how offset-blind reads ship.

    The fixture makes the two readings disagree loudly: rows 0-3 are 1 byte,
    rows 4-7 are 50 bytes, and the view starts at row 4. Offset-blind reads
    1; offset-honoring reads 50."""
    var vals = List[String]()
    for _ in range(4):
        vals.append(String("s"))
    for _ in range(4):
        vals.append(_rep(String("L"), 50))
    # Build the offset-bearing view directly (see the docstring for why).
    var view = Column.from_string(StringArray.from_strings(vals)^)
    var plain = Column.from_string(StringArray.from_strings(vals)^)
    view._offset = 4
    view._length = 4

    assert_true(
        view.is_plain_string(),
        "the view must still be a plain-STRING column (it is what gets priced)",
    )
    for r in range(4):
        var got = view.string_byte_length_at(r)
        assert_equal(
            got,
            50,
            "row "
            + String(r)
            + " of an _offset=4 view must read the LONG half; got "
            + String(got)
            + " (1 means the accessor ignored _offset)",
        )
    # And the un-offset column still reads the SHORT half, so the assertion
    # above cannot be satisfied by an accessor that just always returns 50.
    assert_equal(
        plain.string_byte_length_at(0),
        1,
        "row 0 of the un-offset column is the 1-byte value",
    )


# =============================================================================
# TILED / PARALLEL PRICING
# =============================================================================


def _lcg(mut s: UInt64) -> Int:
    """Deterministic PRNG. A FIXED seed on purpose: a flaky falsifier in this
    area is worse than none, because the failure it is looking for is a silent
    wrong answer that nobody would re-run to confirm."""
    s = s * 6364136223846793005 + 1442695040888963407
    return Int((s >> 33) & 0xFFFFFFFF)


def _assert_bounds_identical(
    got: List[Int], want: List[Int], what: String
) raises:
    """EXACT equality, not just "both are valid partitions".

    Any partition of [0, n) into ascending contiguous ranges yields the same
    output multiset, so a weaker invariants-only check would pass a tiling that
    cuts in different places. That latitude is real but it is not what is being
    asserted here: the fast-absorb predicate is a SOUND over-approximation of
    "no cut inside this tile", so a divergence is never benign — it means the
    predicate admitted a tile it should have descended, i.e. a chunk is over
    budget."""
    assert_equal(
        len(got),
        len(want),
        what
        + ": chunk COUNT differs — tiled produced "
        + String(len(got) - 1)
        + " chunks, serial oracle produced "
        + String(len(want) - 1),
    )
    for i in range(len(want)):
        assert_equal(
            got[i],
            want[i],
            what
            + ": bound["
            + String(i)
            + "] tiled="
            + String(got[i])
            + " serial="
            + String(want[i]),
        )


def test_tiled_pricing_matches_the_serial_oracle() raises:
    """★ THE FALSIFIER FOR THE TILED ARM (mutants M5/M6/M7).

    The untiled planner (`force_price_tiles=1`, which skips the wave entirely
    and runs the plain per-row loop) is the reference ORACLE. The tiled
    planner must reproduce its cut points EXACTLY, over:
      * skewed lengths — the shape that makes an average-based cut wrong, and
        the shape that makes tiles unequal in BYTES though equal in ROWS;
      * TWO priced columns, one per side, so the fast-absorb's per-column loop
        actually has something to disagree about (M5);
      * budgets that produce one chunk, a few chunks, and very many;
      * tile counts that are coprime with n, divide n, exceed the chunk size,
        and equal n — so cuts land BEFORE, INSIDE, and exactly ON tile seams.
    """
    var seed = UInt64(0x9E3779B97F4A7C15)
    var n = 311  # prime: no tile count divides it evenly (M7)
    var lvals = List[String]()
    var rvals = List[String]()
    for _ in range(n):
        # 1..3 bytes usually, 60..91 bytes 1 row in 8 — 20x mean-vs-worst skew.
        var a = _lcg(seed)
        if a % 8 == 0:
            lvals.append(_rep(String("L"), 60 + (a % 32)))
        else:
            lvals.append(_rep(String("s"), 1 + (a % 3)))
        var b = _lcg(seed)
        if b % 5 == 0:
            rvals.append(_rep(String("R"), 40 + (b % 24)))
        else:
            rvals.append(_rep(String("t"), 1 + (b % 2)))
    var left = _str_batch(String("s"), lvals)
    var right = _str_batch(String("t"), rvals)

    # Index lists that are NOT the identity, so a tiling bug cannot be masked by
    # accidentally reading the right row anyway.
    var li = List[Int](capacity=n)
    var ri = List[Int](capacity=n)
    for i in range(n):
        li.append((i * 7) % n)
        ri.append((i * 13 + 5) % n)

    var budgets = List[Int]()
    budgets.append(1 << 20)  # everything fits: ONE chunk, all tiles absorbed
    budgets.append(4000)
    budgets.append(700)
    budgets.append(200)
    budgets.append(64)
    budgets.append(1)  # every row its own chunk: every tile is descended

    var tile_counts = List[Int]()
    tile_counts.append(2)
    tile_counts.append(3)
    tile_counts.append(7)
    tile_counts.append(16)
    tile_counts.append(80)
    tile_counts.append(311)  # one row per tile — every seam is a row boundary
    tile_counts.append(1000)  # clamped to n; exercises the clamp

    for bi in range(len(budgets)):
        var budget = budgets[bi]
        var oracle = join_output_chunk_bounds(
            left, right, li, ri, budget, force_price_tiles=1
        )
        _assert_bounds_wellformed(oracle, n)
        for ti in range(len(tile_counts)):
            var tiles = tile_counts[ti]
            var got = join_output_chunk_bounds(
                left, right, li, ri, budget, force_price_tiles=tiles
            )
            _assert_bounds_wellformed(got, n)
            _assert_bounds_identical(
                got,
                oracle,
                "budget=" + String(budget) + " tiles=" + String(tiles),
            )

    # The fixture must actually EXERCISE the interesting regimes, or this test
    # is a tautology over one chunk.
    var one = join_output_chunk_bounds(
        left, right, li, ri, 1 << 20, force_price_tiles=16
    )
    assert_equal(len(one) - 1, 1, "big budget must be the all-absorbed case")
    var many = join_output_chunk_bounds(
        left, right, li, ri, 64, force_price_tiles=16
    )
    assert_true(
        len(many) - 1 > 16,
        "small budget must cut MORE often than there are tiles (so cuts land"
        " inside tiles, not only on seams); got "
        + String(len(many) - 1)
        + " chunks",
    )


def test_tiled_pricing_cuts_land_on_before_and_after_a_tile_seam() raises:
    """The seam cases, made EXACT rather than statistical.

    120 rows of exactly 10 bytes at budget 100 cuts every 10 rows — bounds are
    0,10,20,...,120 whatever the tiling. Choosing the tile count then places
    every cut deterministically:
      * 12 tiles -> seams at 0,10,...,120: every cut is exactly ON a seam;
      * 8 tiles  -> seams at 0,15,30,...: every cut is strictly INSIDE a tile;
      * 24 tiles -> seams every 5 rows: cuts alternate seam / mid-tile;
      * 7 tiles  -> seams at 0,17,34,51,68,85,102,120: ragged, and the last
        tile is a different size (the M7 shape).
    A tiling that loses the partial tile after a cut, or double-counts the row
    at a seam, changes these bounds and cannot hide behind a row count."""
    var vals = List[String]()
    for _ in range(120):
        vals.append(_rep(String("y"), 10))
    var left = _str_batch(String("s"), vals)
    var right = _i64_batch(String("v"), 1)
    var li = _iota(120)
    var ri = List[Int](capacity=120)
    for _ in range(120):
        ri.append(0)

    var want = List[Int]()
    for k in range(13):
        want.append(k * 10)

    var oracle = join_output_chunk_bounds(
        left, right, li, ri, 100, force_price_tiles=1
    )
    _assert_bounds_identical(
        oracle, want, "the untiled planner itself cuts every 10 rows"
    )

    var tile_counts = List[Int]()
    tile_counts.append(12)  # cut exactly ON every seam
    tile_counts.append(8)  # every cut strictly inside a tile
    tile_counts.append(24)  # alternating
    tile_counts.append(7)  # ragged, uneven last tile
    tile_counts.append(120)  # one row per tile
    for i in range(len(tile_counts)):
        var got = join_output_chunk_bounds(
            left, right, li, ri, 100, force_price_tiles=tile_counts[i]
        )
        _assert_bounds_identical(
            got, want, "seam case tiles=" + String(tile_counts[i])
        )


def test_tiled_pricing_honors_the_null_sentinel() raises:
    """M3 on the tiled arm — but read the honest scope before trusting it.

    `_TilePriceWork` reads `offsets[col_offset + ix]` directly instead of going
    through `Column.string_byte_length_at`, so it carries its OWN `-1` guard.

    ⚠ THIS TEST DOES NOT FALSIFY THE REMOVAL OF THAT GUARD. Under mutant M8
    the whole suite stays green: pricing a sentinel only
    ever ADDS bytes (Arrow offsets are non-decreasing), so the tile total comes
    out too big, the tile fails the fast-absorb test, and the DESCENT — the
    per-row code, with its own `idx < 0` guard — produces the right
    bounds anyway. What the missing guard actually costs is an out-of-bounds
    read at `col_offset == 0` and the silent loss of the parallel fast path;
    neither is expressible as a cut point. See the M8 entry in the mutant log.

    What this test DOES pin, and what it is worth: that sentinel-bearing index
    lists — all-NULL and mixed — produce oracle-identical bounds on the tiled
    arm at every tile count. That covers the descent's own sentinel handling
    and the seam behaviour around NULL runs, which is where a tiling bug in
    outer-join territory would otherwise surface as dropped rows. `-1` handling
    is also the family of a defect class that drops NULL-keyed rows from
    RIGHT/FULL while every value test stays green (`_composite_inner_chunks`
    routes INNER only, so an end-to-end INNER join cannot reach it)."""
    var vals = List[String]()
    for _ in range(200):
        vals.append(_rep(String("q"), 20))
    var left = _i64_batch(String("v"), 1)
    var right = _str_batch(String("s"), vals)

    var li = List[Int](capacity=200)
    var ri = List[Int](capacity=200)
    for _ in range(200):
        li.append(0)
        ri.append(-1)  # every right row is NULL

    var tile_counts = List[Int]()
    tile_counts.append(1)
    tile_counts.append(4)
    tile_counts.append(37)
    tile_counts.append(200)
    for i in range(len(tile_counts)):
        var b = join_output_chunk_bounds(
            left, right, li, ri, 8, force_price_tiles=tile_counts[i]
        )
        _assert_bounds_wellformed(b, 200)
        assert_equal(
            len(b) - 1,
            1,
            "all-NULL right side gathers 0 bytes => ONE chunk, at tiles="
            + String(tile_counts[i])
            + "; got "
            + String(len(b) - 1),
        )

    # And a MIXED list: the sentinel rows must cost nothing while the real ones
    # still cost their bytes, so the tiled and untiled planners agree.
    var mixed = List[Int](capacity=200)
    for i in range(200):
        mixed.append(-1 if (i % 3 == 0) else (i % 200))
    var oracle = join_output_chunk_bounds(
        left, right, li, mixed, 100, force_price_tiles=1
    )
    for i in range(len(tile_counts)):
        var got = join_output_chunk_bounds(
            left, right, li, mixed, 100, force_price_tiles=tile_counts[i]
        )
        _assert_bounds_identical(
            got, oracle, "mixed sentinel tiles=" + String(tile_counts[i])
        )


def test_tiled_pricing_honors_the_column_slice_base() raises:
    """Mutant M9 — M4 on the parallel arm (the offset-blind-read class).

    `_TilePriceWork` carries `col_offset` (the column's `_offset`) because it
    reads the offsets buffer RAW; `string_byte_length_at` adds `_offset` for the
    same reason. Dropping it prices rows [0, n) of the buffer instead of
    [_offset, _offset + n) — the offset-blind-read shape, and it produces a
    plausible answer rather than a crash.

    Fixture: 8 source rows, the first 4 one byte and the last 4 fifty bytes,
    with the batch's column a view starting at row 4. Offset-blind pricing sees
    4 bytes total and never cuts; offset-honoring sees 200 and cuts."""
    var vals = List[String]()
    for _ in range(4):
        vals.append(String("s"))
    for _ in range(4):
        vals.append(_rep(String("L"), 50))

    var view = Column.from_string(StringArray.from_strings(vals)^)
    view._offset = 4
    view._length = 4
    var sb = SchemaBuilder()
    sb.add_field(Field(String("s"), ArrowType.STRING, False))
    var bb = RecordBatchBuilder.with_capacity(1)
    bb.add_column(view^)
    var left = bb.build(sb.build())
    assert_equal(left.num_rows(), 4, "the batch is the 4-row VIEW")

    var right = _i64_batch(String("v"), 1)
    var li = _iota(4)
    var ri = List[Int](capacity=4)
    for _ in range(4):
        ri.append(0)

    # Budget 120 = two 50-byte rows fit, three do not.
    var oracle = join_output_chunk_bounds(
        left, right, li, ri, 120, force_price_tiles=1
    )
    assert_equal(
        len(oracle) - 1,
        2,
        "4 rows x 50 B at budget 120 must be 2 chunks — 1 chunk means the"
        " planner priced the 1-byte half (offset-blind)",
    )
    var tile_counts = List[Int]()
    tile_counts.append(2)
    tile_counts.append(3)
    tile_counts.append(4)
    for i in range(len(tile_counts)):
        var got = join_output_chunk_bounds(
            left, right, li, ri, 120, force_price_tiles=tile_counts[i]
        )
        _assert_bounds_identical(
            got, oracle, "sliced column tiles=" + String(tile_counts[i])
        )


# =============================================================================
# DESCENT HOIST
# =============================================================================


def test_descent_reads_through_the_resolved_column() raises:
    """★ THE STRUCTURAL PIN FOR THE HOIST (mutants M11 + M12).

    Two things are asserted here, and the FIRST one is asserted by the mere fact
    that this function compiles:

    (1) THE DESCENT NEEDS NO `RecordBatch`. `_price_rows_serial` is called below
        with the priced-column list, the two RESOLVED column lists, the two
        index lists and the budget — and nothing else. The `left` / `right`
        batches are deliberately not passed. So the un-hoist (M11) cannot be
        written without adding a parameter to that signature, and this test then
        stops compiling. That is the ONLY guard that works here: under M11
        every value assertion in this file stays GREEN, because it is the
        same arithmetic on the same operands. A perf hoist that silently
        regresses is not observable any other way.

    (2) `_ResolvedCol` CARRIES `col_offset` (M12 — the offset-blind-read
        defect class). The fixture is the M9 fixture: 8 source
        rows, the first four 1 byte and the last four 50, viewed from row 4.
        Offset-blind resolution reads 1; offset-honoring reads 50, and only the
        latter cuts 4 rows at budget 120 into 2 chunks.

    And the bounds the descent produces standalone are asserted EQUAL to what
    the full planner produces at `force_price_tiles=1`, so this isolated call
    cannot drift away from the path production actually takes."""
    var vals = List[String]()
    for _ in range(4):
        vals.append(String("s"))
    for _ in range(4):
        vals.append(_rep(String("L"), 50))

    var view = Column.from_string(StringArray.from_strings(vals)^)
    view._offset = 4
    view._length = 4
    var sb = SchemaBuilder()
    sb.add_field(Field(String("s"), ArrowType.STRING, False))
    var bb = RecordBatchBuilder.with_capacity(1)
    bb.add_column(view^)
    var left = bb.build(sb.build())
    var right = _i64_batch(String("v"), 1)

    var priced = _collect_priced_cols(left, right)
    assert_equal(len(priced), 1, "exactly one priced column (the STRING view)")
    assert_equal(priced[0].from_left, True, "it is on the LEFT")
    assert_equal(priced[0].slot, 0, "its resolved slot is 0")

    var lcols = List[Int]()
    lcols.append(priced[0].col)
    var lres = _resolve_priced_cols(left, lcols)
    var rres = _resolve_priced_cols(right, List[Int]())
    assert_equal(len(lres), 1, "one resolved LEFT column")
    assert_equal(len(rres), 0, "no resolved RIGHT column")

    # M12: the slice base survived the hoist, and the hoisted read agrees with
    # the accessor the pre-hoist descent used.
    assert_equal(
        lres[0].col_offset,
        4,
        "the resolved column must CARRY the source column's _offset; 0 means"
        " the hoist dropped it (offset-blind pricing)",
    )
    for r in range(4):
        assert_equal(
            lres[0].byte_len_at(r),
            50,
            "resolved byte_len_at("
            + String(r)
            + ") must read the LONG half of the _offset=4 view",
        )

    var li = _iota(4)
    var ri = List[Int](capacity=4)
    for _ in range(4):
        ri.append(0)

    # THE CALL WITH NO BATCHES IN IT. See (1) above.
    var running = List[Int]()
    running.append(0)
    var chunk_rows = 0
    var bounds = List[Int]()
    bounds.append(0)
    _price_rows_serial(
        priced, lres, rres, li, ri, 120, 0, 4, running, chunk_rows, bounds
    )
    bounds.append(4)

    _assert_bounds_wellformed(bounds, 4)
    assert_equal(
        len(bounds) - 1,
        2,
        "4 rows x 50 B at budget 120 must be 2 chunks — 1 chunk means the"
        " descent priced the 1-byte half (offset-blind)",
    )

    # ... and it is the SAME answer the whole planner gives on its descent arm.
    var oracle = join_output_chunk_bounds(
        left, right, li, ri, 120, force_price_tiles=1
    )
    _assert_bounds_identical(
        bounds, oracle, "standalone descent vs the planner's descent arm"
    )


def test_resolve_refuses_a_column_with_no_offsets() raises:
    """Mutant M13 — the RAISE that the hoist MOVED.

    Tested inside the per-row loop (via `Column.string_byte_length_at` ->
    `_offsets.value()`), the `Optional[_offsets]` discriminant makes a column
    with no offsets buffer fail loudly at the first row it prices. The hoist
    moves that test out of the loop — which is precisely the way a
    loop-invariant hoist can convert a fail-loud into a silent wrong answer, so
    the refusal is restated explicitly in `_resolve_priced_cols` and asserted
    here rather than left to `.value()`'s implicit abort.

    An INT64 column is the case that matters: it has no offsets buffer at all.
    Under M13 (the refusal deleted), this run does not
    return a wrong answer and does not raise — it **ABORTS the process**
    (``Optional.value()` called on empty `Optional``). The explicit `raise` is
    therefore not decoration; it is what makes the failure catchable by a caller
    instead of a kill. The planner itself can never reach this
    (`_collect_priced_cols` admits only `is_plain_string()` columns) — which is
    exactly why the guard needs a direct test to exist at all."""
    var b = _i64_batch(String("v"), 4)
    var cols = List[Int]()
    cols.append(0)
    var raised = 0
    try:
        var _r = _resolve_priced_cols(b, cols)
    except:
        raised += 1
    assert_equal(
        raised, 1, "resolving a non-plain-STRING column must RAISE, not proceed"
    )

    # And the empty request is not an error — it is the "this side prices
    # nothing" case the planner hits on every join with a fixed-width side.
    var none = _resolve_priced_cols(b, List[Int]())
    assert_equal(len(none), 0, "resolving zero columns yields an empty list")


def test_arrow_limit_constant_is_the_int32_ceiling() raises:
    """The constant this whole module exists to stay under. Pinned so a future
    'let's just bump the budget' edit has to confront it."""
    assert_equal(
        ARROW_INT32_OFFSET_LIMIT, 2147483647, "Arrow int32 offset ceiling"
    )
    assert_true(
        DEFAULT_JOIN_CHUNK_BUDGET_BYTES < ARROW_INT32_OFFSET_LIMIT,
        "the default budget must sit UNDER the ceiling it protects",
    )




# =============================================================================
# The UNREACHABLE budget.
# =============================================================================
#
# The join assemble's string gather PROMOTES to Int64 offsets rather than
# narrowing, so the Arrow Int32 ceiling this module's DEFAULT budget is derived
# from cannot bind the terminal that calls it. A caller that
# wants THIS leaf without the pricing walk therefore needs a way to say "no
# budget" that is NOT `<= 0` — because `<= 0` ALSO means "delegate to the
# unchunked leaf" one level up, and a lever built on it would be a route change
# (a different, slower plan with byte-identical output) reported as a pricing
# win. `>= ARROW_INT64_OFFSET_MAX` is that spelling.
# =============================================================================


def test_unreachable_budget_cannot_bind_and_costs_no_walk() raises:
    """A budget at the int64 ceiling yields ONE chunk, and does so WITHOUT
    pricing a row.

    ⚠ THE PREDICATE IS ASSERTED DIRECTLY, NOT INFERRED FROM THE BOUNDS. At
    2^63-1 the per-row walk would ALSO return `[0, n]` — correctly, having done
    every subtraction. So a bounds-only test is GREEN whether the O(1) exit
    exists or not, which makes it no test of this change at all. `_budget_can_
    bind` is the thing that moved; it is what gets asserted."""
    assert_true(
        not _budget_can_bind(ARROW_INT64_OFFSET_MAX),
        "a budget AT the int64 ceiling must be recognised as unable to bind —"
        " that ceiling is ~9.2 exabytes and a per-column total counts bytes in"
        " a RESIDENT buffer",
    )
    assert_true(
        not _budget_can_bind(0), "0 is the caller's explicit UNLIMITED"
    )
    assert_true(not _budget_can_bind(-1), "a negative budget is unlimited too")

    # ⛔ AND THE ORDINARY RANGE IS UNTOUCHED. If this flips, every join
    # silently stops chunking.
    assert_true(_budget_can_bind(1), "1 byte is a budget that binds")
    assert_true(
        _budget_can_bind(DEFAULT_JOIN_CHUNK_BUDGET_BYTES),
        "the shipped 1 GiB default must still BIND — it is the value every"
        " unarmed run uses, and a predicate that excluded it would disable"
        " chunking for everybody",
    )
    assert_true(
        _budget_can_bind(ARROW_INT64_OFFSET_MAX - 1),
        "one byte BELOW the ceiling still binds — the exit is the ceiling"
        " itself, not a neighbourhood of it",
    )

    # The end-to-end answer, over a fixture that DOES split at a real budget.
    var vals = List[String]()
    for i in range(200):
        vals.append(_rep(String("k"), 10 + (i % 5)))
    var left = _str_batch(String("s"), vals)
    var right = _i64_batch(String("v"), 1)
    var li = _iota(200)
    var ri = List[Int](capacity=200)
    for _ in range(200):
        ri.append(0)

    var split = join_output_chunk_bounds(left, right, li, ri, 100)
    assert_true(
        len(split) - 1 > 1,
        "the fixture must split at a binding budget, or the contrast below is"
        " between two one-chunk answers and proves nothing",
    )

    var b = join_output_chunk_bounds(
        left, right, li, ri, ARROW_INT64_OFFSET_MAX
    )
    _assert_bounds_wellformed(b, 200)
    assert_equal(
        len(b) - 1, 1, "an unreachable budget yields exactly ONE chunk"
    )


def test_unreachable_budget_agrees_with_the_per_row_planner() raises:
    """The O(1) exit returns what the WALK would have returned — bit-identical.

    This is the soundness half, and it is separate from the leg above on
    purpose: that one pins that the walk is SKIPPED, this one pins that
    skipping it did not change the answer. `force_price_tiles=1` is the serial
    DESCENT, i.e. the per-row oracle this whole module is validated against
    (`test_tiled_pricing_matches_the_serial_oracle`), driven here at a budget
    one byte BELOW the ceiling — which BINDS, so it takes the real walk — and
    compared with the exit's answer at the ceiling itself.

    ⚠ THE FIXTURE IS SKEWED AND CARRIES A `-1` SENTINEL, because the two
    properties a cheap exit could plausibly break are per-row skew and the
    outer-join null. If the exit ever grew a condition the walk does not share,
    this is where it shows up."""
    var vals = List[String]()
    for i in range(128):
        vals.append(_rep(String("z"), 1 + ((i * 13) % 37)))
    var left = _str_batch(String("s"), vals)
    var right = _i64_batch(String("v"), 1)
    var li = List[Int](capacity=128)
    var ri = List[Int](capacity=128)
    for i in range(128):
        li.append(-1 if (i % 11) == 0 else i)
        ri.append(0)

    var walked = join_output_chunk_bounds(
        left, right, li, ri, ARROW_INT64_OFFSET_MAX - 1, force_price_tiles=1
    )
    var exited = join_output_chunk_bounds(
        left, right, li, ri, ARROW_INT64_OFFSET_MAX, force_price_tiles=1
    )
    assert_equal(
        len(walked),
        len(exited),
        "the O(1) exit returned a DIFFERENT NUMBER OF CHUNKS than the per-row"
        " walk at a budget one byte below it",
    )
    for k in range(len(walked)):
        assert_equal(
            walked[k],
            exited[k],
            "bound " + String(k) + " differs between the walk and the exit",
        )
    _assert_bounds_wellformed(exited, 128)


def main() raises:
    var suite = TestSuite()
    suite.test[test_unlimited_budget_is_one_chunk]()
    suite.test[test_unreachable_budget_cannot_bind_and_costs_no_walk]()
    suite.test[test_unreachable_budget_agrees_with_the_per_row_planner]()
    suite.test[test_no_priced_column_is_one_chunk]()
    suite.test[test_empty_result_still_yields_one_chunk]()
    suite.test[test_every_chunk_is_within_budget]()
    suite.test[test_skew_defeats_an_average_derived_row_count]()
    suite.test[test_no_row_is_lost_or_duplicated]()
    suite.test[test_null_sentinel_costs_nothing]()
    suite.test[test_offset_bearing_string_column_prices_the_right_rows]()
    # The tiled/parallel pricing arm.
    suite.test[test_tiled_pricing_matches_the_serial_oracle]()
    suite.test[test_tiled_pricing_cuts_land_on_before_and_after_a_tile_seam]()
    suite.test[test_tiled_pricing_honors_the_null_sentinel]()
    suite.test[test_tiled_pricing_honors_the_column_slice_base]()
    # The serial descent's hoist.
    suite.test[test_descent_reads_through_the_resolved_column]()
    suite.test[test_resolve_refuses_a_column_with_no_offsets]()
    suite.test[test_arrow_limit_constant_is_the_int32_ceiling]()
    suite^.run()
