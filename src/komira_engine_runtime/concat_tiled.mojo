# =============================================================================
# concat_tiled: the row-range tiled concat driver (`_concat_tiled`).
# =============================================================================
#
# Cuts every column into `(column, row range)` tiles so a concat of few, long
# columns still spreads across the pool. Fixed-width tiles copy a disjoint
# row range of the destination; STRING / BINARY tiles find their destination
# byte cursor from a per-batch prefix sum (`string_tile_row_bounds`,
# `_string_batch_byte_prefix`), so no per-row pre-pass is needed. The route
# and the tile count come from `concat_fan_plan`; the states and tasks from
# `concat_tasks`; the inputs are released on the pool by `concat_release`.
# =============================================================================

from komira_async.runtime.sched_trace import (
    SITE_CONCAT,
    PHASE_CONCAT_TILED_SETUP,
    PHASE_CONCAT_TILED_ASSEMBLE,
    sched_trace_enabled,
    sched_trace_fork_ns_now,
    sched_trace_add_serial_phase,
)
from std.time import perf_counter_ns
from std.collections.optional import Optional
from std.math import max
from std.memory import UnsafePointer
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
    _string_batch_byte_prefix,
    _arrow_type_byte_width,
)
from komira_arrow.offset_overflow import check_emittable_int32_offsets
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_arrow.bitmap import Bitmap
from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.local_dispatcher import LocalDispatcher
from komira_buffer.heap_region import HeapRegion
from komira_engine_runtime.concat_options import ConcatOptions
from komira_engine_runtime.grain_geometry import grain_geometry_record
from komira_engine_runtime.concat_string_tile_bounds import string_tile_row_bounds
from komira_engine_runtime.concat_fan_plan import (
    _on_pool_dispatch_active,
    _take_slab,
)
from komira_engine_runtime.concat_release import release_concat_inputs_parallel
from komira_engine_runtime.concat_tasks import (
    _ConcatTiledState,
    _ConcatTiledTask,
    _ConcatWork,
)

