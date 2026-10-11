# =============================================================================
# PERF-CRITICAL: Column-Parallel RecordBatch Concat (D-2 Fix #2 Path A)
# =============================================================================
# Regression if removed: D-2 finalize concat phase — single-threaded
#                        `_concat_morsels_into_one` runs ~67ms on 10.5M
#                        rows × 4 INT64 cols (median, M4 10-core),
#                        consuming ~18% of total D-2 wall time. Removing
#                        the column-parallel path returns the entire
#                        concat to the main thread (regression band: D-2
#                        ~50ms / +25%, A-2 / C-1 / C-2 proportional).
# Measured impact:       Per-column work is embarrassingly parallel (no
#                        cross-column dependencies). One thread per
#                        column on 4-col → 8-col fixtures yields
#                        4-8x column-concat speedup; the wall-time
#                        improvement is bounded by the slowest column
#                        (typically a STRING column when present).
# DuckDB equivalent:     DuckDB's pipelined hash join emits DataChunks
#                        directly without a per-pipeline barrier, so it
#                        does not pay this cost at all. We close the gap
#                        by parallelizing the barrier rather than removing
#                        it (Path A — see the Fix #2 design).
# Do NOT delete without: re-measuring the finalize concat on a multi-core
#                        host; `tests/test_concat_one_column_parallel.mojo`
#                        and `tests/test_concat_release_state.mojo` pin the
#                        routing and the input lifetimes.
# =============================================================================
#
# Strategy
# --------
# Path A of the D-2 finalize-concat parallelization plan: a stand-alone
# utility that takes the multi-batch output (`Slab[RecordBatch]`) from
# `ParquetCollectSink.finalize` (when `multi_batch_mode=True`) and the
# caller's dispatcher, and produces a single `RecordBatch`.
#
# ⚠ "ONE TASK PER OUTPUT COLUMN" IS NO LONGER THE FAN. It was, and
# the column count has no relationship to the pool or to the bytes moved — on
# q21 that dispatched TWO tasks onto twenty-two workers for a 96 MB copy. The
# fan now comes from `fan_out_grain.parallel_copy_tiles(bytes,
# splittable, unsplittable, workers)`; fixed-width columns are cut into
# `(col, row_range)` tiles and the whole-column dispatch is what the rule
# DECLINES to. See the "THE CONCAT'S FAN" block below for the measurement and
# for the two post-barrier serializations that had to be removed with it.
#
# A caller with no dispatcher in scope concatenates serially with the
# multi-way helpers in `komira_arrow.streaming_concat`.
#
# State / Task shape
# ------------------
# (`concat_tasks`):
#
#   * State: KeepAlive, owns ALL per-dispatch heap allocations
#     (input batches Slab, output Column slab, error flag, error msg)
#     via `OwnedPointer`. NO wildcard-origin fields, NO borrowed
#     pointer fields — the input batches are MOVED INTO the State
#     before dispatch, so the State owns them outright.
#   * Task: Segment, POD; each invocation receives its column index
#     via `task_id`. Per-task work: read `state.input_batches[*][col_idx]`
#     across the input slab, run the existing
#     `_concat_string_columns_multi` / `_concat_fixed_columns_multi`
#     helper for that column type, and write the resulting `Column`
#     into `state.columns[][col_idx]` via `__setitem__`.
#
# Thresholds (serial-fallback gates, before any dispatch attempt)
# ---------------------------------------------------------------
#   * total_rows < 1024        → serial. Below this, the dispatch
#                                semaphore + per-task wakeup dominates
#                                the column-concat cost.
#   * num_cols < 2             → serial UNLESS the row-range tiling rule
#                                cuts the one column (`tiles >= 2`). The
#                                one-task-per-COLUMN fan is one task at one
#                                column — pure overhead — so that fan is
#                                never used for it; the TILED fan is.
#                                (2026-09-24,, cbq05 —
#                                this bullet used to read "with one column
#                                there is no parallelism to extract", which
#                                was false from LEVER A on: a 100M-row
#                                search_phrase collect ran ~295 ms serial on
#                                the driver behind it. `_concat_route_plan`.)
#
# ⛔ TWO BULLETS THAT USED TO STAND HERE ARE RETIRED, AND BOTH WERE STILL BEING
# QUOTED AS LIVE ON 2026-09-16 — by a reader who then concluded this entry point
# serializes a narrow batch. It does not. They are recorded, not deleted:
#   * ~~`pool_ptr is null` → serial~~ — GONE: the dispatcher is a
#     reference, so there is no null-fallback arm left to take.
#   * ~~any column is BOOL or DICTIONARY → serial~~ — GONE at ``
# ("route `any_slow` PER COLUMN"). ONE dictionary column used to
#     cost the WHOLE batch every worker; each column now picks its own kernel in
#     `_ConcatColumnsTask.execute`, so the batch is ADMITTED and only that column
#     folds. What BOOL/DICTIONARY still do is set `any_untiled_type`, which
#     declines the row-range TILED route only — see `_concat_fan_plan`.
#
# ⚠ THESE THRESHOLDS WERE UNCHANGED BY THE FAN CHANGE, AND THAT WAS
# LOAD-BEARING THEN: they were checked FIRST, so the fan change could not make
# any serial input start forking. (The opt-in shape tested its own
# gate ABOVE these, which would have made a single-column multi-million-row
# concat parallel the moment its flag was set.)
#
# ★ 2026-09-24 CHANGED ONE OF THEM ON PURPOSE, AS ITS OWN MEASURED CHANGE — the
# thing the note refused to let happen as a SIDE EFFECT. A one-column
# concat is admitted to the TILED fan when the tiling rule cuts it; nothing else
# moves. Falsifier: `komira_engine_runtime/tests/test_concat_one_column_
# parallel.mojo` (routing via `grain_geometry`, plus an independent ordered +
# sorted value oracle, plus the stays-serial controls).
# =============================================================================
#
# FILES
# -----
# This module holds the public entry points, `_concat_impl` (the one-task-
# per-column route) and `_concat_serial`. The route and fan decision is
# `concat_fan_plan`; the dispatch states and tasks are `concat_tasks`; the
# tiled driver is `concat_tiled`; the pool-side input teardown is
# `concat_release`.
# =============================================================================

