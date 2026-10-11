# =============================================================================
# ONE-COLUMN CONCAT ADMISSION — routing falsifier + independent value oracle
# =============================================================================
#
# (cbq05). THE DEFECT, stated structurally:
#
#   `streaming_concat_parallel._concat_impl` gated its whole parallel branch on
#   `num_cols >= _MIN_COLS_FOR_PARALLEL (2)`. A ONE-column resident collect
#   therefore returned `_concat_serial` before the row-range TILED route --
# which has split a single column across the pool since LEVER A
#   -- was ever consulted. cbq05 (`count(DISTINCT search_phrase)`) collects
#   exactly one STRING column of 99,997,497 rows / 740 MB of payload, and that
#   concat ran on the DRIVER thread for ~295 of a ~620 ms warm rep while all
#   twenty workers idled (the benchmark host, 2026-09-24 diagnosis hold).
#
# The column count was never the right question for a one-column concat. The
# incumbent one-task-per-COLUMN fan really is pure overhead at one column, so
# the old gate was right to refuse THAT fan; what it also refused, by being
# checked first, was the tiled fan, whose width comes from the bytes and the
# pool. The fix admits a one-column concat exactly when the tiling rule says
# the column is worth cutting (`tiles >= 2`), and keeps it serial otherwise.
#
# ⚠ WHY THIS FILE ASSERTS ON ROUTING AND NEVER ON A DURATION: wall-clock
# assertions are banned here (build-blocking flakes), and the defect's own
# signature is "no fork was recorded". The instrument is `grain_geometry`:
# `_concat_tiled` records `SITE_CONCAT` immediately before its fork, and
# `_concat_serial` returns upstream of every record. So
#     calls == 0            -> the concat stayed on the driver (the defect)
#     calls == 1, morsels>=2 -> it was cut into row-range tiles on the pool
#
# ⚠ THE VALUE ORACLE IS INDEPENDENT OF BOTH CONCAT PATHS. Every expected value
# is regenerated from the fixture's own row generator, never read back out of
# another concat. Two checks, deliberately different in kind:
#   * ORDERED: output row r equals generated row r. A concat is an end-to-end
#     layout, so order is part of the answer; a tile that wrote its rows at the
#     wrong destination cursor fails here.
#   * SORTED MULTISET: sort(output) == sort(generated). This one is blind to
#     order on purpose -- it names a DROPPED, DUPLICATED or CORRUPTED row even
#     if some future change legitimately re-orders.
# Plus the offsets buffer itself (slot 0 is the driver's, the last slot is the
# payload length, monotone in between), because an offsets off-by-one is a
# plausible wrong answer rather than a crash.
#
# ⚠ R4/R5 ARE WHAT MAKE R1..R3 NON-VACUOUS. They drive fixtures that must STAY
# serial -- under the tiling row floor, and on a ONE-worker pool (where one
# task would be pure overhead) -- and assert the census reads ZERO. An
# instrument that can only answer "forked" proves nothing by answering it.
#
# ⚠ R6 IS THE DESTROY-RECREATE LEG. A fresh runtime per iteration, the same
# one-column fork each time: the gap6/gap7 class only manifests across
# teardown/re-create of the pool the tiled State is dispatched on.
#
# ⚠ R7 IS THE SECOND DEFECT THE FIRST FIX EXPOSED. Admitted, cbq05's concat
# forked 20 equal-ROW tiles whose payload-plus-offsets cost ranged 32.7..151.1
# MB against a 56.8 MB mean, so the fork ran at occupancy 0.49-0.63. R7 pins
# `concat_string_tile_bounds.string_tile_row_bounds` to a ONE-ROW balance bound
# computed from the generator alone, and proves the fixture is skewed enough
# that an equal-row cut breaks it. It FAILED against an equal-row stub of the
# same signature before the byte-balanced body landed.
#
# FIXTURES: ragged batch sizes (zero-row and one-row batches included) so tile
# boundaries land strictly inside batches, and cbq05's own value shape -- most
# rows EMPTY, the rest variable-length and carrying their row number, so a
# mis-strided offset cannot reproduce a plausible value -- plus a BYTE-HEAVY
# row band, so R1/R2/R6 also drive byte-balanced bounds that fall far from the
# equal-row ones through the whole concat, values checked.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.string_array import StringArray
from komira_arrow.schema import (
    Field,
    RecordBatch,
    RecordBatchBuilder,
    SchemaBuilder,
)
from komira_collections.slab import Slab

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.runtime import PLACEMENT_FIXED, PerCoreAsyncRuntime
from komira_async.runtime.sched_trace import SITE_CONCAT

