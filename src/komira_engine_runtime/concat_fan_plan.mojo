# =============================================================================
# concat_fan_plan: the parallel concat's route and fan, decided in one place.
# =============================================================================
#
# `_concat_route_plan` decides whether a concat stays on the driver
# (`_concat_serial`), runs one task per output column (`_ConcatColumnsTask`),
# or runs the row-range tiled fan (`_concat_tiled`), and how many tiles. The
# fan is sized from the bytes moved and the pool's worker count
# (`fan_out_grain.parallel_copy_tiles`), never from the column count. It is a
# dispatch-time decision: the inputs are the batches in hand and
# `dispatcher.worker_count()`, so the same batches on the same pool always take
# the same route.
#
# `_take_slab` is the one safe move-out of a state's slab slot, shared by the
# column, tiled and release paths. `_on_pool_dispatch_active` reports a live
# pool dispatch in this process (a concat called from inside a pool task stays
# serial rather than nesting a dispatch).
# =============================================================================

from std.collections.optional import Optional
from std.builtin.swap import swap
from komira_arrow.schema import RecordBatch
from komira_collections.slab import Slab
from komira_arrow.streaming_concat import _arrow_type_byte_width
from komira_engine_runtime.concat_options import ConcatOptions
from komira_engine_runtime.fan_out_grain import parallel_copy_tiles
from komira_async_api.fork_join_shared import fork_join_pool_depth

# =============================================================================
# Threshold knobs (compile-time, simple to tune)
# =============================================================================

comptime _MIN_ROWS_FOR_PARALLEL: Int = 1024
comptime _MIN_COLS_FOR_PARALLEL: Int = 2