def _concat_tiled(
    var input_slab: Slab[Optional[RecordBatch]],
    num_batches: Int,
    num_cols: Int,
    mut dispatcher: LocalDispatcher[NoopSink],
    var cancel_token: CancellationToken,
    var schema_opt: Optional[Schema],
    worker_count: Int,
    tiles_in: Int,
    string_tiles: Bool,
    options: ConcatOptions,
) raises -> RecordBatch:
    """Row-range TILED concat — the fan sized by `parallel_copy_tiles`.

    Columns are split into `(col, row_range)` tiles so the fan is derived from
    the bytes moved and the pool width rather than from the column count.
    BYTE-IDENTICAL to the column-parallel / serial concat, and by CONSTRUCTION
    rather than by inspection: fixed-width tiles + validity + null count route
    through the SAME `_concat_fixed_column_into_range` / `_build_fixed_validity`
    / `_sum_fixed_null_count` helpers the whole-column
    `_concat_fixed_columns_multi` uses, and a STRING/BINARY tile routes through
    `_concat_string_column_into_range`, which is `_concat_string_columns_multi`'s
    own scan-2 arithmetic restricted to a row window.

    Args:
        tiles_in: Tiles per splittable column, DECIDED BY THE CALLER (which is
            also where the admission test lives — `tiles_in >= 2` IS that test,
            so this function cannot be entered on a declined shape). Passing it
            in rather than recomputing it here keeps the route decision and the
            fan a single expression.
        string_tiles: When True, STRING/BINARY columns are ALSO cut into
            row-range tiles (kind 3 + the kind-2 validity item). When False
            they take the whole-column kind-1 route: the
            `ConcatOptions.string_tiling=False` arm and the differential
            oracle.

    Preconditions (enforced by the caller): num_batches >= 2, no BOOL/DICTIONARY
    column, every column either fixed-width or STRING/BINARY, at least one
    splittable column, and the concat already on its parallel branch.
    """
    var owned_input = input_slab^

    # SCHEDULER-TRACE BRACKETS. The site table's `inter_ns` charges a serial
    # window to the site of the PRECEDING fork, so these two brackets say which
    # code the window is: SETUP is entry -> fork (buffer pre-alloc + work-item
    # build, which lands in the PREVIOUS site's inter-gap because it precedes
    # concat's own fork) and ASSEMBLE is barrier -> return (the serial
    # per-column wrap and RecordBatch build, which lands in SITE_CONCAT's own
    # inter-gap). Zero cost when tracing is off: one cached Bool branch, no
    # external_call.
    var _tb_on = sched_trace_enabled()
    var _tb_t0 = UInt64(0)
    var _tb_f0 = UInt64(0)
    if _tb_on:
        _tb_t0 = UInt64(perf_counter_ns())
        _tb_f0 = sched_trace_fork_ns_now()

    # Schema source + per-batch output row offsets (prefix sum) + total rows.
    var schema_idx = -1
    var batch_row_offset = List[Int](capacity=num_batches)
    var total_rows = 0
    for i in range(num_batches):
        batch_row_offset.append(total_rows)
        if owned_input[i]:
            var rows = owned_input[i].value().num_rows()
            total_rows += rows
            if (
                schema_idx < 0
                and rows > 0
                and owned_input[i].value().num_columns() > 0
            ):
                schema_idx = i

    if schema_idx < 0:
        _ = owned_input^
        _ = cancel_token^
        if schema_opt:
            var empty = RecordBatch()
            empty.schema = schema_opt.take()
            return empty^
        return RecordBatch()

    # Per-column width (0 → STRING/BINARY, whole-column) + fixed count +
    # captured output fields (no-schema entry only).
    var col_width = List[Int](capacity=num_cols)
    var num_fixed = 0
    for c in range(num_cols):
        var at = owned_input[schema_idx].value().column_at(c).arrow_type
        var w = _arrow_type_byte_width(at)
        col_width.append(w)
        if w > 0:
            num_fixed += 1

    var captured_fields = List[Field]()
    if not schema_opt:
        ref input_schema = owned_input[schema_idx].value().schema
        for c in range(num_cols):
            captured_fields.append(input_schema.field_at(c))

    # -- Tiles per fixed-width column ---------------------------------------
    # DECIDED BY THE CALLER (`parallel_copy_tiles`, or 3 under the byte-equiv
    # FORCE fixture). Clamped here only against a `total_rows` smaller than the
    # tile count, which the FORCE fixture can produce and the rule cannot.
    var tiles = tiles_in
    if tiles > total_rows:
        tiles = total_rows if total_rows > 0 else 1
    if tiles < 1:
        tiles = 1

    # -- Build work items + pre-alloc destination buffers -------------------
    # SAFETY: `owned_input` is a stack-rooted Slab live for this function body;
    # `get_mut_interior(0)` produces a ref to slot 0 and `UnsafePointer(to=ref)`
    # lifts it to a pointer rooted at the slab's storage. Used ONLY for the
    # driver-side `_string_batch_byte_prefix` scans below (read-only) and never
    # escapes — the workers get their own pointer from the State.
    ref setup_slot0 = owned_input.get_mut_interior(0)
    var setup_ptr = UnsafePointer(to=setup_slot0)

    var fixed_bufs = Slab[OwnedAlignedBuffer].create(num_cols)
    var str_off_bufs = Slab[OwnedAlignedBuffer].create(num_cols)
    var out_columns = Slab[Column[HeapRegion]].create(num_cols)
    var out_validity = Slab[Optional[Bitmap[HeapRegion]]].create(num_cols)
    var out_nulls = Slab[Int].create(num_cols)
    var work_items = List[_ConcatWork]()
    var str_byte_prefix = List[List[Int]]()
    # Only the kind-3 route cuts at byte-balanced bounds.
    var string_bytebal = string_tiles and options.string_bytebal
    for c in range(num_cols):
        out_columns.append(Column[HeapRegion]())
        out_validity.append(Optional[Bitmap[HeapRegion]](None))
        out_nulls.append(0)
        var w = col_width[c]
        if w == 0 and not string_tiles:
            # STRING/BINARY, WHOLE-COLUMN ROUTE (`ConcatOptions.string_tiling=False`).
            # Length-0 placeholders and one kind-1 task that builds the entire
            # Column itself.
            var ph = OwnedAlignedBuffer(1)
            ph.set_length(0)
            fixed_bufs.append(ph^)
            var ph_off = OwnedAlignedBuffer(1)
            ph_off.set_length(0)
            str_off_bufs.append(ph_off^)
            str_byte_prefix.append(List[Int]())
            work_items.append(_ConcatWork(Int32(c), UInt8(1), 0, 0))
        elif w == 0:
            # STRING/BINARY ROW-RANGE TILES. The per-batch byte prefix is
            # O(num_batches) — two Int32 loads per batch — and its last entry
            # is the column's total payload size, which is what sizes the
            # destination. `OwnedAlignedBuffer` does NOT zero-fill, so the
            # payload pages are first-touched by the TILES, in parallel.
            var prefix = _string_batch_byte_prefix(setup_ptr, num_batches, c)
            var total_bytes = prefix[num_batches]
            # THE TILE BOUNDS ARE BYTE-BALANCED. Equal ROW ranges are equal
            # work for a fixed-width column and NOT for this one: a tile moves
            # its rows' payload plus 4 B of offset per row, and payload length
            # is data. `string_tile_row_bounds` cuts by that cost instead; the
            # tiles still PARTITION [0, total_rows), which is all the
            # disjointness contract below rests on.
            # `ConcatOptions.string_bytebal=False` selects the equal-row cut.
            var sbounds = List[Int]()
            if string_bytebal:
                sbounds = string_tile_row_bounds(
                    owned_input, num_batches, c, batch_row_offset, prefix,
                    total_rows, tiles,
                )
            # ⛔ THE INT32 OFFSET CEILING, ON THE ONE PATH THAT DOES NOT GO
            # THROUGH `_concat_string_columns_multi`. The tiles write their
            # offsets as `Int32(byte_cursor - data_start) + src_off[...]` into
            # the `obuf` sized just below; past INT32_MAX that narrowing wraps
            # NEGATIVE and silently, leaving an exactly-correct row count over
            # unaddressable rows. `prefix[num_batches]` is the whole column's
            # 64-bit byte total and is already in hand, so the check is one
            # `Int` comparison — and it must stand HERE, before `dbuf`, because
            # the guard's contract is to fail before >2 GiB of RSS is
            # committed and before any tile is dispatched. A tile cannot raise
            # usefully: inside the fork a raise is a per-worker error flag, not
            # a refusal, and by then the destination exists.
            check_emittable_int32_offsets(
                "streaming concat(n-way, row-range tiled)",
                total_bytes,
                total_rows,
                promote_at=options.offset_promote_at,
            )
            var dbuf = OwnedAlignedBuffer(max(total_bytes, 1))
            dbuf.set_length(Int64(total_bytes))
            fixed_bufs.append(dbuf^)

            var off_bytes = (total_rows + 1) * 4
            var obuf = OwnedAlignedBuffer(max(off_bytes, 1))
            obuf.set_length(Int64(off_bytes))
            # `out_off[0] = 0` IS THE DRIVER'S, NOT ANY TILE'S. Tile [rs, re)
            # owns offset slots [rs+1, re], so the ranges partition
            # [1, total_rows] and slot 0 is owned by nobody. Writing it here
            # keeps that partition exact instead of special-casing tile 0.
            var obuf_view = obuf.view_mut()
            var obuf_p = obuf_view._unsafe_ptr().bitcast[Scalar[DType.int32]]()
            (obuf_p + 0)[] = Int32(0)
            str_off_bufs.append(obuf^)
            str_byte_prefix.append(prefix^)

            # VALIDITY + NULL COUNT, IN THE FORK — kind 2 unchanged, see its
            # note on `_ConcatWork`: the helpers read only `_validity` /
            # `_offset` / `_length` and are layout-agnostic.
            work_items.append(_ConcatWork(Int32(c), UInt8(2), 0, total_rows))
            for t in range(tiles):
                var srs = (t * total_rows) // tiles
                var sre = ((t + 1) * total_rows) // tiles
                if t == tiles - 1:
                    sre = total_rows
                if string_bytebal:
                    srs = sbounds[t]
                    sre = sbounds[t + 1]
                if sre <= srs:
                    # Empty tile (total_rows < tiles, or one row costlier than
                    # a whole byte-balanced target) — skip.
                    continue
                work_items.append(_ConcatWork(Int32(c), UInt8(3), srs, sre))
        else:
            var nbytes = max(total_rows * w, 1)
            var buf = OwnedAlignedBuffer(nbytes)
            buf.set_length(Int64(total_rows * w))
            fixed_bufs.append(buf^)
            var ph_off = OwnedAlignedBuffer(1)
            ph_off.set_length(0)
            str_off_bufs.append(ph_off^)
            str_byte_prefix.append(List[Int]())
            # VALIDITY + NULL COUNT, IN THE FORK. Emitted FIRST for this column
            # so it is dispatched before that column's tiles: it is the longest
            # single item of the three kinds (a whole-column bitmap build) and a
            # straggler costs least when it starts earliest. `row_end` carries
            # `total_rows` — the item has no row range of its own.
            work_items.append(_ConcatWork(Int32(c), UInt8(2), 0, total_rows))
            # Partition [0, total_rows) into `tiles` even ranges.
            for t in range(tiles):
                var rs = (t * total_rows) // tiles
                var re = ((t + 1) * total_rows) // tiles
                if t == tiles - 1:
                    re = total_rows
                if re <= rs:
                    continue  # empty tile (total_rows < tiles) — skip
                work_items.append(_ConcatWork(Int32(c), UInt8(0), rs, re))

    var num_tasks = len(work_items)

    # THE FAN, READ OUT OF A RUN RATHER THAN INFERRED. `morsels` is the per-column
    # TILE count and `workers` is the task count the fork actually gets — the two
    # numbers a task-count assertion is the ONLY available falsifier for, since a
    # 2-task fan and a 22-task fan return byte-identical results.
    #
    # ⚠ THE `grain` FIELD IS DESCRIPTIVE HERE, NOT THE LIMITER. This site's floor
    # is `COPY_TILE_MIN_BYTES` (bytes per tile), not a row grain; the value stored
    # is the rows-per-tile the fan actually produced, so a reader sees the
    # realised geometry rather than a constant. Under the byte-equiv FORCE
    # fixture the tile count is pinned to 3 and no floor applies at all.
    grain_geometry_record(
        SITE_CONCAT,
        total_rows,
        (total_rows + tiles - 1) // tiles,
        tiles,
        min(num_tasks, worker_count),
        options.trace_geometry,
    )

    # PARALLELIZE-BOUNDARY: row-range tiled RecordBatch concat.
    # Four kinds of work item, and each names the container it owns:
    # Disjointness:
    #   * kind 0 (fixed tile)  writes ONLY the destination byte slice
    #     [row_start*width, row_end*width) of `fixed_bufs[][col]`;
    #   * kind 3 (STRING tile) writes ONLY the payload byte range of
    #     `fixed_bufs[][col]` covering rows [row_start, row_end) — derived from
    #     `str_byte_prefix[col]`, monotone in the row index, so tile ranges that
    #     partition [0,total_rows) yield byte ranges that cannot overlap — AND
    #     the int32 slots [row_start+1, row_end] of `str_off_bufs[][col]`, which
    #     likewise partition [1, total_rows]. Slot 0 is written by the DRIVER
    #     before dispatch and by no task;
    #   * kind 1 (whole STRING, `ConcatOptions.string_tiling=False`) writes ONLY
    #     `out_columns[][col]`;
    #   * kind 2 (validity)    writes ONLY `out_validity[][col]` and
    #     `out_nulls[][col]`.
    #   A column takes kind 0+2, or kind 3+2, or kind 1 — never a mixture — so
    #   the four kinds write four DISJOINT containers and, within each, one slot
    #   per column. Input is read-only across the window, shared by every task.
    #   The bitmap boundary-byte race is avoided by ownership, not by
    #   serialization. Exactly ONE task per column writes that column's validity
    #   bitmap and it writes the whole of it, so no two threads share a bitmap
    #   byte. (Splitting validity BY ROW RANGE would need 8-row-aligned tiles;
    #   that is deliberately not done: a whole-column bitmap is ~1/64th of the
    #   value payload, so it does not need its own fan.) Kind 2 serves STRING
    #   columns the same way because its helpers are layout-agnostic.
    # Liveness: State owns the input slab, output Column slab, destination value
    #   buffers, string offsets buffers, validity slab and null-count slab via
    #   OwnedPointer; the driver's `var state` slot holds the State alive across
    #   `run_with_state`, whose drain barrier rejoins every worker before this
    #   function returns.
    # No-realloc: `fixed_bufs` and `str_off_bufs` are pre-sized (set_length
    #   applied); `out_columns`, `out_validity` and `out_nulls` are pre-filled to
    #   num_cols; workers mutate live slots/slices only, never grow a container.
    var state = _ConcatTiledState(
        owned_input^, out_columns^, fixed_bufs^, str_off_bufs^,
        out_validity^, out_nulls^,
        work_items^, batch_row_offset^, col_width^, str_byte_prefix^,
    )
    var task = _ConcatTiledTask(Int32(0))
    if _tb_on:
        # Close the SETUP bracket at the fork boundary. No fork can have completed
        # inside it (this driver's first fork is the one below), so wall == serial.
        sched_trace_add_serial_phase(
            PHASE_CONCAT_TILED_SETUP,
            UInt64(perf_counter_ns()) - _tb_t0,
            sched_trace_fork_ns_now() - _tb_f0,
        )
    # CLONED BEFORE THE DISPATCH CONSUMES IT — the teardown wave below needs a
    # token and `cancel_token` is moved into `run_with_state` on the next
    # statement. Same shape and same reason as the column-parallel path.
    var release_token = cancel_token.clone()
    _ = dispatcher.run_with_state[_ConcatTiledState, _ConcatTiledTask](
        state, task^, num_tasks, cancel_token^,
        site_id=SITE_CONCAT,
    )
    if _tb_on:
        # Open the ASSEMBLE bracket the instant the drain barrier rejoins: from
        # here to the driver's return is exactly the post-barrier serial window
        # that `inter_ns[SITE_CONCAT]` claims but cannot prove.
        _tb_t0 = UInt64(perf_counter_ns())
        _tb_f0 = sched_trace_fork_ns_now()

    # Drain barrier rejoined. Read the error channel.
    var raised = state.err_flag[].load() != Int8(0)
    var raised_msg = String("")
    if raised:
        raised_msg = String(state.err_msg[])

    # Swap the output Column slab + fixed value buffers out of their heap slots.
    # Move the slabs out through `_take_slab`: a swap against an empty slab, so
    # each heap slot keeps a destructible placeholder until state^ drops at
    # scope exit and no pointer to the slot is formed.
    var done_columns = _take_slab(state.out_columns[])
    var done_bufs = _take_slab(state.fixed_bufs[])
    var done_str_offs = _take_slab(state.str_off_bufs[])
    var done_validity = _take_slab(state.out_validity[])

    if raised:
        # SERIAL teardown on the failure path, deliberately: a `raised` here can
        # be a cancellation, and a teardown DISPATCH would then raise a SECOND
        # error that masks the first. Same reasoning as the column-parallel
        # path's `raised` decline.
        _ = release_token^
        _ = done_columns^
        _ = done_bufs^
        _ = done_str_offs^
        _ = done_validity^
        var drop_in = _take_slab(state.input_batches[])
        _ = drop_in^
        _ = state^
        raise Error("concat_record_batches_column_parallel (tiled): " + raised_msg)

    # -- Assemble the output batch ------------------------------------------
    # Every per-column BUFFER is now built: values by the kind-0 tiles, validity
    # and null count by the kind-2 items, STRING Columns whole by the kind-1
    # items. This loop only WRAPS them, so it is O(num_cols) pointer moves and
    # carries no per-row or per-batch work. The validity bitmap build and the
    # null-count scan run in the fork as kind-2 items (see `_ConcatWork`).
    var owned_cols = done_columns^
    var owned_bufs = done_bufs^
    var owned_str_offs = done_str_offs^
    var owned_validity = done_validity^
    var builder = RecordBatchBuilder.with_capacity(num_cols)

    ref in_slab = state.input_batches[]

    for c in range(num_cols):
        var w = state.col_width[c]
        # Drop the (empty for tiled cols / built for whole-column string cols)
        # placeholder.
        var placeholder = owned_cols.take_slot_unchecked(c)
        if w == 0 and not string_tiles:
            # STRING/BINARY, WHOLE-COLUMN: the worker-built Column IS the slot.
            builder.add_column(placeholder^)
            var ph_buf = owned_bufs.take_slot_unchecked(c)
            _ = ph_buf^
            var ph_off = owned_str_offs.take_slot_unchecked(c)
            _ = ph_off^
            var ph_val = owned_validity.take_slot_unchecked(c)
            _ = ph_val^
        elif w == 0:
            # STRING/BINARY, TILED. Payload + offsets were filled by
            # the kind-3 tiles, validity + null count by the kind-2 item; this
            # only WRAPS them. `arrow_type` comes from the schema batch, exactly
            # as the fixed-width arm below does — STRING vs BINARY is carried,
            # and the whole-column helper's `_decimal_p/_s` carry does not apply
            # (a variable-width column has neither).
            _ = placeholder^  # empty Column() — trivial drop
            ref s_src_col = in_slab[schema_idx].value().column_at(c)
            var s_at = s_src_col.arrow_type
            var s_data = owned_bufs.take_slot_unchecked(c)
            var s_offs = owned_str_offs.take_slot_unchecked(c)
            var s_validity = owned_validity.take_slot_unchecked(c)
            builder.add_column(Column[HeapRegion](
                arrow_type=s_at,
                data=s_data^,
                offsets=s_offs^,
                validity=s_validity^,
                length=total_rows,
                null_count=state.out_nulls[][c],
                offset=0,
            ))
        else:
            _ = placeholder^  # empty Column() — trivial drop
            ref src_col = in_slab[schema_idx].value().column_at(c)
            var at = src_col.arrow_type
            var ph_off2 = owned_str_offs.take_slot_unchecked(c)
            _ = ph_off2^
            var buf = owned_bufs.take_slot_unchecked(c)
            buf.set_length(Int64(total_rows * w))
            var validity = owned_validity.take_slot_unchecked(c)
            var out_col = Column[HeapRegion](
                arrow_type=at,
                data=buf^,
                offsets=None,
                validity=validity^,
                length=total_rows,
                null_count=state.out_nulls[][c],
                offset=0,
            )
            # DECIMAL (p, s) IS PER-COLUMN, NOT PART OF THE ArrowType.
            # `_arrow_type_byte_width` gives DECIMAL128 a width of 16, so a
            # decimal column reaches this arm, and the metadata carry its
            # whole-column sibling does (`_concat_fixed_columns_multi`) has to
            # happen here too, or the tiled and whole-column paths stop being
            # byte-identical. Without it a scale-2 decimal comes back scale-0:
            # `312.50` reads as `31250`, with no raise and no warning.
            # `tests/test_concat_byte_equivalence.mojo` pins the carry.
            out_col._decimal_p = src_col._decimal_p
            out_col._decimal_s = src_col._decimal_s
            builder.add_column(out_col^)
    owned_cols.set_len_unchecked(0)
    _ = owned_cols^
    owned_bufs.set_len_unchecked(0)
    _ = owned_bufs^
    owned_str_offs.set_len_unchecked(0)
    _ = owned_str_offs^
    owned_validity.set_len_unchecked(0)
    _ = owned_validity^

    # THE TEARDOWN WAVE: the same one the column-parallel path takes, for the
    # same reason. Without it the tiled path would destroy N RecordBatches on
    # the DRIVER with every worker rejoined and parked.
    var drained_input = _take_slab(state.input_batches[])
    if _on_pool_dispatch_active():
        _ = release_token^
        _ = drained_input^
    else:
        release_concat_inputs_parallel(
            drained_input^, total_rows, dispatcher, release_token^,
        )
    _ = state^

    if _tb_on:
        # Close ASSEMBLE. Excludes only the trailing `builder.build(schema)` call
        # (schema wiring + a column-list move, sub-microsecond); everything the
        # post-barrier window actually spends — the per-column Column wrap and
        # the input teardown wave — is inside.
        sched_trace_add_serial_phase(
            PHASE_CONCAT_TILED_ASSEMBLE,
            UInt64(perf_counter_ns()) - _tb_t0,
            sched_trace_fork_ns_now() - _tb_f0,
        )

    if schema_opt:
        return builder.build(schema_opt.take())

    var sb = SchemaBuilder()
    for c in range(num_cols):
        sb.add_field(captured_fields[c].copy())
    return builder.build(sb.build())