from komira_engine_runtime.grain_geometry import (
    GRAIN_F_MORSELS,
    grain_geometry_calls,
    grain_geometry_field,
    grain_geometry_reset,
)
from komira_engine_runtime.concat_string_tile_bounds import (
    STRING_TILE_ROW_COST_BYTES,
    string_tile_row_bounds,
)
from komira_engine_runtime.streaming_concat_parallel import (
    concat_record_batches_column_parallel,
)


# The tiled route's own row floor (`streaming_concat_parallel.
# _TILE_ENTRY_MIN_ROWS`), mirrored so a fixture that silently falls under it
# is a loud failure rather than a both-arms-serial comparison.
comptime _TILE_ENTRY_MIN_ROWS: Int = 131_072

# A pool wide enough for `parallel_copy_tiles` to cut, small enough for any box.
comptime _WORKERS: Int = 4


def _noop_sink_factory() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


# =============================================================================
# Fixture generators (THE ORACLE'S SOURCE OF TRUTH)
# =============================================================================


comptime _HEAVY_LO: Int = 60_000
comptime _HEAVY_HI: Int = 70_000
"""A BYTE-HEAVY row band, so the fixture is skewed the way cbq05's column is
(its 20 equal-ROW tiles ranged 32.7..151.1 MB against a 56.8 MB mean)."""


def _phrase(i: Int) -> String:
    """cbq05's shape: three rows in four are EMPTY; the rest vary in length and
    carry their own row number, so no two non-empty rows share a byte extent.
    Rows in [_HEAVY_LO, _HEAVY_HI) carry a ~300-byte tail, so equal ROW ranges
    are very unequal BYTE ranges (R7 asserts the fixture is that skewed)."""
    if (i * 7919) % 4 != 1:
        return String("")
    var s = String("q") + String(i)
    for _k in range(i % 13):
        s += "-x"
    if i >= _HEAVY_LO and i < _HEAVY_HI:
        for _k in range(150):
            s += "-y"
    return s^


def _is_null_row(i: Int) -> Bool:
    """Null period 5 -- coprime to every ragged size below, so nulls straddle
    every tile boundary rather than aligning with one."""
    return (i % 5) == 2


def _ragged_sizes(min_total: Int) -> List[Int]:
    """Batch sizes cycling through a ragged pattern (a ZERO-row and a ONE-row
    batch included) until the total reaches `min_total`."""
    var pattern: List[Int] = [4099, 1, 0, 3571, 2048, 5003, 17, 4096, 2777]
    var out = List[Int]()
    var total = 0
    var k = 0
    while total < min_total:
        var n = pattern[k % len(pattern)]
        out.append(n)
        total += n
        k += 1
    return out^


def _total(imm sizes: List[Int]) -> Int:
    var t = 0
    for i in range(len(sizes)):
        t += sizes[i]
    return t


def _string_batch(base: Int, n: Int, nullable: Bool) raises -> RecordBatch:
    var strs = List[String]()
    var valid = List[Bool]()
    for j in range(n):
        var i = base + j
        if nullable and _is_null_row(i):
            strs.append(String(""))
            valid.append(False)
        else:
            strs.append(_phrase(i))
            valid.append(True)
    var sb = SchemaBuilder()
    sb.add_field(Field("search_phrase", ArrowType.STRING, nullable))
    var b = RecordBatchBuilder()
    if nullable:
        b.add_column(
            Column.from_string(StringArray.from_strings_with_validity(strs, valid))
        )
    else:
        b.add_column(Column.from_string(StringArray.from_strings(strs)))
    return b.build(sb.build())


def _int_batch(base: Int, n: Int) raises -> RecordBatch:
    var a = PrimitiveArray[DType.int64].allocate(n)
    var p = a._typed_ptr_mut()
    for j in range(n):
        (p + j)[] = Int64((base + j) * 3 + 1)
    var sb = SchemaBuilder()
    sb.add_field(Field("v", ArrowType.INT64, False))
    var b = RecordBatchBuilder()
    b.add_column(Column.from_primitive[DType.int64](a^))
    return b.build(sb.build())