# =============================================================================
# THE CONCAT'S FAN — sized by BYTES and the POOL, not by the column count
# (supersedes the opt-in PERF-CONCAT-ROWRANGE-PARTITION [W2b])
# =============================================================================
#
# ★ WHAT WAS WRONG. `_concat_impl` dispatched `num_cols` tasks. The column count
# is a property of the SCHEMA and has no relationship to the pool or to the bytes
# being moved, so the fan was whatever the query plan happened to produce.
# MEASURED on tpch-q21 (the benchmark host, W=22, `ConcatOptions.trace`), the three warm
# concats per rep:
#
#     batches   cols  fixed      rows      incumbent tasks   pool
#       2,782      5      4   1,828,911         5             22
#       1,787     10      7      75,871        10             22
#       5,861      2      2   6,001,215         2             22   <- 96 MB, 2 tasks
#
# The last one copies ~96 MB of INT64 with TWO of twenty-two workers. That is
# the same defect class as the four hand-typed fork grains this campaign has
# already closed, wearing a different face: a fan derived from a structurally
# unrelated quantity. The generic statement of the fix, and the other two sites
# in the class, are in `fan_out_grain.parallel_copy_tiles`.
#
# ★ WHAT SHIPS. Columns are cut into `(col, row_range)` tiles so the fan is
# derived from `parallel_copy_tiles`, i.e. from the widest unit's BYTE volume
# and the actual `worker_count()`. BOOL / DICTIONARY never reach here (serial
# pairwise fallback).
#
# ⚠ THIS PARAGRAPH USED TO END "STRING / BINARY columns stay whole-column (one
# task each): variable-width rows cannot write disjoint destination slices
# without a per-row byte-offset pre-pass." THAT WAS TRUE FOR A GATHER AND FALSE
# FOR A CONCAT, and it cost this site its largest task. LEVER A
# splits them too: a concat lays its input batches end to end, so a tile's
# destination byte cursor is a per-BATCH prefix sum plus THREE Int32 loads per
# (tile, batch) pair — O(tiles * batches), never per row — and BOTH prefix sums
# already existed in the code that called them impossible (`batch_row_offset`
# on the dispatch State; the two Int32 per batch that scan 1 of
# `_concat_string_columns_multi` reads and discards). The derivation is at
# `komira_arrow/streaming_concat.mojo._concat_string_column_into_range`
# and the kill switch is `ConcatOptions.string_tiling`.
#
# WHY IT MATTERED: on a (STRING, INT64) join side of 20M rows the string column
# is 1.12 GB and the fixed column 160 MB, so the fan was 19 tiles moving 8.4 MB
# each plus ONE task moving 1.12 GB. Occupancy 0.0751 = 1.5 of 20 workers is
# that picture and nothing else.
#
# ★ WHAT IS HELD, EXACTLY WHERE IT SHIPPED. `_TILE_ENTRY_MIN_ROWS` (131,072) is
# UNCHANGED, and the tiled route is now reachable ONLY from inside the
# already-parallel branch (`go_parallel`). NO INPUT THAT RUNS SERIAL TODAY
# BECOMES PARALLEL, at any row count, on any pool. Only the FAN of already-
# parallel work moves. ⚠ The opt-in path this replaces did NOT hold that
# invariant — its gate sat ABOVE the `go_parallel` check, so a single-column
# 6M-row concat (serial today, `num_cols >= 2` fails) would have started forking
# the moment the flag was set. That is fixed here, not preserved.
#
# ⚠ 2026-09-24: THE PARAGRAPH ABOVE IS THE RECORD, AND ITS LAST CASE WAS
# THEN OPENED DELIBERATELY. The one-column concat IS admitted now — as its own
# change with its own falsifier, not as the side effect this paragraph guarded
# against — and only onto the tiled fan (`_concat_route_plan`). `go_parallel`
# is no longer a variable; it is `not plan.serial`. What the paragraph protects
# still stands for every other shape.
#
# ⚠ AND THE OPT-IN PATH HAD A SECOND LATENT DEFECT, ALSO FIXED. It routed every
# `_arrow_type_byte_width == 0` column to the STRING helper. That helper is
# correct for STRING / BINARY and silently wrong for anything else with no
# fixed width in that (partial) table — DATE32, TIMESTAMP, DECIMAL128, LIST.
# The incumbent column-parallel path RAISES on those (`_concat_fixed_columns_multi`
# rejects width 0), so the flag would have converted a loud failure into a wrong
# answer. The tiled route now declines whenever any column is neither
# STRING/BINARY nor fixed-width, and the incumbent raises exactly as before.
#
# ★ WHAT THIS IS WORTH, RE-MEASURED ON THE TRUNK IT LANDS ON (, after
# the collect-coalescer + probe-tier landings took q21 from 174 to 103 ms). One
# binary, `ConcatOptions.tiling` off vs on, position-balanced paired rounds x 10
# reps (drop 4), exact permutation, bench mutex before every run:
#
#     cb20   -14.96 ms  -2.57%   15 of 15   p = 6.1e-05
#     q7      -3.90 ms  -4.77%   15 of 15   p = 6.1e-05
#     q21     -1.98 ms  -1.90%   13 of 21   p = 0.451   <- NOT SIGNIFICANT
#
# ⚠ q21 CANNOT ADJUDICATE THIS ANY MORE, AND THAT IS THE CELL, NOT THE LEVER.
# Its within-arm spread went from 1.6-2.1% (, where this measured
# -1.87%, 15 of 15, p = 6.1e-05) to 12.6-13.7%, and a KNOWN-ZERO control on the
# same binary reads 12.79% / 12.87% with the two arms BYTE-IDENTICAL (+0.09 ms,
# p = 0.678, 10 of 21). The box was verified idle. The point estimate is stable
# across three sessions (-1.87% / -1.46% / -1.90%); the resolution is not. Do
# not quote a q21 number under ~5 ms until that 12.8% is diagnosed.
#
# ⚠ AND THE COALESCER DID NOT CHANGE THIS LEVER'S REACH — which is exactly why
# the fan is sized in BYTES and not in batches. q21's big concat went from 5,861
# input batches to 146; the row count and the byte count are IDENTICAL, so
# `parallel_copy_tiles` returns the same 11 tiles / 22 tasks.
#
# ⛔ WHY THE "MEASURED FLAT, DEAD LEVER" VERDICT DOES NOT APPLY.
# That earlier A/B (best cell
# 1.033x) was ENGAGED-BUT-FLAT and concluded "the copy is DRAM-bandwidth-bound;
# 2-3 workers saturate". It was measured on an **i7-14700K** — dual-channel DDR5,
# ~20-25 GB/s of copy bandwidth PER CORE — where 2-3 tasks genuinely do saturate
# and there is nothing left for a wider fan to collect. The number of tasks it
# takes to saturate is `socket_bandwidth / per_core_bandwidth`, which is a
# property of the MACHINE: on the Broadwell server socket this engine ships
# against it is ~8, not ~3, because a core can keep only ~10 line-fill buffers
# outstanding (~7.5 GB/s) while the socket sustains ~55-60 GB/s. The old verdict
# was right for its box and does not transfer. It was also measured on q5/q3/j2,
# never on q21, with min-of-6 against a 1.15x gate rather than a paired
# permutation test.
comptime _TILE_ENTRY_MIN_ROWS: Int = 131_072