from komira_async.runtime.sched_trace import (
    SITE_CONCAT,
    PHASE_CONCAT_COLS_SETUP,
    PHASE_CONCAT_COLS_ASSEMBLE,
    sched_trace_enabled,
    sched_trace_fork_ns_now,
    sched_trace_add_serial_phase,
)
from std.time import perf_counter_ns
from std.collections.optional import Optional
from std.memory import UnsafePointer
from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import (
    Field,
    RecordBatch,
    RecordBatchBuilder,
    Schema,
    SchemaBuilder,
)
from komira_arrow.column import Column
from komira_collections.slab import Slab
from komira_arrow.streaming_concat import (
    _concat_fixed_columns_multi,
    _concat_string_columns_multi,
    _concat_slow_column_pairwise,
    _arrow_type_byte_width,
)
from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.local_dispatcher import LocalDispatcher
from komira_buffer.heap_region import HeapRegion
from komira_engine_runtime.concat_options import ConcatOptions
from komira_engine_runtime.grain_geometry import grain_geometry_record
from komira_engine_runtime.concat_dict_unify import (
    rewrap_unified_dict_columns,
    unify_string_dict_columns,
)
from komira_engine_runtime.concat_fan_plan import (
    _concat_route_plan,
    _on_pool_dispatch_active,
    _take_slab,
)
from komira_engine_runtime.concat_release import release_concat_inputs_parallel
from komira_engine_runtime.concat_tasks import (
    _ConcatColumnsState,
    _ConcatColumnsTask,
)
from komira_engine_runtime.concat_tiled import _concat_tiled

# =============================================================================
# concat_record_batches_column_parallel — public entry point
# =============================================================================