def _string_batches(imm sizes: List[Int], nullable: Bool) raises -> Slab[RecordBatch]:
    var out = Slab[RecordBatch].create(len(sizes))
    var base = 0
    for m in range(len(sizes)):
        out.append(_string_batch(base, sizes[m], nullable))
        base += sizes[m]
    return out^


def _int_batches(imm sizes: List[Int]) raises -> Slab[RecordBatch]:
    var out = Slab[RecordBatch].create(len(sizes))
    var base = 0
    for m in range(len(sizes)):
        out.append(_int_batch(base, sizes[m]))
        base += sizes[m]
    return out^


# =============================================================================
# Driver -- a REAL multi-worker pool, torn down on return
# =============================================================================


def _drive(var batches: Slab[RecordBatch], workers: Int) raises -> RecordBatch:
    var runtime = PerCoreAsyncRuntime[NoopSink](
        num_workers=workers,
        sink_factory=_noop_sink_factory,
        backend=BACKEND_MOCK,
        placement=PLACEMENT_FIXED,
    )
    var ct = CancellationToken.new()
    ref disp = runtime.dispatcher()
    var out = concat_record_batches_column_parallel(
        batches^, disp, ct^
    )
    _ = runtime^
    return out^


# =============================================================================
# Routing assertions
# =============================================================================


def _assert_tiled_fork(label: String) raises:
    """THE FALSIFIER. Reds on the pre-change code, where `num_cols < 2` sent a
    one-column concat to `_concat_serial` and no fork was ever recorded."""
    var calls = grain_geometry_calls(SITE_CONCAT)
    if calls != 1:
        raise Error(
            label + ": ROUTING FAILURE -- expected exactly ONE fork at"
            " SITE_CONCAT, got calls=" + String(calls) + ". calls=0 IS the"
            " defect: a one-column concat above the tiling floor stayed on"
            " the driver thread while the pool idled."
        )
    var tiles = grain_geometry_field(SITE_CONCAT, GRAIN_F_MORSELS)
    if tiles < 2:
        raise Error(
            label + ": the fork recorded " + String(tiles) + " tile(s). A"
            " one-column concat must be ADMITTED only onto the row-range tiled"
            " route (tiles >= 2) -- the one-task-per-column fan is ONE task at"
            " one column, i.e. pure dispatch overhead."
        )


def _assert_stayed_serial(label: String) raises:
    var calls = grain_geometry_calls(SITE_CONCAT)
    if calls != 0:
        raise Error(
            label + ": expected the concat to stay SERIAL (calls=0), got"
            " calls=" + String(calls) + " -- a shape the tiling rule declines"
            " must not be forked as a single task."
        )


def _assert_non_vacuous(label: String, total_rows: Int) raises:
    if total_rows < _TILE_ENTRY_MIN_ROWS:
        raise Error(
            label + ": VACUOUS FIXTURE -- " + String(total_rows) + " rows is"
            " under the tiled route's row floor ("
            + String(_TILE_ENTRY_MIN_ROWS) + "), so no fix could fork it."
        )


# =============================================================================
# Value oracles (independent of every concat path)
# =============================================================================
#
# ⚠ BYTE-LEVEL, NOT `as_string().get(r)`: the rows are read straight off the
# concatenated `offsets` + `data` buffers the tiles wrote, so no accessor sits
# between the oracle and the bytes under test.
#
# ⚠ AND THE MULTISET SORTS UNIQUE KEYS. Three rows in four are "" by design
# (cbq05's shape), so the sorted oracle is spelled as (a) the EMPTY count and
# (b) the sorted FNV-1a fingerprints of the NON-empty values -- every non-empty
# value embeds its row number, so those keys are unique and the sort never sees
# a long duplicate run. Equal as multisets iff (a) and (b) are equal (a 64-bit
# collision aside).


def _fnv1a(imm bytes: List[UInt8]) -> Int:
    var h = UInt64(0xCBF29CE484222325)
    for k in range(len(bytes)):
        h = (h ^ UInt64(bytes[k])) * UInt64(0x100000001B3)
    return Int(h)