@fieldwise_init
struct _ConcatFanPlan(ImplicitlyCopyable, Movable):
    """The concat's route + fan, decided in ONE place.

    `serial == True` means the concat never leaves the driver (`_concat_serial`)
    — decided by `_concat_route_plan`, the ONLY producer that sets it.
    Otherwise `tiles == 1` means DECLINE the tiled route (the incumbent
    one-task-per-column dispatch runs byte-for-byte). `string_tiles` is
    meaningful only when `tiles > 1`.
    """
    var tiles: Int
    var string_tiles: Bool
    var serial: Bool


def _string_col_total_bytes(
    imm input_slab: Slab[Optional[RecordBatch]],
    num_batches: Int,
    col: Int,
) raises -> Int:
    """Total payload bytes STRING/BINARY column `col` contributes to the concat.

    O(num_batches): two Int32 loads per batch — the same pair
    `_string_batch_byte_prefix` reads, summed rather than accumulated. This is
    what makes a string column PRICEABLE by `parallel_copy_tiles`, whose whole
    contract is that a fan is sized by the bytes it moves; sizing a 1.12 GB
    string column by `total_rows * max_fixed_width` would price it at the
    INT64's 160 MB and fan it 7x too weakly.
    """
    var total = 0
    for i in range(num_batches):
        if not input_slab[i]:
            continue
        ref col_ref = input_slab[i].value().column_at(col)
        var rows = col_ref._length
        if rows == 0:
            continue
        if not col_ref._offsets:
            continue
        var off = col_ref._offset
        var v = col_ref._offsets.value().view_ro()
        var p = v._unsafe_ptr().bitcast[Scalar[DType.int32]]()
        total += Int((p + off + rows)[]) - Int((p + off)[])
    return total