def concat_record_batches_column_parallel(
    var batches: Slab[RecordBatch],
    mut dispatcher: LocalDispatcher[NoopSink],
    var cancel_token: CancellationToken,
    options: ConcatOptions = ConcatOptions(),
) raises -> RecordBatch:
    """Concatenate `batches` into one `RecordBatch` on `dispatcher`'s pool.

    The result's schema is the first non-empty input batch's (the
    `_with_schema` variant stamps a caller-supplied schema instead).

    Route (`concat_fan_plan._concat_route_plan`), decided before any dispatch:
      * fewer than 1024 rows in total: serial, on the caller.
      * one column, and the tiling rule declines to cut it (below
        `_TILE_ENTRY_MIN_ROWS`, under the byte floor, a one-worker pool, a
        BOOL / DICTIONARY / untiled type, `ConcatOptions.tiling=False`, or
        inside a live pool dispatch): serial.
      * otherwise parallel: the row-range tiled fan when the rule cuts the
        columns into tiles (for example 20 tiles of one column on a 20-worker
        pool, 10 per column for two columns), else one task per column.
    BOOL and DICTIONARY columns do not make a batch serial: they decline the
    tiled route only, and on the per-column route only that column takes the
    pair-wise fold. STRING dictionaries are unified first
    (`concat_dict_unify`), so they reach the concat as INT32 codes.

    Args:
        batches: The batches in output order. Consumed; the slab and its
            batches are drained in place.
        dispatcher: The dispatcher whose pool runs the fan.
        cancel_token: Consumed by the dispatch.
        options: Route switches and traces (`ConcatOptions`); the defaults
            are the production route.

    Returns:
        One `RecordBatch` with the rows of every input batch in order. An
        empty slab gives an empty `RecordBatch()`.
    """
    return _concat_with_dict_unify(
        batches^, dispatcher, cancel_token^, Optional[Schema](None), options
    )


def concat_record_batches_column_parallel_with_schema(
    var batches: Slab[RecordBatch],
    mut dispatcher: LocalDispatcher[NoopSink],
    var cancel_token: CancellationToken,
    var schema: Schema,
    options: ConcatOptions = ConcatOptions(),
) raises -> RecordBatch:
    """`concat_record_batches_column_parallel` with an authoritative output
    schema: the result carries `schema` (field names, nullability, metadata)
    instead of the first input batch's.

    Args:
        batches: The batches in output order (consumed).
        dispatcher: The dispatcher whose pool runs the fan.
        cancel_token: Consumed by the dispatch.
        schema: Stamped on the result; its field count must equal the
            input batches' column count.
        options: As for `concat_record_batches_column_parallel`.

    Returns:
        One `RecordBatch` carrying `schema`.
    """
    return _concat_with_dict_unify(
        batches^, dispatcher, cancel_token^, Optional[Schema](schema^), options
    )


def _concat_with_dict_unify(
    var batches: Slab[RecordBatch],
    mut dispatcher: LocalDispatcher[NoopSink],
    var cancel_token: CancellationToken,
    var schema_opt: Optional[Schema],
    options: ConcatOptions,
) raises -> RecordBatch:
    """⭐ CD-SCAN (2026-09-25): unify every batch's STRING dictionary FIRST
    (`concat_dict_unify.unify_string_dict_columns`), so a dictionary column
    reaches `_concat_impl` as INT32 codes — all-fixed-width, so it TILES —
    instead of taking the O(N^2) single-task pair-wise fold; then re-label the
    concatenated codes as ONE DICTIONARY column. A batch set with no string
    dictionary (every caller before CD-SCAN) passes through untouched.

    ⛔ Deliberately a WRAPPER, not new control flow inside `_concat_impl`:
    that function's docstring records the SLP-vectorizer crash that added
    control flow there re-acquires."""
    var owned = batches^
    var plan = unify_string_dict_columns(
        owned, dispatcher, options.dict_unify, options.trace_dict_unify
    )
    var restore = not Bool(schema_opt)
    var out = _concat_impl(
        owned^, dispatcher, cancel_token^, schema_opt^, options
    )
    return rewrap_unified_dict_columns(out^, plan^, restore)