def _phrase_bytes(i: Int) -> List[UInt8]:
    var e = _phrase(i)
    var bs = e.as_bytes()
    var out = List[UInt8](capacity=len(bs))
    for k in range(len(bs)):
        out.append(bs[k])
    return out^


def _row_bytes(imm out: RecordBatch, r: Int) -> List[UInt8]:
    ref col = out.column_at(0)
    var lo = Int(col._offsets.value().get_typed[Int32](r))
    var hi = Int(col._offsets.value().get_typed[Int32](r + 1))
    var got = List[UInt8](capacity=hi - lo)
    for k in range(lo, hi):
        got.append(col._data.get_typed[UInt8](k))
    return got^


def _assert_offsets_sane(label: String, imm out: RecordBatch) raises:
    """Slot 0 is the driver's (no tile owns it), the last slot is the payload
    length, and nothing in between goes backwards."""
    ref col = out.column_at(0)
    assert_true(Bool(col._offsets), label + ": STRING column has no offsets")
    var n = col._length
    var prev = col._offsets.value().get_typed[Int32](0)
    assert_equal(Int(prev), 0, label + ": offsets[0] must be 0")
    for r in range(1, n + 1):
        var cur = col._offsets.value().get_typed[Int32](r)
        if cur < prev:
            raise Error(
                label + ": offsets go BACKWARDS at slot " + String(r) + " ("
                + String(prev) + " -> " + String(cur) + ")"
            )
        prev = cur
    assert_equal(
        Int(prev), col._data.len(), label + ": offsets[n] must equal payload len"
    )


def _assert_strings_match(
    label: String, imm out: RecordBatch, total: Int, nullable: Bool
) raises:
    assert_equal(out.num_columns(), 1, label + ": column count")
    assert_equal(out.num_rows(), total, label + ": row count")
    assert_true(
        out.column_at(0).arrow_type == ArrowType.STRING, label + ": type"
    )
    _assert_offsets_sane(label, out)

    var got_fp = List[Int]()
    var want_fp = List[Int]()
    var got_empty = 0
    var want_empty = 0
    var want_nulls = 0
    for r in range(total):
        var exp_null = nullable and _is_null_row(r)
        var is_null = out.column_at(0).is_null_at(r)
        if is_null != exp_null:
            raise Error(
                label + ": NULL-ness wrong at row " + String(r) + " (got "
                + String(is_null) + ", want " + String(exp_null) + ")"
            )
        if exp_null:
            want_nulls += 1
            continue
        var g = _row_bytes(out, r)
        var e = _phrase_bytes(r)
        # ORDERED: the end-to-end layout is part of a concat's answer.
        var same = len(g) == len(e)
        if same:
            for k in range(len(e)):
                if g[k] != e[k]:
                    same = False
                    break
        if not same:
            raise Error(
                label + ": row " + String(r) + " holds " + String(len(g))
                + " byte(s) that differ from its generated value '"
                + _phrase(r) + "' (" + String(len(e)) + " byte(s))"
            )
        if len(g) == 0:
            got_empty += 1
        else:
            got_fp.append(_fnv1a(g))
        if len(e) == 0:
            want_empty += 1
        else:
            want_fp.append(_fnv1a(e))
    assert_equal(
        out.column_at(0).null_count(), want_nulls, label + ": null_count"
    )

    # SORTED MULTISET: order-blind, so it names a dropped / duplicated /
    # corrupted row independently of the ordered check above.
    assert_equal(got_empty, want_empty, label + ": EMPTY-value count")
    sort(got_fp)
    sort(want_fp)
    assert_equal(len(got_fp), len(want_fp), label + ": multiset size")
    for k in range(len(got_fp)):
        if got_fp[k] != want_fp[k]:
            raise Error(
                label + ": SORTED ORACLE diverges at rank " + String(k)
            )