def _concat_fan_plan(
    imm input_slab: Slab[Optional[RecordBatch]],
    num_batches: Int,
    num_cols: Int,
    schema_idx: Int,
    num_fixed: Int,
    max_fixed_width: Int,
    total_rows: Int,
    any_untiled_type: Bool,
    worker_count: Int,
    options: ConcatOptions,
) raises -> _ConcatFanPlan:
    """THE ROUTE AND THE FAN, as one expression. Called once per concat CALL.

    ⛔ THIS LIVES IN A LEAF ON PURPOSE — DO NOT INLINE IT BACK INTO
    `_concat_impl`. Adding control flow to `_concat_impl` deterministically
    SEGFAULTS the local (non-RBE) Mojo compile inside the SLP vectorizer, on
    exactly the three `no-remote` targets whose `MojoCompileExecutable` then ran on
    the host; RBE workers compile the same source fine, and `@no_inline` on the
    callee does not avoid it because the trigger is the extra control flow in
    `_concat_impl` itself. The recovery precedent and the crash log are written
    up at `komira_parquet/materialize_parquet_scan.mojo`. Hoisting the whole
    decision here NET-REMOVES branches from `_concat_impl` rather than adding
    any, which is the only safe direction.

    LEVER A is the `string_tiles` half. STRING/BINARY columns move
    from `n_unsplittable` to `n_splittable`, and `widest_unit_bytes` becomes the
    max over ALL splittable units — for a (STRING, INT64) join side that is the
    string PAYLOAD, not `total_rows * 8`.

    Returns:
        `_ConcatFanPlan(tiles, string_tiles)`. `tiles == 1` DECLINES the tiled
        route entirely and the caller keeps its incumbent fan byte-for-byte.
    """
    var plan = _ConcatFanPlan(1, False, False)
    if not options.tiling:
        return plan
    if any_untiled_type:
        # A column that is neither fixed-width nor STRING/BINARY. The incumbent
        # path RAISES on these; tiling must not convert that into an answer.
        return plan

    # Every remaining column is fixed-width or STRING/BINARY (BOOL/DICTIONARY
    # never reach here — they set `any_untiled_type`, which returned above;
    # Previously it was `any_slow` sending the whole batch serial), so
    # this subtraction is exact rather than an estimate.
    var num_string = num_cols - num_fixed
    var str_on = options.string_tiling and num_string > 0

    var n_splittable = num_fixed + (num_string if str_on else 0)
    var n_unsplittable = 0 if str_on else num_string
    if n_splittable < 1:
        # No splittable unit at all: nothing for a row-range fan to cut. Before
        # LEVER A this was spelled `num_fixed >= 1`, which declined an
        # all-STRING batch outright; with strings splittable the honest test is
        # whether ANY unit can be split.
        return plan

    var widest_unit_bytes = total_rows * max_fixed_width
    if str_on:
        for c in range(num_cols):
            var at = input_slab[schema_idx].value().column_at(c).arrow_type
            if _arrow_type_byte_width(at) == 0:
                var sb = _string_col_total_bytes(input_slab, num_batches, c)
                if sb > widest_unit_bytes:
                    widest_unit_bytes = sb

    var tiles = 1
    if options.force_tiles:
        # Byte-equivalence fixture only: pin 3 tiles so the cross-tile disjoint
        # writes and an uneven remainder are exercised on a small input the rule
        # itself would (correctly) decline. FORCE outranks the row/byte gates
        # but NOT the kill switch above it — so the guard's OFF arm cannot be
        # satisfied by clearing only one of the two.
        tiles = 3
    elif total_rows >= _TILE_ENTRY_MIN_ROWS:
        # ENTRY, HELD at the value it shipped at. Nothing has measured a tiled
        # concat below 131,072 rows and I4 says an unmeasured widening is a
        # regression risk, so the byte floor inside `parallel_copy_tiles` is a
        # SECOND gate below this one, never a replacement for it.
        tiles = parallel_copy_tiles(
            widest_unit_bytes, n_splittable, n_unsplittable, worker_count
        )

    plan = _ConcatFanPlan(tiles, str_on and tiles > 1, False)

    if options.trace:
        # Diagnostic (opt-in, one line per concat CALL): the shape, the bytes,
        # and the fan that shape produced. It exists because the previous A/B of
        # this path could not distinguish "engaged, no win" from "never
        # engaged", and because a task count is the only falsifier a fan change
        # can have. Zero cost when unset. `tasks` counts the kind-2 validity
        # item per splittable column, which `parallel_copy_tiles` does not
        # price — that omission predates LEVER A and is left visible here
        # rather than silently corrected in the policy.
        print(
            "[CONCAT-TRACE] num_batches=", num_batches,
            "num_cols=", num_cols, "num_fixed=", num_fixed,
            "num_string=", num_string,
            "total_rows=", total_rows, "max_w=", max_fixed_width,
            "widest_unit_bytes=", widest_unit_bytes,
            "workers=", worker_count,
            "incumbent_tasks=", num_cols,
            "string_tiles=", plan.string_tiles,
            "tiles=", tiles,
            "tasks=", (
                tiles * n_splittable + n_unsplittable + n_splittable
            ) if tiles > 1 else num_cols,
        )

    return plan