def _concat_impl(
    var batches: Slab[RecordBatch],
    mut dispatcher: LocalDispatcher[NoopSink],
    var cancel_token: CancellationToken,
    var schema_opt: Optional[Schema],
    options: ConcatOptions,
) raises -> RecordBatch:
    """Shared implementation for the two public entry points.

    Args:
        batches: Input slab (consumed).
        dispatcher: The dispatcher whose pool runs the fan.
        cancel_token: CancellationToken consumed by the dispatch.
        schema_opt: If Some, the result is stamped with this schema
            (authoritative). If None, the result is stamped with a
            schema derived from the input batches.
    """
    # TRACK-B POST-BARRIER BRACKET () for the WHOLE-COLUMN
    # column-parallel path (the tiled path brackets itself inside `_concat_tiled`).
    # Opened at entry; closed at the fork (SETUP) and at the return (ASSEMBLE).
    # The early-return / serial-fallback / tiled-route arms simply never close it,
    # so no record is emitted for a run that did not take this path.
    var _tb_on = sched_trace_enabled()
    var _tb_t0 = UInt64(0)
    var _tb_f0 = UInt64(0)
    if _tb_on:
        _tb_t0 = UInt64(perf_counter_ns())
        _tb_f0 = sched_trace_fork_ns_now()

    var owned_batches = batches^
    var num_batches = len(owned_batches)
    if num_batches == 0:
        _ = owned_batches^
        if schema_opt:
            var empty = RecordBatch()
            empty.schema = schema_opt.take()
            return empty^
        return RecordBatch()

    # Single-batch fast path. The multi-batch finalize drain may return
    # a single already-concatted RecordBatch (DICTIONARY fallback inside
    # `_drain_morsels_to_batches` calls `_concat_morsels_into_one`
    # internally and yields a 1-element list). In that case our concat
    # work is redundant — just lift the one batch out and return it.
    if num_batches == 1:
        var only = owned_batches.take_slot_unchecked(0)
        owned_batches.set_len_unchecked(0)
        _ = owned_batches^
        if schema_opt:
            only.schema = schema_opt.take()
        return only^

    # Find first non-empty batch (schema source) + tally totals.
    var schema_idx = -1
    var total_rows = 0
    for i in range(num_batches):
        ref b = owned_batches[i]
        var rows = b.num_rows()
        total_rows += rows
        if schema_idx < 0 and rows > 0 and b.num_columns() > 0:
            schema_idx = i

    if schema_idx < 0:
        _ = owned_batches^
        if schema_opt:
            var empty = RecordBatch()
            empty.schema = schema_opt.take()
            return empty^
        return RecordBatch()

    var num_cols = owned_batches[schema_idx].num_columns()

    # Type-check for BOOL / DICTIONARY (slow-path fallback) + count fixed-width
    # columns (row-range tiling candidates) + the WIDEST fixed width, which is
    # what prices the biggest task the incumbent fan produces. No early break —
    # the counts need the full column scan; `any_slow` is monotone so the result
    # is unchanged.
    #
    # `any_untiled_type` is a column that is NEITHER fixed-width NOR
    # STRING/BINARY — DATE32, TIMESTAMP, DECIMAL128, LIST, ... all of which
    # `_arrow_type_byte_width` reports as 0 because its table is partial. The
    # incumbent path RAISES on them (`_concat_fixed_columns_multi` rejects width
    # 0); the tiled path would hand them to the STRING helper and return a wrong
    # answer. So they decline tiling and the incumbent raises exactly as before.
    #
    # ★ BOOL/DICTIONARY NO LONGER SEND THE BATCH SERIAL (board
    # ). They used to set `any_slow`, which `go_parallel` tested,
    # so ONE dictionary column cost the batch every worker AND made the other
    # twenty columns pay an N^2 pair-wise memcpy. Each column picks its own
    # kernel now (`_ConcatColumnsTask.execute`), so the batch is admitted and
    # only the dictionary column itself folds.
    #
    # ⚠ THEY SET `any_untiled_type` INSTEAD, WHICH IS LOAD-BEARING, NOT
    # TIDYING. The TILED route has no BOOL/DICTIONARY arm and never needed
    # one, because `any_slow` used to keep those batches away from it
    # entirely. Its `num_string = num_cols - num_fixed` subtraction would
    # count a dictionary column as STRING and hand it to the string tiler ->
    # a wrong answer, not a raise. Declining to tile keeps that route's
    # inputs exactly what they have always been; the incumbent one-task-per-
    # column fan (which now has the slow arm) is what picks the batch up.
    var num_fixed = 0
    var max_fixed_width = 0
    var any_untiled_type = False
    for c in range(num_cols):
        var at = owned_batches[schema_idx].column_at(c).arrow_type
        if at == ArrowType.BOOL or at == ArrowType.DICTIONARY:
            any_untiled_type = True
        else:
            var w = _arrow_type_byte_width(at)
            if w > 0:
                num_fixed += 1
                if w > max_fixed_width:
                    max_fixed_width = w
            elif at != ArrowType.STRING and at != ArrowType.BINARY:
                any_untiled_type = True

    # Build the input staging Slab[Optional[RecordBatch]] (always —
    # both serial and parallel paths use this shape so they can share
    # the existing multi-way helpers without API divergence).
    var input_slab = Slab[Optional[RecordBatch]].create(num_batches)
    for i in range(num_batches):
        var b = owned_batches.take_slot_unchecked(i)
        input_slab.append(Optional[RecordBatch](b^))
    owned_batches.set_len_unchecked(0)
    _ = owned_batches^

    # ---- The ADMISSION and the FAN, decided in ONE leaf ----------------------
    # `_concat_route_plan` answers serial-vs-parallel AND, for a parallel
    # concat, the fan (`fan_out_grain.parallel_copy_tiles` via
    # `_concat_fan_plan`). DELIBERATELY NOT HERE: control flow added to this
    # function re-acquires the SLP-vectorizer crash `_concat_fan_plan`'s
    # docstring records, so the gate that used to be spelled inline
    # (`num_cols >= 2 and total_rows >= 1024`) is a Bool read now.
    #
    # ⚠ THE ONE-COLUMN ADMISSION (2026-09-24, cbq05). That inline gate sat
    # ABOVE the tiled route, so a one-column concat — 100M rows of
    # `search_phrase` on cbq05 — ran serially on the driver however large it
    # was. A one-column concat is now admitted exactly when the tiling rule
    # cuts it (`tiles >= 2`); every other one-column input, and every
    # multi-column input, takes the route it took before. See
    # `_concat_route_plan` for the held invariants.
    var worker_count = dispatcher.worker_count()
    var plan = _concat_route_plan(
        input_slab, num_batches, num_cols, schema_idx, num_fixed,
        max_fixed_width, total_rows, any_untiled_type, worker_count, options,
    )

    if plan.serial:
        # Serial fallback. Move the input Slab into a stack-rooted
        # buffer expected by the existing helpers, run the per-column
        # work serially, then return.
        return _concat_serial(input_slab^, num_batches, num_cols, schema_opt^)

    var tiles = plan.tiles

    if tiles > 1:
        return _concat_tiled(
            input_slab^, num_batches, num_cols, dispatcher,
            cancel_token^, schema_opt^, worker_count, tiles, plan.string_tiles,
            options,
        )

    # ---- Column-parallel dispatch ----
    # Pre-fill the output Slab[Column] with empty placeholders. Workers
    # `__setitem__` their disjoint slot — no growth across the dispatch.
    var out_columns = Slab[Column[HeapRegion]].create(num_cols)
    for _c in range(num_cols):
        out_columns.append(Column[HeapRegion]())

    # Capture per-column field metadata from the input schema BEFORE
    # the input slab is moved into State. Used to build the output
    # schema after dispatch (no-schema entry only — the schema-aware
    # entry stamps `schema_opt.take()` on the result instead).
    # AGG-SCHEMA-METADATA-PROPAGATION-V0.4: cache as
    # full Field clones (via `field_at`) so Phase B/C metadata (_tz,
    # decimal (p,s), _dict_index_type, _union_type_ids, _flags,
    # kv-metadata) propagates into the output schema.
    var captured_fields = List[Field]()
    if not schema_opt:
        ref input_schema = input_slab[schema_idx].value().schema
        for c in range(num_cols):
            captured_fields.append(input_schema.field_at(c))

    # PARALLELIZE-BOUNDARY: per-column RecordBatch concat, one task
    # per output column.
    # Disjointness: task `col_idx` reads `state.input_batches[][*]
    #   [col_idx]` (one column index across all input batches) and
    #   writes only `state.columns[][col_idx]` (Slab __setitem__;
    #   pre-sized, no growth). Different col_idx values touch
    #   disjoint Column slots on output and disjoint Column slices on
    #   input.
    # Liveness: State owns BOTH the input slab and the output column
    #   slab via OwnedPointer. The State itself is held alive by the
    #   driver's `var state` slot for the duration of `run_with_state`.
    #   The `run_with_state` drain barrier (dispatch_semaphore_wait on
    #   exit) rejoins every worker before this function returns.
    # No-realloc: `out_columns` sized at the pre-dispatch loop above.
    #   Workers __setitem__ live slots only. The input slab is read-
    #   only across the dispatch window (the helpers only read; the
    #   dispatch barrier completes before any caller touches the slab
    #   again).
    # PERF-CRITICAL: Path A column-parallel concat (D-2 Fix #2).
    var state = _ConcatColumnsState(input_slab^, out_columns^)
    var task = _ConcatColumnsTask(Int32(0))
    if _tb_on:
        sched_trace_add_serial_phase(
            PHASE_CONCAT_COLS_SETUP,
            UInt64(perf_counter_ns()) - _tb_t0,
            sched_trace_fork_ns_now() - _tb_f0,
        )
    # CLONED BEFORE THE DISPATCH CONSUMES IT. The input-teardown wave below
    # needs a token and `cancel_token` is moved into `run_with_state` on the
    # next statement, so the clone has to be taken here rather than there.
    var release_token = cancel_token.clone()
    # THE INCUMBENT FAN, RECORDED. Before this line the `num_cols` dispatch wrote
    # NO geometry, so a census could see the tiled fan and not the one it is
    # supposed to be compared against — i.e. the instrument could not observe the
    # defect. `morsels` is 1 (one whole-column unit per task) and `workers` is
    # the task count the fork gets, which for this path IS the column count.
    grain_geometry_record(
        SITE_CONCAT, total_rows, total_rows, 1,
        min(num_cols, dispatcher.worker_count()),
        options.trace_geometry,
    )
    # cancel_token is consumed here.
    _ = dispatcher.run_with_state[
        _ConcatColumnsState, _ConcatColumnsTask
    ](state, task^, num_cols, cancel_token^, site_id=SITE_CONCAT)
    if _tb_on:
        _tb_t0 = UInt64(perf_counter_ns())
        _tb_f0 = sched_trace_fork_ns_now()

    # Drain barrier rejoined. Read the error channel, then swap the
    # Slab[Column] out of the OwnedPointer's heap slot with `_take_slab`.
    var raised = state.err_flag[].load() != Int8(0)
    var raised_msg = String("")
    if raised:
        raised_msg = String(state.err_msg[])

    # `state.columns` is a live OwnedPointer holding the populated
    # Slab[Column]; `_take_slab` swaps it for an empty slab, so the slot is
    # destructible when state^ drops at scope exit.
    var done_columns = _take_slab(state.columns[])

    # `state.input_batches` is a live OwnedPointer holding the populated
    # Slab[Optional[RecordBatch]] that the workers read from during dispatch.
    # After the drain barrier the workers are fully joined; no thread reads
    # from this slab anymore, so it is safe to swap it out with `_take_slab`
    # (an empty placeholder stays behind) and let the local `_drain_input` Slab drop
    # at scope exit (its destructor calls Optional[RecordBatch]
    # destructors on each remaining slot — same effect as letting the
    # State's auto-drop run, just sequenced explicitly here so the
    # output `done_columns` and the drained input land in deterministic
    # frame-local slots before state^ runs).
    var _drain_input = _take_slab(state.input_batches[])
    # THE TEARDOWN WAVE (site 49). Previously `_ = _drain_input^`: N
    # RecordBatch destructors on the DRIVER with every worker already rejoined
    # and parked -- measured at 14.4 ms/rep NAMED destruction under this
    # subtree on q21. `release_concat_inputs_parallel` hands each worker a
    # stride-slice of the batches so the `free()` storm lands on the pool. It
    # declines to the byte-for-byte previous drop below 2 batches or at
    # `--workers 1`, which is the arm the value oracle runs.
    if raised or _on_pool_dispatch_active():
        # TWO REASONS TO DECLINE, both of which must drop serially.
        #
        # ⚠ THERE WERE THREE. `not concat_release_on()` -- the
        # concat-release kill-switch -- was DELETED 2026-09-08 under
        # the maintainer directive, on the retirement condition its own
        # docstring named: *"delete this ... AFTER the A/B is recorded"*. It is
        # recorded and resolved (q21 -17.33 ms / -5.20%, p = 3.24e-05). The serial arm
        # below is STILL REACHED by the two surviving terms and by
        # `release_concat_inputs_parallel`'s own structural decline (< 2 batches,
        # `--workers 1`), so the deletion removed the probe and stranded nothing.
        #
        # `raised`: the concat dispatch above already failed, which for a
        # cancellation means THIS token is cancelled too -- so a teardown
        # dispatch would raise a SECOND error and `release_concat_inputs_
        # parallel` would propagate it, MASKING the original failure with a
        # cancellation. The original error is the one the caller needs.
        #
        # `_on_pool_dispatch_active()`: a live pool dispatch would make
        # `run_with_state` re-enter the dispatcher. Same guard
        # `hash_agg_untyped_sink` uses before `release_radix_srcs_parallel`.
        _ = release_token^
        _ = _drain_input^
    else:
        release_concat_inputs_parallel(
            _drain_input^, total_rows, dispatcher, release_token^,
        )

    _ = state^  # Auto-drops the OwnedPointers (heap allocs).

    if raised:
        _ = done_columns^
        raise Error("concat_record_batches_column_parallel: " + raised_msg)

    # Assemble the output RecordBatch.
    var owned_cols = done_columns^
    var builder = RecordBatchBuilder.with_capacity(num_cols)
    for i in range(num_cols):
        var col = owned_cols.take_slot_unchecked(i)
        builder.add_column(col^)
    owned_cols.set_len_unchecked(0)
    _ = owned_cols^

    if _tb_on:
        sched_trace_add_serial_phase(
            PHASE_CONCAT_COLS_ASSEMBLE,
            UInt64(perf_counter_ns()) - _tb_t0,
            sched_trace_fork_ns_now() - _tb_f0,
        )

    if schema_opt:
        return builder.build(schema_opt.take())

    # Build the output schema from the captured Field clones.
    var sb = SchemaBuilder()
    for c in range(num_cols):
        sb.add_field(captured_fields[c].copy())
    return builder.build(sb.build())