def _assert_ints_match(label: String, imm out: RecordBatch, total: Int) raises:
    assert_equal(out.num_columns(), 1, label + ": column count")
    assert_equal(out.num_rows(), total, label + ": row count")
    assert_equal(out.column_at(0).null_count(), 0, label + ": null_count")
    ref col = out.column_at(0)
    var got = List[Int]()
    var want = List[Int]()
    for r in range(total):
        var v = Int(col._data.get_typed[Int64](r))
        var e = r * 3 + 1
        if v != e:
            raise Error(
                label + ": row " + String(r) + " is " + String(v) + ", want "
                + String(e)
            )
        got.append(v)
        want.append(e)
    # Unique by construction (3r+1), so the sort is duplicate-free.
    sort(got)
    sort(want)
    for k in range(len(got)):
        if got[k] != want[k]:
            raise Error(label + ": SORTED ORACLE diverges at rank " + String(k))


# =============================================================================
# R1..R3 -- the falsifiers: ONE column above the floor MUST fork, tiled
# =============================================================================


def test_r1_one_string_column_forks_tiled() raises:
    """THE cbq05 SHAPE. One non-null STRING column, mostly empty rows, ragged
    batches, 4 workers. Pre-change: calls=0 (serial on the driver)."""
    var label = String("R1 one STRING column")
    var sizes = _ragged_sizes(160_000)
    var total = _total(sizes)
    _assert_non_vacuous(label, total)
    grain_geometry_reset()
    var out = _drive(_string_batches(sizes, False), _WORKERS)
    _assert_tiled_fork(label)
    _assert_strings_match(label, out, total, False)


def test_r2_one_nullable_string_column_forks_tiled() raises:
    """One NULLABLE STRING column -- the kind-2 validity item runs next to the
    string tiles, and nulls straddle every tile boundary."""
    var label = String("R2 one NULLABLE STRING column")
    var sizes = _ragged_sizes(160_000)
    var total = _total(sizes)
    _assert_non_vacuous(label, total)
    grain_geometry_reset()
    var out = _drive(_string_batches(sizes, True), _WORKERS)
    _assert_tiled_fork(label)
    _assert_strings_match(label, out, total, True)


def test_r3_one_int64_column_forks_tiled() raises:
    """One fixed-width column -- the kind-0 tile route at one column."""
    var label = String("R3 one INT64 column")
    var sizes = _ragged_sizes(200_000)
    var total = _total(sizes)
    _assert_non_vacuous(label, total)
    grain_geometry_reset()
    var out = _drive(_int_batches(sizes), _WORKERS)
    _assert_tiled_fork(label)
    _assert_ints_match(label, out, total)


# =============================================================================
# R4/R5 -- the controls: shapes the tiling rule declines MUST stay serial
# =============================================================================


def test_r4_one_column_under_the_tiling_floor_stays_serial() raises:
    """Under `_TILE_ENTRY_MIN_ROWS` the tiling rule declines, and one column
    on the one-task-per-column fan is a single task -- so it stays serial.
    Also proves `calls == 0` is reachable through this harness."""
    var label = String("R4 one column under the floor")
    var sizes: List[Int] = [3000, 1, 0, 2048, 777]
    var total = _total(sizes)
    assert_true(total >= 1024, label + ": must clear the 1024-row floor")
    assert_true(total < _TILE_ENTRY_MIN_ROWS, label + ": must sit under it")
    grain_geometry_reset()
    var out = _drive(_string_batches(sizes, False), _WORKERS)
    _assert_stayed_serial(label)
    _assert_strings_match(label, out, total, False)


def test_r5_one_column_on_a_one_worker_pool_stays_serial() raises:
    """The R1 fixture on ONE worker: nothing to fan across, so the tiling rule
    declines and the concat must not dispatch a single-task fork."""
    var label = String("R5 one column, one worker")
    var sizes = _ragged_sizes(160_000)
    var total = _total(sizes)
    grain_geometry_reset()
    var out = _drive(_string_batches(sizes, False), 1)
    _assert_stayed_serial(label)
    _assert_strings_match(label, out, total, False)


# =============================================================================
# R6 -- destroy-recreate: the same fork across fresh pools
# =============================================================================


def test_r6_destroy_recreate_pool_soak() raises:
    var sizes = _ragged_sizes(140_000)
    var total = _total(sizes)
    _assert_non_vacuous(String("R6 soak"), total)
    for it in range(3):
        var label = String("R6 soak iteration ") + String(it)
        grain_geometry_reset()
        var out = _drive(_string_batches(sizes, it % 2 == 1), _WORKERS)
        _assert_tiled_fork(label)
        _assert_strings_match(label, out, total, it % 2 == 1)


