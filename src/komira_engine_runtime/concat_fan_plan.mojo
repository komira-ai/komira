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
# THE CONCAT'S FAN: sized by BYTES and the POOL, not by the column count
# =============================================================================
#
# Columns are cut into `(col, row_range)` tiles, and the number of tiles is
# derived from `parallel_copy_tiles`: the widest unit's byte volume and the
# pool's `worker_count()`. The column count is a property of the schema and has
# no relationship to either, so it does not size the fan. BOOL and DICTIONARY
# columns never reach the tiled route (serial pairwise fallback).
#
# STRING / BINARY columns are split too. A concat lays its input batches end to
# end, so a tile's destination byte cursor is a per-batch prefix sum plus three
# Int32 loads per (tile, batch) pair: O(tiles * batches), never per row. The
# derivation is in `komira_arrow/streaming_concat.mojo`
# `_concat_string_column_into_range`; `ConcatOptions.string_tiling` switches it.
# A string column is priced by its payload bytes (`_string_col_total_bytes`),
# so a wide string column gets a proportionally wide fan.
#
# The tiled route is reachable only when `_concat_route_plan` admits the call
# as parallel (`not plan.serial`). `_TILE_ENTRY_MIN_ROWS` is the row floor for
# that admission. A one-column concat is admitted only onto the tiled fan, and
# only outside a live pool dispatch.
#
# The tiled route declines whenever a column is neither STRING/BINARY nor
# fixed-width (DATE32, TIMESTAMP, DECIMAL128, LIST have no width in the
# `_arrow_type_byte_width` table); the one-task-per-column path then runs and
# rejects such a column exactly as it always has, instead of the tiler
# producing a wrong answer.

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
    # never reach here — they set `any_untiled_type`, which returned above),
    # so this subtraction is exact rather than an estimate.
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

    It declines under a live pool dispatch: a one-column concat reached from
    inside a pool task runs serially, because a fork from there would raise
    "nested dispatch detected". The multi-column path has no such guard.

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