def _concat_route_plan(
    imm input_slab: Slab[Optional[RecordBatch]],
    num_batches: Int,
    num_cols: Int,
    schema_idx: Int,
    num_fixed: Int,
    max_fixed_width: Int,
    total_rows: Int,
    any_untiled_type: Bool,
    worker_count: Int,
    options: ConcatOptions,
) raises -> _ConcatFanPlan:
    """SERIAL vs PARALLEL, and then the fan — the whole admission, in a LEAF.

    Same reason `_concat_fan_plan` is a leaf: control flow added to
    `_concat_impl` segfaults the local Mojo compile in the SLP vectorizer, so
    the admission test lives here and `_concat_impl` reads one Bool.

    ★ THE ONE-COLUMN ADMISSION (2026-09-24,, cbq05). The
    gate used to be `num_cols >= 2 and total_rows >= 1024`, checked BEFORE the
    fan plan, so a one-column concat never reached the row-range TILED route —
    which has cut a single column across the pool since LEVER A.
    cbq05 (`count(DISTINCT search_phrase)`) collects exactly ONE STRING column,
    99,997,497 rows / 740 MB of payload, and that concat ran on the DRIVER for
    ~295 of a ~620 ms warm rep while twenty workers idled (the benchmark host diagnosis
    hold, 2026-09-24).

    What `num_cols >= 2` got RIGHT is kept: the incumbent one-task-per-COLUMN
    fan is a single task at one column — pure dispatch overhead. So a
    one-column concat is admitted ONLY when the tiling rule itself says the
    column is worth cutting (`tiles >= 2`: above `_TILE_ENTRY_MIN_ROWS`, above
    the byte floor, a pool of >= 2, no BOOL/DICTIONARY/untiled type, and the
    `ConcatOptions.tiling` kill switch ON). Every other one-column input stays
    `_concat_serial` byte-for-byte, and `ConcatOptions.tiling=False` restores the old
    route for ALL of them — it is this admission's kill switch too.

    ⚠ AND IT DECLINES UNDER A LIVE POOL DISPATCH. A one-column concat reached
    from inside a pool task (e.g. a `combine_partition`) ran serially before
    and worked; a fork from there would raise "nested dispatch detected". The
    multi-column path never had this guard and is left exactly as it was — the
    guard only keeps the NEW admission from converting a working call site into
    a raise.

    Multi-column inputs: unchanged. Same row floor, same `_concat_fan_plan`
    call with the same arguments, same result.
    """
    if total_rows < _MIN_ROWS_FOR_PARALLEL:
        return _ConcatFanPlan(1, False, True)
    var one_col = num_cols < _MIN_COLS_FOR_PARALLEL
    if one_col and _on_pool_dispatch_active():
        return _ConcatFanPlan(1, False, True)
    var plan = _concat_fan_plan(
        input_slab, num_batches, num_cols, schema_idx, num_fixed,
        max_fixed_width, total_rows, any_untiled_type, worker_count, options,
    )
    if one_col and plan.tiles < 2:
        # The tiling rule declined, so the only parallel fan left is ONE task.
        plan = _ConcatFanPlan(1, False, True)
    return plan


# =============================================================================
# _take_slab — the one safe move-out of a state's slab slot
# =============================================================================


def _take_slab[T: Movable & Deinitable](mut slot: Slab[T]) -> Slab[T]:
    """Move the slab out of `slot`, leaving an EMPTY (destructible) slab there.

    The safe spelling of "take the pointee and write a placeholder back": a
    `swap` against a fresh empty slab is a move-out the compiler checks, with no
    pointer to the slot and no window in which the slot holds a moved-from
    value. The driver calls it after the drain barrier, when no worker can still
    touch the slot.
    """
    var out = Slab[T]()
    swap(slot, out)
    return out^


# =============================================================================
# _on_pool_dispatch_active: is a pool dispatch live in this process?
# =============================================================================


@always_inline
def _on_pool_dispatch_active() -> Bool:
    """True while a `run_with_state` dispatch is in flight in this process,
    that is, when the caller is running inside a pool task. A concat called
    there stays on the calling task (serial arm) instead of nesting a
    dispatch. One relaxed atomic load of the process-global depth that the
    dispatcher maintains."""
    return fork_join_pool_depth() > Int64(0)