# =============================================================================
# R7 -- STRING tile bounds are BYTE-balanced, not ROW-balanced
# =============================================================================
#
# The concat's wall is its LARGEST tile. On cbq05 the 20 equal-ROW string tiles
# carried 32.7..151.1 MB of payload-plus-offsets against a 56.8 MB mean, and the
# fork ran at occupancy 0.49-0.63. `string_tile_row_bounds` cuts by COST
# (payload bytes + 4 B/row). The oracle below is computed from the generator
# alone -- no concat code -- and the bound is ONE ROW: a tile cannot split a
# row, so each tile may exceed `ceil(total_cost / tiles)` by at most the
# costliest single row. The non-vacuity half asserts the SAME fixture cut into
# equal row ranges VIOLATES that bound, so this leg can tell the two apart.


def _tile_costs(imm bounds: List[Int], imm cost_prefix: List[Int]) -> List[Int]:
    var out = List[Int]()
    for t in range(len(bounds) - 1):
        out.append(cost_prefix[bounds[t + 1]] - cost_prefix[bounds[t]])
    return out^


def _check_bounds_for(tiles: Int) raises:
    var label = String("R7 byte-balanced bounds, tiles=") + String(tiles)
    var sizes = _ragged_sizes(160_000)
    var n = len(sizes)
    var batches = _string_batches(sizes, False)
    var slab = Slab[Optional[RecordBatch]].create(n)
    for m in range(n):
        var b = batches.take_slot_unchecked(m)
        slab.append(Optional[RecordBatch](b^))
    batches.set_len_unchecked(0)

    # The per-batch prefixes and the per-row cost prefix, from the GENERATOR.
    var row_off = List[Int]()
    var byte_prefix = List[Int]()
    var cost_prefix: List[Int] = [0]
    var r = 0
    var bytes = 0
    var max_row_cost = 0
    for m in range(n):
        row_off.append(r)
        byte_prefix.append(bytes)
        for _j in range(sizes[m]):
            var blen = _phrase(r).byte_length()
            bytes += blen
            var rc = blen + STRING_TILE_ROW_COST_BYTES
            if rc > max_row_cost:
                max_row_cost = rc
            cost_prefix.append(cost_prefix[len(cost_prefix) - 1] + rc)
            r += 1
    byte_prefix.append(bytes)
    var total = r
    var total_cost = cost_prefix[total]
    var allowed = (total_cost + tiles - 1) // tiles + max_row_cost

    var bounds = string_tile_row_bounds(
        slab, n, 0, row_off, byte_prefix, total, tiles
    )
    assert_equal(len(bounds), tiles + 1, label + ": bound count")
    assert_equal(bounds[0], 0, label + ": first bound")
    assert_equal(bounds[tiles], total, label + ": last bound")
    for t in range(tiles):
        if bounds[t + 1] < bounds[t]:
            raise Error(label + ": bounds go BACKWARDS at tile " + String(t))
    var costs = _tile_costs(bounds, cost_prefix)
    for t in range(tiles):
        if costs[t] > allowed:
            raise Error(
                label + ": tile " + String(t) + " rows ["
                + String(bounds[t]) + ", " + String(bounds[t + 1])
                + ") carries " + String(costs[t]) + " cost bytes; the"
                " balanced bound is " + String(allowed) + " (ceil(total/"
                "tiles) + one row). An equal-ROW cut does this."
            )

    # NON-VACUITY: the same fixture, cut into equal ROW ranges, must break it.
    var eq = List[Int]()
    for t in range(tiles + 1):
        eq.append((t * total) // tiles)
    var eq_costs = _tile_costs(eq, cost_prefix)
    var eq_worst = 0
    for t in range(tiles):
        if eq_costs[t] > eq_worst:
            eq_worst = eq_costs[t]
    assert_true(
        eq_worst > allowed,
        label + ": FIXTURE NOT SKEWED ENOUGH -- equal-row tiles already meet"
        " the balanced bound (worst " + String(eq_worst) + " <= "
        + String(allowed) + "), so this leg cannot tell the two cuts apart.",
    )


def test_r7_string_tile_bounds_are_byte_balanced() raises:
    _check_bounds_for(4)
    _check_bounds_for(3)
    _check_bounds_for(20)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