# =============================================================================
# _concat_serial — serial fallback (used by both entry points)
# =============================================================================


def _concat_serial(
    var input_slab: Slab[Optional[RecordBatch]],
    num_batches: Int,
    num_cols: Int,
    var schema_opt: Optional[Schema],
) raises -> RecordBatch:
    """Serial concat fallback. Runs the multi-way per-column helpers
    in a single-threaded for-loop. Used when `_concat_route_plan` says
    `serial`: under the row floor, or a single column the row-range
    tiling rule declines to cut. (The null-pool and BOOL/DICT arms this
    line used to list are gone — see the module header.)
    """
    var owned_input = input_slab^

    # Find first non-empty batch.
    var schema_idx = -1
    for i in range(num_batches):
        if owned_input[i]:
            schema_idx = i
            break
    if schema_idx < 0:
        _ = owned_input^
        if schema_opt:
            var empty = RecordBatch()
            empty.schema = schema_opt.take()
            return empty^
        return RecordBatch()

    # Acquire a typed pointer into the slab's interior to feed the
    # existing helpers (which take `UnsafePointer[Optional[RecordBatch],
    # o]`).
    # SAFETY: `owned_input` is a stack-rooted Slab; its interior buffer
    # is alive for the function body. `get_mut_interior(0)` produces a
    # ref to slot 0; UnsafePointer(to=ref) lifts the ref to a pointer
    # rooted at the slab's storage. Used only for the in-function
    # helper calls below — the pointer never escapes.
    ref slot0 = owned_input.get_mut_interior(0)
    var staging_ptr = UnsafePointer(to=slot0)

    # Build per-column results, then assemble.
    #
    # ★ PER COLUMN, NOT PER BATCH. This used
    # to test a whole-batch `any_slow` and send EVERY column to
    # `_concat_variable_width_batches_pairwise` if any one of them was BOOL or
    # DICTIONARY. This is the SERIAL fallback, so no parallelism is at stake
    # here -- what is at stake is the other twenty columns' N^2 pair-wise
    # memcpy, which is why the routing has to be fixed here too and not only
    # on the admitted path.
    var sb = SchemaBuilder()
    for c in range(num_cols):
        # AGG-SCHEMA-METADATA-PROPAGATION-V0.4: preserve metadata.
        sb.add_field(owned_input[schema_idx].value().schema.field_at(c))

    var builder = RecordBatchBuilder.with_capacity(num_cols)
    for c in range(num_cols):
        var at = owned_input[schema_idx].value().column_at(c).arrow_type
        if at == ArrowType.BOOL or at == ArrowType.DICTIONARY:
            builder.add_column(
                _concat_slow_column_pairwise(staging_ptr, num_batches, c)
            )
        elif at == ArrowType.STRING or at == ArrowType.BINARY:
            builder.add_column(_concat_string_columns_multi(staging_ptr, num_batches, c))
        else:
            builder.add_column(_concat_fixed_columns_multi(staging_ptr, num_batches, c, at))
    var out_batch = builder.build(sb.build())

    # The helpers `take()` populated slots when they consume them;
    # any still-populated slots get dropped via Slab's destructor.
    _ = owned_input^

    if schema_opt:
        out_batch.schema = schema_opt.take()
    return out_batch^
