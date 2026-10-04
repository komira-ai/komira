# =============================================================================
# compiler_join_assembly — generic join result assembly (post-probe gather)
# =============================================================================
#
# Contains:
#   - _resolve_join_output_cols: name resolution for projected join output,
#     with "_right" suffix collision handling. Exported for use by
#     `komira_engine_operators.compiler_join_fused`.
#   - _assemble_join_result_projected: late-materialization gather that
#     writes ONLY the requested output columns from pre-collected index
#     lists. Handles STRING + fixed-width + nullable sides.
#   - _assemble_join_result: unified full-materialization function for all
#     join types (inner, left, right, full) via boolean flags for nullable
#     sides.
#
# The single-pass fused probe+gather variants (_assemble_inner_join_fused,
# _assemble_inner_join_chunked, _assemble_inner_join_fused_projected) live
# in `komira_engine_operators.compiler_join_fused`.
#
# No runtime wildcard-origin pointer sites.
# =============================================================================

from std.memory import unsafe_memcpy, unsafe_memset, alloc
from std.sys.intrinsics import prefetch, PrefetchOptions
from std.collections import Set
from std.sys import size_of
from std.io import FileDescriptor

# -----------------------------------------------------------------------------
# _STDERR — DIAGNOSTICS DO NOT GO ON THE DATA CHANNEL.
# -----------------------------------------------------------------------------
#
# A query binary that streams Arrow IPC writes its answer to **fd 1**, and this
# file can be inside that binary's link closure. A bare `print(...)` here
# therefore lands IN THE ANSWER, not beside it: a reader parses the diagnostic
# text as the stream's length prefix and fails over an intact answer.
#
# ROUTED, NOT DELETED -- the `ArrowOffsetPromotion` banner below announces a
# change to the DECLARED TYPE of a user-visible column and must never be silent.
# Only its destination moves (same spelling as `compiler_helpers.mojo:_STDERR`).
comptime _STDERR: FileDescriptor = FileDescriptor(2)

from komira_arrow.schema import RecordBatch, RecordBatchBuilder, Schema, SchemaBuilder, Field
from komira_arrow.column import Column
from komira_arrow.arrow_types import ArrowType, widen_offset_type
from komira_arrow.offset_overflow import (
    ARROW_INT32_OFFSET_MAX,
    should_promote_offsets,
)
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_buffer.heap_region import HeapRegion
from komira_arrow.bitmap import Bitmap, gather_bits_aligned_buffer
from komira_concurrency.parallel_dispatch import NoDispatch, ParallelDispatch
from komira_column_kernels.compiler_helpers import (
    element_size,
    has_right_suffix,
    strip_right_suffix,
    _parallel_string_gather,
    _parallel_fixedwidth_gather,
    _on_pool_dispatch_active,
    _gather_nw,
    GATHER_PARALLEL_MIN_ROWS,
)
from komira_counters.gather_width_counter import (
    gather_note_narrow_typed,
    gather_note_width_fallback,
)
from komira_counters.join_index_window_counter import join_index_window_note_gather
from komira_join_assembly.join_key_cse import (
    JoinKeyAliasMap,
    join_key_cse_note_gathers,
    join_key_cse_note_shares,
)


# =============================================================================
# Projected join result assembly (late materialization)
# =============================================================================
#
# Resolves a list of output column names to (side, col_idx) pairs where
# side = 0 for probe (left), 1 for build (right). Post-join collision
# handling: when a right-side column name collides with a left-side name,
# the right one is addressed via "_right" suffix in the output schema.
# =============================================================================


comptime _JSIDE_PROBE: UInt8 = 0
comptime _JSIDE_BUILD: UInt8 = 1

# Prefetch distance for the STRING gather Pass-1 (compute-total-bytes) loop. On Apple M4, an L1 miss costs ~12-16
# cycles and L2 ~50-80 cycles; prefetching `_STR_GATHER_PF_LEN` rows ahead
# at the offsets-buffer cache line hides the random-access miss on the
# random-row offsets fetch. Mirrors the dictionary `resolve_int64` prefetch
# shape. Per-row offsets footprint
# is 4 bytes (Int32), so 16 rows = 64 bytes = one ARM cache line — exactly
# matches the lookahead used by the gather-batch fixed-width prefetch.
comptime _STR_GATHER_PF_LEN: Int = 16


def resolve_join_output_cols(
    probe_schema: Schema,
    build_schema: Schema,
    names: List[String],
) raises -> Tuple[List[UInt8], List[Int]]:
    """Resolve output column names to (side, index) pairs.

    For each name:
      - First search the probe schema (case-sensitive exact match).
      - Otherwise, search the build schema.
      - Otherwise, check for "_right" suffix on a colliding name and
        search the build schema for the stripped name.

    Args:
        probe_schema: Schema of the left (probe) batch.
        build_schema: Schema of the right (build) batch.
        names: Output column names to resolve.

    Returns:
        Tuple of (sides, indices) parallel lists.
    """
    var sides = List[UInt8]()
    var indices = List[Int]()

    # Build left name set for O(1) probe-side collision detection.
    var left_name_set = Set[String]()
    for i in range(probe_schema.num_columns()):
        left_name_set.add(probe_schema.field_name(i))

    for k in range(len(names)):
        var name = names[k]
        var found = False

        # 1) Try probe schema (preferred — the _right suffix is for collisions).
        for i in range(probe_schema.num_columns()):
            if probe_schema.field_name(i) == name:
                sides.append(_JSIDE_PROBE)
                indices.append(i)
                found = True
                break

        if found:
            continue

        # 2) Try build schema by exact match.
        for i in range(build_schema.num_columns()):
            if build_schema.field_name(i) == name:
                sides.append(_JSIDE_BUILD)
                indices.append(i)
                found = True
                break

        if found:
            continue

        # 3) Try "_right" suffix stripping: if name ends with "_right",
        # search the build schema for the stripped name. Only valid when
        # the stripped name collides with a left column name.
        if has_right_suffix(name):
            var orig = strip_right_suffix(name)
            if orig in left_name_set:
                for i in range(build_schema.num_columns()):
                    if build_schema.field_name(i) == orig:
                        sides.append(_JSIDE_BUILD)
                        indices.append(i)
                        found = True
                        break

        if not found:
            raise Error(
                "_resolve_join_output_cols: column '" + name
                + "' not found in either probe or build schema"
            )

    return (sides^, indices^)


def assemble_join_result_projected(
    left: RecordBatch,
    right: RecordBatch,
    left_indices: List[Int],
    right_indices: List[Int],
    output_names: List[String],
    left_nullable: Bool = False,
    right_nullable: Bool = False,
    gather_parallel_min_rows: Int = GATHER_PARALLEL_MIN_ROWS,
    offset_promote_at: Int = ARROW_INT32_OFFSET_MAX,
) raises -> RecordBatch:
    """Dispatcher-less (SERIAL gather) entry — forwards to
    `assemble_join_result_projected_dispatch` with comptime `has_pool=False`.

    READ THIS BEFORE ADDING A NEW CALLER. `has_pool=False` prunes the parallel
    gather arm at COMPTIME, so an assemble reached through THIS entry is
    honestly serial no matter how large the output. That is the right entry for
    a caller running ON a pool worker (the per-morsel `JoinProbeOp.execute`
    shape -- its gather is suppressed to serial at RUNTIME by
    `_on_pool_dispatch_active` anyway) or for a caller whose outputs are
    small. A caller that assembles a LARGE (>= 64K row) join output
    OFF-pool MUST reach `assemble_join_result_projected_dispatch` with its
    dispatcher — see that function's docstring.

    Args:
        left: The left (probe) side batch.
        right: The right (build) side batch.
        left_indices: Left-side row indices (-1 = null when left_nullable).
        right_indices: Right-side row indices (-1 = null when right_nullable).
        output_names: Names of the output columns to materialize. Names
            follow post-join schema conventions: left cols keep their
            name, right cols colliding with left get "_right" suffix.
        left_nullable: If True, left_indices may contain -1.
        right_nullable: If True, right_indices may contain -1.

    Returns:
        A RecordBatch with exactly the requested columns, in the requested
        order.
    """
    # Class C serial-fallback shape: D=NoDispatch with a CONCRETE origin from a
    # stack-local, never a MutAnyOrigin wildcard. `has_pool=False` prunes the
    # dispatch branch, so the Optional pointer is a never-deref'd phantom.
    var _nd = NoDispatch()
    comptime nd_o = origin_of(_nd)
    return assemble_join_result_projected_dispatch[False, NoDispatch, nd_o](
        left,
        right,
        left_indices,
        right_indices,
        output_names,
        Optional[Pointer[NoDispatch, nd_o]](None),
        left_nullable,
        right_nullable,
        gather_parallel_min_rows=gather_parallel_min_rows,
        offset_promote_at=offset_promote_at,
    )


def assemble_join_result_projected_dispatch[
    has_pool: Bool, D: ParallelDispatch, disp_o: Origin[mut=True],
](
    left: RecordBatch,
    right: RecordBatch,
    left_indices: List[Int],
    right_indices: List[Int],
    output_names: List[String],
    dispatcher_ptr: Optional[Pointer[D, disp_o]],
    left_nullable: Bool = False,
    right_nullable: Bool = False,
    gather_parallel_min_rows: Int = GATHER_PARALLEL_MIN_ROWS,
    offset_promote_at: Int = ARROW_INT32_OFFSET_MAX,
) raises -> RecordBatch:
    """Assemble a join result containing ONLY the named output columns.

    This is the late-materialization path: instead of gathering every
    column from both sides and letting a downstream projection drop them,
    we only gather the columns that are actually needed.

    For a two-join, four-column aggregate this drops materialized columns
    from 10+ to ~5 per join.

    WHY THIS ENTRY EXISTS. The shared gather kernels run on the engine's own
    runtime, never on Mojo's stdlib `parallelize(...)` pool, so the parallel
    gather arm needs a dispatcher. The dispatcher-less entry's `has_pool` is
    COMPTIME FALSE, so a large off-pool join output assembled through it is
    serial. This entry threads the caller's dispatcher so the parallel arm is
    compiled and reachable.

    The decision is the same as `emit_gather_column_projected`'s:
    `count >= gather_parallel_min_rows` AND NOT `_on_pool_dispatch_active()`.
    Threading a dispatcher only makes the arm REACHABLE; the on-pool per-morsel
    assemble is still suppressed at runtime, and `fork_join_shared` degrades a
    nested wave to inline chunks. Nothing runs on the stdlib pool, because this
    routes through the CALLER'S dispatcher.

    `D` is the caller's concrete dispatcher, so the `run_with_state` calls DEVIRTUALIZE per instantiation.
    An engine-side caller holding a `SharedForkJoinHandle` passes `handle.ptr`
    straight through — that is how a core kernel gets the pool without
    `komira_core` naming `LocalDispatcher` (which lives up in
    `komira_async`).

    Args:
        left: The left (probe) side batch.
        right: The right (build) side batch.
        left_indices: Left-side row indices (-1 = null when left_nullable).
        right_indices: Right-side row indices (-1 = null when right_nullable).
        output_names: Names of the output columns to materialize. Names
            follow post-join schema conventions: left cols keep their
            name, right cols colliding with left get "_right" suffix.
        dispatcher_ptr: The caller's dispatcher, or None. Dereferenced only
            under `has_pool=True`.
        left_nullable: If True, left_indices may contain -1.
        right_nullable: If True, right_indices may contain -1.
        gather_parallel_min_rows: Output row count at or above which a
            column gather runs in parallel. `GATHER_PARALLEL_MIN_ROWS` in
            production; tests pass `1` (force the parallel arm) or
            `GATHER_SERIAL_ONLY` (serial reference).
        offset_promote_at: Data-byte count above which a variable-width output
            column is promoted to 64-bit offsets. `ARROW_INT32_OFFSET_MAX` in
            production (the session's configured value otherwise).

    Returns:
        A RecordBatch with exactly the requested columns, in the requested
        order.
    """
    # When output_names is empty (ungrouped count(*) above an inner/left join — no group-by keys,
    # no agg-child column refs), the per-column gather loop runs zero
    # iterations and RecordBatchBuilder.build() falls into its
    # "num_cols == 0" default-empty branch, discarding the matched-row
    # count. Fast-path: emit a count-only batch carrying len(left_indices)
    # so the downstream count(*) reads num_rows correctly. Matches the
    # canonical primitive used by the streaming Parquet count-only path
    # (RecordBatch.count_only).
    if len(output_names) == 0:
        return RecordBatch.count_only(len(left_indices))

    var resolved = resolve_join_output_cols(left.schema, right.schema, output_names)
    var sides = resolved[0].copy()
    var col_indices = resolved[1].copy()

    var count = len(left_indices)
    var num_out = len(output_names)
    var builder = RecordBatchBuilder()
    var sb = SchemaBuilder()

    # NOTE (origin guard): laundering left_indices/right_indices pointers
    # through Int(...) and rebuilding them as a wildcard-origin UnsafePointer
    # (so both sides could share one `idx_ptr` local) severs Mojo's lifetime
    # tracking and causes non-deterministic row-count drift.
    #
    # So the origins are NOT unified at all: we call an inner helper that
    # is parameterized on `idx_origin: ImmutOrigin`, and at each call site
    # pass `left_indices.unsafe_ptr()` or `right_indices.unsafe_ptr()`
    # directly. Mojo's type system then tracks each List's origin
    # independently and keeps it alive for the duration of the call. No
    # Int laundering, no wildcard origins, no manual keepalive.
    #
    for out_c in range(num_out):
        var side = sides[out_c]
        var col_idx = col_indices[out_c]
        var is_probe = (side == _JSIDE_PROBE)
        var field_name = output_names[out_c]

        if is_probe:
            emit_gather_column_projected_dispatch[has_pool, D, disp_o](
                left,
                col_idx,
                field_name,
                left_nullable,
                left_indices,
                count,
                dispatcher_ptr,
                builder,
                sb,
                gather_parallel_min_rows=gather_parallel_min_rows,
                offset_promote_at=offset_promote_at,
            )
        else:
            emit_gather_column_projected_dispatch[has_pool, D, disp_o](
                right,
                col_idx,
                field_name,
                right_nullable,
                right_indices,
                count,
                dispatcher_ptr,
                builder,
                sb,
                gather_parallel_min_rows=gather_parallel_min_rows,
                offset_promote_at=offset_promote_at,
            )

    var schema = sb.build()
    return builder.build(schema^)


# =============================================================================
# Inner helper for projected join output — one column at a time
# =============================================================================
#
# Parameterized on `idx_origin: ImmutOrigin` so the caller can pass either
# `left_indices.unsafe_ptr()` or `right_indices.unsafe_ptr()` directly
# without having to unify the two origin types (see the origin-guard note
# in `assemble_join_result_projected_dispatch`).
#
# Mojo tracks the origin of `idx_ptr` through the call, so the source List
# stays alive for the entire helper body — no keepalive, no Int round-trip.
# =============================================================================


def emit_gather_column_projected(
    batch: RecordBatch,
    col_idx: Int,
    field_name: String,
    is_nullable: Bool,
    imm indices: List[Int],
    count: Int,
    mut builder: RecordBatchBuilder,
    mut sb: SchemaBuilder,
    gather_parallel_min_rows: Int = GATHER_PARALLEL_MIN_ROWS,
    offset_promote_at: Int = ARROW_INT32_OFFSET_MAX,
) raises:
    """Dispatcher-less (SERIAL) entry — forwards to
    `emit_gather_column_projected_dispatch` with comptime `has_pool=False`.

    The shared gather kernels this delegates to never use Mojo's stdlib
    `parallelize(...)` pool, so a caller with no dispatcher is honestly
    serial. A caller that assembles a
    LARGE (>= 64K row) join output OFF-pool should reach
    `emit_gather_column_projected_dispatch` (or, one level up,
    `assemble_join_result{,_projected}_dispatch`) with its dispatcher instead."""
    # Class C serial-fallback shape: D=NoDispatch with a CONCRETE origin from a
    # stack-local, never a MutAnyOrigin wildcard. `has_pool=False` prunes the
    # dispatch branch, so the Optional pointer is a never-deref'd phantom.
    var _nd = NoDispatch()
    comptime nd_o = origin_of(_nd)
    emit_gather_column_projected_dispatch[False, NoDispatch, nd_o](
        batch,
        col_idx,
        field_name,
        is_nullable,
        indices,
        count,
        Optional[Pointer[NoDispatch, nd_o]](None),
        builder,
        sb,
        gather_parallel_min_rows=gather_parallel_min_rows,
        offset_promote_at=offset_promote_at,
    )


def emit_gather_column_projected_dispatch[
    has_pool: Bool, D: ParallelDispatch, disp_o: Origin[mut=True],
](
    batch: RecordBatch,
    col_idx: Int,
    field_name: String,
    is_nullable: Bool,
    imm indices: List[Int],
    count: Int,
    dispatcher_ptr: Optional[Pointer[D, disp_o]],
    mut builder: RecordBatchBuilder,
    mut sb: SchemaBuilder,
    index_base: Int = 0,
    gather_parallel_min_rows: Int = GATHER_PARALLEL_MIN_ROWS,
    offset_promote_at: Int = ARROW_INT32_OFFSET_MAX,
) raises:
    """Gather one output column from `batch` at `col_idx`, writing into
    `builder` and appending the field to `sb`.

    Used by `assemble_join_result` / `assemble_join_result_projected` so the
    per-column gather loop can accept a borrowed `List[Int]` of row indices.
    Callers pass `left_indices` / `right_indices` directly (the borrow origin
    is tracked by Mojo, so each List stays alive for the duration of the call
    — the origin-guard idiom; no Int laundering, no wildcard origin).

    PERF: when the output is large enough (>= `gather_parallel_min_rows`,
    default `GATHER_PARALLEL_MIN_ROWS`), AND we are NOT
    running inside a live executor-pool dispatch (`_on_pool_dispatch_active`),
    the per-column STRING two-pass and fixed-width scatter run in PARALLEL via
    the SHARED `_parallel_string_gather` / `_parallel_fixedwidth_gather` sort
    kernels (with the `-1` null-sentinel branch enabled for outer-join sides).
    The on-pool suppression mirrors `gather_batch`: the per-morsel
    `JoinProbeOp.execute` runs THIS assemble on a LIVE `run_with_state` pool
    (already 1/N of the data across N workers), where a nested `parallelize`
    would LIVELOCK the dispatcher. The off-pool composite-leaf
    full-output assemble (after the probe's parallelize joins) parallelizes —
    same context as `SortSink.finalize`. Byte-identical to the serial gather;
    validity is resolved SERIALLY on the main thread and the output Column is
    built ONCE on the main thread after the fork-join barrier (cross-thread
    safety: workers only memcpy into pre-sized disjoint byte slices, never
    construct/drop a Column / StringArray / ArcPointer).

    `gather_parallel_min_rows` is the test seam for the parallel/serial
    choice: `1` forces the parallel arm, `GATHER_SERIAL_ONLY` forces the serial
    reference arm; both must produce byte-identical output.

    `offset_promote_at` is forwarded to the string arms' 64-bit offset
    promotion check (see `should_promote_offsets`).

    INDEX WINDOW: this gather reads
    `indices[index_base : index_base + count]` and produces OUTPUT rows
    `[0, count)`. The chunked join terminal passes the whole index list plus a
    base instead of `memcpy`ing each chunk's slice into a fresh `List[Int]`
    (a copy that would run single-threaded on the driver). The copy would buy
    nothing: this parameter is
    declared `read indices`, it is passed the SAME list once per column in the
    caller's loop, and every one of its serial index reads funnels through the
    ONE `idx_ptr` local below. So the window is free.

    ⚠ EXACTLY ONE INDEX SPACE MOVES. `index_base` shifts the INDEX-LIST read
    and NOTHING else. The output data buffer, the rebuilt offsets, and the
    VALIDITY BITMAP (`bm.clear(i)` / `bm.set(i)`) are all indexed by the
    chunk-local output row `i` and stay 0-based. Shifting the bitmap too is
    invisible on an INNER join over a non-nullable source, which is why the
    guard drives a NULLABLE string column through >= 3 chunks and asserts NULL
    POSITIONS per chunk.

    `index_base = 0` is the default (the serial forwarder, the projected
    entries, the unchunked leaf).
    """
    # SAFETY: raw index pointer for the serial hot loops (W=4 prefetch gather).
    # `indices` is borrowed (`read`); its origin keeps the List alive for the
    # whole body, so `idx_ptr` never dangles. `+ index_base` windows the READ
    # side only (see the INDEX WINDOW note above); every serial read in this
    # body goes through this ONE local. The parallel kernels take the
    # `List[Int]` directly and are handed `index_base` explicitly.
    var idx_ptr = indices.unsafe_ptr() + index_base

    # Per-column parallel decision (mirror compiler_helpers.gather_batch). The
    # `_on_pool_dispatch_active()` gate keeps the on-pool per-morsel probe
    # assemble SERIAL (avoids the nested-parallelize livelock); the off-pool
    # full-output composite-leaf assemble parallelizes. `has_pool` joins the
    # decision -- there is nothing to dispatch onto without a threaded
    # dispatcher, so a `has_pool=False` instantiation folds to serial at
    # comptime.
    var gather_parallel = (
        has_pool
        and count >= gather_parallel_min_rows
        and not _on_pool_dispatch_active()
    )
    # Chunk count: hardware-derived from the DISPATCHER's pool when we have one
    # (house rule: never a constant), capped by `_gather_nw`'s core count.
    var gather_nw = 1
    if gather_parallel:
        gather_nw = _gather_nw(count)

        comptime if has_pool:
            var wc = dispatcher_ptr.value()[].worker_count()
            if wc >= 1 and wc < gather_nw:
                gather_nw = wc

    ref src_col = batch.column_at(col_idx)
    var at = src_col.arrow_type
    var field_nullable = src_col._validity.__bool__() or is_nullable
    # ★ RENAME THE SOURCE FIELD; DO NOT REBUILD IT.
    #
    # `sb.add_field(Field(field_name, at, field_nullable))` would reconstruct
    # the emitted Field from THREE of its FIFTEEN slots and silently drop
    # `decimal_precision`/`decimal_scale`, `_tz`, `_dict_index_type`,
    # `_union_type_ids`, `_flags`, the kv-metadata and the nested-child lists
    # -- the same defect `compiler_helpers.project_batch_by_src_out_pairs_arm`
    # guards against for a PROJECT.
    #
    # ⛔ AND THIS FUNCTION BUILDS THE OUTPUT SCHEMA, NOT THE CALLER. The
    # `output_schema` an assemble is handed supplies only the column NAME
    # (`output_schema.field_name(c)` at both call sites); every other slot of
    # the emitted schema comes from here. So a `_build_join_output_schema`
    # that faithfully carried decimal (p, s) would be discarded one frame
    # later.
    #
    # Without this, a `decimal128(12, 2)` payload carried through
    # `INNER JOIN ON a.k = b.k` comes back `p 0 s 0` on BOTH the field and the
    # column. On the C ABI that is `Field.format_string()`'s `p < 1` fallback,
    # i.e. `decimal128(38, 0)`, so `10.25` reaches pandas / polars / DuckDB as
    # `1025` -- 100x, with no raise -- while `Column.as_decimal128` refuses it
    # outright.
    #
    # `field_at` returns a Field BY VALUE, so the three overrides below rename
    # THIS COPY and carry every other slot. `arrow_type` and `nullable` are
    # re-stated from the COLUMN because the column is authoritative for both
    # (a DICTIONARY-decoded column under a STRING field; a gather that
    # produced validity the source field did not declare).
    var out_field: Field
    if col_idx >= 0 and col_idx < batch.schema.num_columns():
        out_field = batch.schema.field_at(col_idx)
        out_field.name = field_name
        out_field.arrow_type = at
        out_field.nullable = field_nullable
    else:
        # A batch whose column slab is wider than its schema is malformed, but
        # this gather is not the place to diagnose it: fall back to the old
        # three-slot Field rather than raising out of a per-column emit.
        out_field = Field(field_name, at, field_nullable)
    sb.add_field(out_field^)

    # STRING / BINARY path: rebuild offsets + data buffers.
    # BINARY shares STRING's physical layout
    # (offsets + bytes + validity) and only differs in the type tag.
    # Both flow through the same offsets-rebuilding code path; the only
    # difference is the resulting Column's `arrow_type`. The "STRING"
    # references in error messages remain accurate for both shapes —
    # the cause is a missing offsets buffer, not a STRING-specific
    # condition.
    if at == ArrowType.STRING or at == ArrowType.BINARY:
        if not src_col._offsets:
            raise Error(
                "_assemble_join_result_projected: variable-length column missing offsets"
                " (arrow_type=" + String(at) + ")"
            )
        # Use a typed Int32 pointer for offsets
        # in both Pass-1 (compute-total-bytes) and Pass-2 (per-row copy)
        # so the inner W=4 unrolled loop and the per-row copy loop can
        # issue raw 4-byte loads without a per-iter `view_ro()` call.
        # Pointer's origin is tied to `src_col._offsets.value()` which
        # outlives this method body via the receiver borrow.
        var src_off = src_col._offset

        # Validity bitmap (if nullable)
        var validity = Optional[Bitmap[HeapRegion]](None)
        var null_count = 0
        if src_col._validity or is_nullable:
            var bm = Bitmap.create(count)
            if is_nullable:
                for i in range(count):
                    var idx = (idx_ptr + i)[]
                    if idx == -1:
                        bm.clear(i)
                        null_count += 1
                    elif src_col._validity:
                        if not src_col._validity.value().test(src_off + idx):
                            bm.clear(i)
                            null_count += 1
                        else:
                            bm.set(i)
                    else:
                        bm.set(i)
            else:
                # Only source validity matters.
                for i in range(count):
                    var idx = (idx_ptr + i)[]
                    if not src_col._validity.value().test(src_off + idx):
                        bm.clear(i)
                        null_count += 1
                    else:
                        bm.set(i)
            validity = bm^

        # Pass 1: compute total data bytes.
        #
        # PERF-CRITICAL: hand-staged W=4 unrolled gather with L1 prefetch.
        # Each row is a 4-load dependency chain (idx -> offsets_ptr+idx ->
        # start,end). The W=4 unroll lets the OOO core schedule 4
        # independent chains in flight; prefetch hides the offsets L1/L2
        # miss `_STR_GATHER_PF_LEN` rows ahead. Same shape as the
        # `DictionaryDecoder.resolve_int64` W=4 loop and the gather_batch
        # fixed-width prefetch pattern in `compiler_helpers`.
        comptime int32_size = size_of[Int32]()

        # ----------------------------------------------------------------
        # PARALLEL PATH: reuse the SHARED sort STRING
        # gather kernel (`_parallel_string_gather`) with the `-1`
        # null-sentinel branch enabled. Byte-identical to the serial Pass-1
        # / Pass-2 below: the kernel's len worker treats `-1` as a
        # zero-length row (mirrors `if idx != -1`), the scatter worker
        # skips the copy and leaves the offset flat. Off-pool only (the
        # gate above ensures the on-pool per-morsel probe stays serial).
        # ----------------------------------------------------------------
        if gather_parallel:
            var pair = _parallel_string_gather[has_pool, D, disp_o](
                src_col,
                indices,
                count,
                OwnedAlignedBuffer((count + 1) * int32_size),
                gather_nw,
                dispatcher_ptr,
                allow_null_sentinel=is_nullable,
                column_name=field_name,
                index_base=index_base,
                offset_promote_at=offset_promote_at,
            )
            var new_offsets = pair.offsets.take()
            var new_data = pair.data.take()
            var was_promoted = pair.promoted_large
            _ = pair^
            # OFFSET-WIDTH PROMOTION. The
            # gather widens to Int64 offsets rather than raising when the
            # output exceeds 2 GiB; the TAG has to follow the BUFFER or the
            # column is a lie. `widen_offset_type` is the one definition of
            # that mapping, shared with the serial arm below and with
            # `gather_batch_dispatch`.
            #
            # The SCHEMA is promoted in lockstep by `RecordBatchBuilder.build`,
            # not here: `sb.add_field` already ran above (the field is appended
            # before the arms so every arm shares one append), and the
            # reconciliation loop in `build` is the tree's ONE place where a
            # Schema is corrected to match an authoritative Column. If that
            # lockstep is ever broken, the failure is LOUD —
            # `RecordBatch._reject_layout_conflict` refuses a LARGE_STRING
            # column under a STRING field rather than repairing it back to
            # STRING and reading int64 offsets at int32 width.
            var out_at = widen_offset_type(at) if was_promoted else at
            var new_col = Column(
                arrow_type=out_at,
                data=new_data^,
                offsets=new_offsets^,
                validity=validity^,
                length=count,
                null_count=null_count,
                offset=0,
            )
            builder.add_column(new_col^)
            return

        # Tight-origin read via view_ro: ByteView pins the MmapAlignedBuffer ref
        # alive across Pass-1 (compute-total-bytes W=4 SIMD) + Pass-2
        # (per-row variable-length copy) loop bodies.
        # PERF-CRITICAL: the bitcast chain is comptime-constant; the final IR
        # is 4-byte loads at int32 stride in the W=4 unrolled gather
        # + prefetch hot path.
        var src_offsets_view = src_col._offsets.value().view_ro()
        var src_offsets_typed = src_offsets_view._unsafe_ptr().bitcast[Scalar[DType.int32]]()
        var total_bytes = 0
        comptime _STR_W: Int = 4
        var simd_end_p1 = (count // _STR_W) * _STR_W
        var i_p1 = 0
        while i_p1 < simd_end_p1:
            # Prefetch offsets line for the row `_STR_GATHER_PF_LEN` ahead.
            # Address-gen uses idx[i + PF_LEN]; idx may be -1 (null) which
            # would prefetch a bogus line — harmless (prefetch is a hint,
            # invalid addresses are silently ignored by the intrinsic).
            if i_p1 + _STR_GATHER_PF_LEN < count:
                var pf_idx = Int((idx_ptr + i_p1 + _STR_GATHER_PF_LEN)[])
                # SAFETY: prefetch is a hint; OOB addresses do not trap.
                # We omit the -1 check because (-1 + src_off) might still
                # land in a valid page (no fault), and the cost of a
                # branch dwarfs the cost of a stray prefetch.
                prefetch[
                    params = PrefetchOptions().for_read().high_locality()
                ](
                    (src_offsets_typed + src_off + pf_idx).bitcast[
                        Scalar[DType.int32]
                    ]()
                )

            # Read 4 indices into independent SSA values; each idx==-1
            # produces a zero contribution. We accumulate as 4 scalars
            # (vs SIMD reduce) because the start/end loads are per-row
            # random-access — vector-lane gather has no NEON intrinsic
            # at int32 stride. The four independent scalar chains are
            # what the OOO core exploits.
            var idx0 = (idx_ptr + i_p1 + 0)[]
            var idx1 = (idx_ptr + i_p1 + 1)[]
            var idx2 = (idx_ptr + i_p1 + 2)[]
            var idx3 = (idx_ptr + i_p1 + 3)[]
            var c0 = 0
            var c1 = 0
            var c2 = 0
            var c3 = 0
            if idx0 != -1:
                var row0 = src_off + idx0
                var s0 = Int((src_offsets_typed + row0)[])
                var e0 = Int((src_offsets_typed + row0 + 1)[])
                c0 = e0 - s0
            if idx1 != -1:
                var row1 = src_off + idx1
                var s1 = Int((src_offsets_typed + row1)[])
                var e1 = Int((src_offsets_typed + row1 + 1)[])
                c1 = e1 - s1
            if idx2 != -1:
                var row2 = src_off + idx2
                var s2 = Int((src_offsets_typed + row2)[])
                var e2 = Int((src_offsets_typed + row2 + 1)[])
                c2 = e2 - s2
            if idx3 != -1:
                var row3 = src_off + idx3
                var s3 = Int((src_offsets_typed + row3)[])
                var e3 = Int((src_offsets_typed + row3 + 1)[])
                c3 = e3 - s3
            total_bytes += c0 + c1 + c2 + c3
            i_p1 += _STR_W

        # Scalar tail (count % W elements, bounded < 4).
        while i_p1 < count:
            var idx = (idx_ptr + i_p1)[]
            if idx != -1:
                var row = src_off + idx
                var start = Int((src_offsets_typed + row)[])
                var end = Int((src_offsets_typed + row + 1)[])
                total_bytes += end - start
            i_p1 += 1

        # ==============================================================
        # THE INT32-OFFSET CEILING, SERIAL TWIN.
        #
        # The parallel twin above checks (via `_parallel_string_gather`), and
        # so must the join assemble's OWN serial pass: pass 2 narrows with
        # `Int32(dst_offset)`, so a >2 GiB join output reaching this arm (an
        # on-pool per-morsel probe, or an output under
        # `gather_parallel_min_rows` rows but over 2 GiB of bytes) would write
        # wrapped negative offsets and return a column with a correct row
        # COUNT and unaddressable rows -- the exact silent failure
        # `offset_overflow.mojo` exists to abolish. Promoting to 64-bit
        # offsets closes it.
        # ==============================================================
        var promote_serial = should_promote_offsets(total_bytes, offset_promote_at)
        if promote_serial:
            print(
                "ArrowOffsetPromotion: column '"
                + field_name
                + "' at _assemble_join_result_projected(serial string) needs "
                + String(total_bytes)
                + " data bytes for "
                + String(count)
                + " values, which exceeds the Arrow 32-bit offset limit of "
                + String(ARROW_INT32_OFFSET_MAX)
                + ". PROMOTING this column to 64-bit offsets (large_string /"
                + " large_binary). Its declared Arrow type widens accordingly;"
                + " Parquet / Arrow-IPC / C-Data exports carry the wide type.",
                file=_STDERR,
            )
        comptime int64_size = size_of[Int64]()
        var out_off_w = int64_size if promote_serial else int32_size

        var new_offsets = OwnedAlignedBuffer((count + 1) * out_off_w)
        var new_data = OwnedAlignedBuffer(max(total_bytes, 1))
        var dst_offset = 0
        # Pass 2: per-row variable-length copy. Length-tier bucketing of
        # this pass is deliberately NOT done: it measured net-negative,
        # because (1) the `copy_from_view_at` lowering already has a 2-3 way
        # size classifier inlined by the compiler that is well-tuned for a
        # mixed length distribution; (2) a 4-way ladder raises the per-row
        # branch-mispredict rate on strings that span the (8, 16, 32)
        # boundaries; (3) the per-row typed-pointer setup interferes with
        # the outer pipeline's ILP. The Pass-1 W=4 + prefetch unroll above
        # is the part that pays.
        #
        # The two arms are the SAME loop at two store widths. They are written
        # out rather than branched per row on purpose: the promoted arm runs
        # only above 2 GiB, so hoisting the width test out of a 40M-iteration
        # loop costs one duplicated body and keeps the narrow arm's
        # instruction stream free of the width test.
        if promote_serial:
            new_offsets.set_typed[Int64](0, Int64(0))
            for i in range(count):
                var idx = (idx_ptr + i)[]
                if idx != -1:
                    var row = src_off + idx
                    var start = Int((src_offsets_typed + row)[])
                    var end = Int((src_offsets_typed + row + 1)[])
                    var slen = end - start
                    if slen > 0:
                        new_data.view_range_mut(
                            dst_offset, slen
                        ).copy_from_view_at(
                            0, src_col._data.view_range_ro(start, slen)
                        )
                    dst_offset += slen
                new_offsets.set_typed[Int64](i + 1, Int64(dst_offset))
        else:
            new_offsets.set_typed[Int32](0, Int32(0))
            for i in range(count):
                var idx = (idx_ptr + i)[]
                if idx != -1:
                    var row = src_off + idx
                    var start = Int((src_offsets_typed + row)[])
                    var end = Int((src_offsets_typed + row + 1)[])
                    var slen = end - start
                    if slen > 0:
                        new_data.view_range_mut(
                            dst_offset, slen
                        ).copy_from_view_at(
                            0, src_col._data.view_range_ro(start, slen)
                        )
                    dst_offset += slen
                new_offsets.set_typed[Int32](i + 1, Int32(dst_offset))
        new_offsets.set_length(Int64((count + 1) * out_off_w))

        new_data.set_length(Int64(total_bytes))

        # Keepalive: ensure src_col._offsets stays alive through the loop
        # (we extracted a typed pointer above; the source col outlives this
        # method body via the receiver borrow).
        _ = src_offsets_typed

        # Tag follows buffer — see the parallel arm above for why the SCHEMA
        # is promoted by `RecordBatchBuilder.build` and not here.
        var out_at_serial = widen_offset_type(at) if promote_serial else at
        var new_col = Column(
            arrow_type=out_at_serial,
            data=new_data^,
            offsets=new_offsets^,
            validity=validity^,
            length=count,
            null_count=null_count,
            offset=0,
        )
        builder.add_column(new_col^)
        return

    # =====================================================================
    # LARGE_STRING / LARGE_BINARY path: the INT64-OFFSETS mirror of the arm
    # above.
    #
    # WHY THIS ARM HAS TO EXIST HERE, AND NOT SOMEWHERE ELSE. It is the
    # destination half of an existing route. `compiler_join_fused.
    # _is_variable_length_type` names FIVE layouts (STRING, BINARY,
    # LARGE_STRING, LARGE_BINARY, DICTIONARY) and its entire job is to send
    # them AWAY from the fused / chunked join-output paths, which stride raw
    # bytes at `row * element_size(at)`; they come here instead. Without this
    # arm LARGE_STRING and LARGE_BINARY would fall past every arm into the
    # fixed-width tail below, which asks a BYTE-width oracle for a
    # variable-width layout: `arrow_types.arrow_fixed_byte_width` refuses, so
    # the input would raise (and with a lenient width fallback it would build
    # a right-length column of garbage bytes with no offsets).
    #
    # NO PARALLEL BRANCH, DELIBERATELY — the same choice, for the same reason,
    # that `gather_batch_dispatch`'s LARGE_* arm makes. `_parallel_string_gather`
    # hard-codes Int32 offsets end to end (its prefix-scan buffer is
    # `(count + 1) * int32_size` and pass 2 narrows with `Int32(dst_off)`), so
    # LARGE_* takes the serial two-pass path unconditionally. A throughput
    # choice, never a correctness one.
    #
    # AND NO `check_int32_offsets` — that is the POINT of this layout, not an
    # omission. Int64 offsets have no 2 GiB ceiling, so the guard that fires on
    # a >2 GiB STRING output has nothing to check here. Copying it in would impose the very ceiling this arm exists to escape.
    # `test_int32_ceiling_is_a_string_only_property` asserts the resulting
    # offsets buffer is `(n + 1) * 8` bytes so a later "tidy-up" that narrows
    # it goes red.
    # =====================================================================
    if at == ArrowType.LARGE_STRING or at == ArrowType.LARGE_BINARY:
        if not src_col._offsets:
            raise Error(
                "_assemble_join_result_projected: variable-length column"
                " missing offsets (arrow_type=" + String(at) + ")"
            )
        comptime int64_size = size_of[Int64]()
        var src_off_l = src_col._offset

        # Validity bitmap — identical in shape to the STRING arm's, including
        # the `-1` sentinel arm. A `-1` row is NULL and contributes no bytes.
        var validity_l = Optional[Bitmap[HeapRegion]](None)
        var null_count_l = 0
        if src_col._validity or is_nullable:
            var bm = Bitmap.create(count)
            if is_nullable:
                for i in range(count):
                    var idx = (idx_ptr + i)[]
                    if idx == -1:
                        bm.clear(i)
                        null_count_l += 1
                    elif src_col._validity:
                        if not src_col._validity.value().test(src_off_l + idx):
                            bm.clear(i)
                            null_count_l += 1
                        else:
                            bm.set(i)
                    else:
                        bm.set(i)
            else:
                for i in range(count):
                    var idx = (idx_ptr + i)[]
                    if not src_col._validity.value().test(src_off_l + idx):
                        bm.clear(i)
                        null_count_l += 1
                    else:
                        bm.set(i)
            validity_l = bm^

        var src_offsets_view_l = src_col._offsets.value().view_ro()

        # Pass 1: total payload bytes the selected rows need. Accumulated in
        # 64-bit `Int` and NOT narrowed anywhere below.
        var total_bytes_l = 0
        for i in range(count):
            var idx = (idx_ptr + i)[]
            if idx != -1:
                var row = src_off_l + idx
                var start = Int(src_offsets_view_l.get_typed[Int64](row))
                var end = Int(src_offsets_view_l.get_typed[Int64](row + 1))
                total_bytes_l += end - start

        var new_offsets_l = OwnedAlignedBuffer((count + 1) * int64_size)
        var new_data_l = OwnedAlignedBuffer(max(total_bytes_l, 1))

        # Pass 2: copy the payload and rebuild the offsets at int64 width.
        # A `-1` row leaves the offset FLAT (zero-length span) and copies
        # nothing — the same contract the STRING arm honours.
        var dst_offset_l = 0
        new_offsets_l.set_typed[Int64](0, Int64(0))
        for i in range(count):
            var idx = (idx_ptr + i)[]
            if idx != -1:
                var row = src_off_l + idx
                var start = Int(src_offsets_view_l.get_typed[Int64](row))
                var end = Int(src_offsets_view_l.get_typed[Int64](row + 1))
                var slen = end - start
                if slen > 0:
                    new_data_l.view_range_mut(
                        dst_offset_l, slen
                    ).copy_from_view_at(
                        0, src_col._data.view_range_ro(start, slen)
                    )
                dst_offset_l += slen
            new_offsets_l.set_typed[Int64](i + 1, Int64(dst_offset_l))
        new_offsets_l.set_length(Int64((count + 1) * int64_size))
        new_data_l.set_length(Int64(total_bytes_l))
        _ = src_offsets_view_l

        var new_col_l = Column(
            arrow_type=at,
            data=new_data_l^,
            offsets=new_offsets_l^,
            validity=validity_l^,
            length=count,
            null_count=null_count_l,
            offset=0,
        )
        builder.add_column(new_col_l^)
        return

    # DICTIONARY path: gather int32 indices, copy shared dict offsets/data.
    # =====================================================================
    # A probe-side column decoded as DICTIONARY (e.g. low-cardinality STRING
    # under RLE_DICTIONARY parquet encoding) must not take the fixed-width
    # branch below: that would copy the 4-byte int32 indices buffer at the
    # wrong stride AND drop `_dict_data` / `_offsets` / `_dict_size`, leaving
    # a column that claims `arrow_type == DICTIONARY` with no dict metadata.
    #
    # Mirrors `gather_batch`'s DICTIONARY branch in `compiler_helpers.mojo`:
    # gather the int32 indices per row using
    # `idx_ptr` selectivity, then copy the shared dictionary offsets and
    # bytes verbatim (they are dict-entry indexed, not row-indexed, so no
    # gather is needed). `is_nullable=True` paths emit -1 sentinel rows
    # the same way they do for fixed-width primitives below.
    if at == ArrowType.DICTIONARY:
        comptime int32_size = size_of[Int32]()
        # Pattern AB-pair: src_idx read (src_col._data) + dst_idx write
        # (fresh-allocated new_idx_buf). Each ByteView pins the MmapAlignedBuffer
        # alive across the per-row gather loop body until new_idx_buf^ moves
        # into Column(...) at function exit.
        var src_idx_view = src_col._data.view_ro()
        var src_idx = src_idx_view._unsafe_ptr().bitcast[Scalar[DType.int32]]()
        var src_off = src_col._offset
        var idx_bytes = count * int32_size
        var new_idx_buf = OwnedAlignedBuffer(max(idx_bytes, 1))
        var dst_idx_view = new_idx_buf.view_mut()
        var dst_idx = dst_idx_view._unsafe_ptr().bitcast[Scalar[DType.int32]]()

        # Validity bitmap (mirror STRING branch).
        var validity_d = Optional[Bitmap[HeapRegion]](None)
        var null_count_d = 0
        if src_col._validity or is_nullable:
            var bm = Bitmap.create(count)
            if is_nullable:
                for i in range(count):
                    var idx = (idx_ptr + i)[]
                    if idx == -1:
                        bm.clear(i)
                        null_count_d += 1
                    elif src_col._validity:
                        if not src_col._validity.value().test(src_off + idx):
                            bm.clear(i)
                            null_count_d += 1
                        else:
                            bm.set(i)
                    else:
                        bm.set(i)
            else:
                for i in range(count):
                    var idx = (idx_ptr + i)[]
                    if not src_col._validity.value().test(src_off + idx):
                        bm.clear(i)
                        null_count_d += 1
                    else:
                        bm.set(i)
            validity_d = bm^

        for i in range(count):
            var idx = (idx_ptr + i)[]
            if idx == -1:
                # Null sentinel — value irrelevant, validity bit is 0.
                (dst_idx + i)[] = Int32(0)
            else:
                (dst_idx + i)[] = (src_idx + src_off + idx)[]
        new_idx_buf.set_length(Int64(idx_bytes))


        # Copy shared dictionary offsets (dict_size + 1 int32 entries).
        # `src_col._offsets` MUST be present on a DICTIONARY column — if
        # it's not, the source itself is malformed (the parquet decoder /
        # `Column.from_dictionary` always sets it). Raise rather than
        # silently producing garbage.
        if not src_col._offsets:
            raise Error(
                "emit_gather_column_projected: DICTIONARY column missing"
                " _offsets — source column is malformed"
            )
        if not src_col._dict_data:
            raise Error(
                "emit_gather_column_projected: DICTIONARY column missing"
                " _dict_data — source column is malformed"
            )
        var dict_offsets_bytes = (src_col._dict_size + 1) * int32_size
        var new_dict_offsets = OwnedAlignedBuffer(dict_offsets_bytes)
        new_dict_offsets.copy_from_view(
            src_col._offsets.value().view_range_ro(0, dict_offsets_bytes)
        )
        new_dict_offsets.set_length(Int64(dict_offsets_bytes))


        # Copy shared dictionary bytes.
        var dict_data_len = src_col._dict_data.value().len()
        var new_dict_data = OwnedAlignedBuffer(max(dict_data_len, 1))
        if dict_data_len > 0:
            new_dict_data.copy_from_view(
                src_col._dict_data.value().view_range_ro(0, dict_data_len)
            )
        new_dict_data.set_length(Int64(dict_data_len))


        var new_col = Column(
            arrow_type=ArrowType.DICTIONARY,
            data=new_idx_buf^,
            offsets=new_dict_offsets^,
            validity=validity_d^,
            length=count,
            null_count=null_count_d,
            offset=0,
        )
        new_col._set_dict_data_from_oab(new_dict_data^)
        new_col._dict_size = src_col._dict_size
        builder.add_column(new_col^)
        return

    # =====================================================================
    # BIT-PACKED BOOL ARM.
    # =====================================================================
    #
    # Without this arm BOOL would fall into the fixed-width path and ask a
    # BYTE-width oracle for the width of a layout whose buffer is
    # `(n + 7) >> 3` bytes. A lenient width (8) would read
    # `(src_off + idx) * 8` -- a byte address computed from a BIT index, which
    # lands in the wrong byte AND discards the sub-byte position; the oracle
    # refuses instead, naming the type.
    #
    # ⚠ THIS ARM IS LOAD-BEARING FOR THREE OTHER SITES. `compiler_join_fused`
    # (x2) and `compiler_join_chunked` stride raw bytes at one precomputed
    # width per output column and cannot carry a bit-packed layout at all; the
    # repo's answer for such a layout is to route it HERE (see
    # `_is_variable_length_type` / `_any_schema_has_var_len`). That routing and
    # this arm are one change: routing BOOL to a destination that also could
    # not carry it would only move the defect.
    #
    # `gather_bits_aligned_buffer` is the shared indexed primitive — the same
    # one the FILTER survivor gather and SORT's finalize gather use. Not a
    # private ladder: this class exists because four hand-copied width ladders
    # drifted apart (see the notes at `compiler_helpers.element_size`).
    #
    # `src_off` is a BIT index for BOOL and is passed through as one.
    #
    # THE `-1` SENTINEL. On an outer join the unmatched side's index list holds
    # `-1`. Feeding that to the bit gather would read bit `src_off - 1` — a
    # live bit of the row before the window — so the sentinel rows are
    # normalised to source row 0 for the DATA gather and their validity bit is
    # cleared. The bit VALUE at a null row is unconstrained; the validity bit
    # is not. Validity follows the STRING/DICTIONARY arms' convention exactly
    # (both `-1` and source-validity consulted), not the fixed-width arm's
    # `-1`-only convention: BOOL never had a fixed-width arm to be
    # byte-identical to.
    if at == ArrowType.BOOL:
        var b_src_off = src_col._offset
        var b_bytes = (count + 7) >> 3

        var b_validity = Optional[Bitmap[HeapRegion]](None)
        var b_null_count = 0
        # `gather_bits_aligned_buffer` takes a `List[Int]`; build the windowed,
        # sentinel-normalised index list once and reuse it for the gather.
        var b_rows = List[Int](capacity=max(count, 1))
        if src_col._validity or is_nullable:
            var bm = Bitmap.create(count)
            for i in range(count):
                var idx = (idx_ptr + i)[]
                if idx == -1:
                    b_rows.append(0)
                    bm.clear(i)
                    b_null_count += 1
                else:
                    b_rows.append(idx)
                    if src_col._validity:
                        if not src_col._validity.value().test(b_src_off + idx):
                            bm.clear(i)
                            b_null_count += 1
                        else:
                            bm.set(i)
                    else:
                        bm.set(i)
            b_validity = bm^
        else:
            for i in range(count):
                b_rows.append((idx_ptr + i)[])

        var b_buf = OwnedAlignedBuffer(max(b_bytes, 1))
        b_buf.zero()
        if count > 0:
            gather_bits_aligned_buffer(b_buf, src_col._data, b_src_off, b_rows)
        b_buf.set_length(Int64(b_bytes))

        var b_col = Column(
            arrow_type=ArrowType.BOOL,
            data=b_buf^,
            offsets=None,
            validity=b_validity^,
            length=count,
            null_count=b_null_count,
            offset=0,
        )
        builder.add_column(b_col^)
        return

    # Fixed-width path: copy elem_size bytes per row.
    var elem_size = element_size(at)
    var data_buf = OwnedAlignedBuffer(max(count * elem_size, 1))

    # =====================================================================
    # ★ THE FIXED-WIDTH VALIDITY PASS — ONE PASS, FOUR ARMS.
    # =====================================================================
    #
    # A carried fixed-width column must keep its OWN validity across a join,
    # not only the outer-join PADDING nulls. Keying validity on `is_nullable`
    # (the OUTER-PADDING flag) alone would emit a nullable INT64 passenger's
    # PAYLOAD BYTE where its NULL belongs, on INNER and LEFT joins alike, while
    # the join keys and the padding nulls stay correct. So validity is built
    # from `src_col._validity or is_nullable` and consults BOTH -- the same
    # rule the STRING/BINARY and DICTIONARY arms follow.
    #
    # ONE pass, hoisted above the serial and parallel arms, so the two cannot
    # disagree (a divergence would produce an answer that changes with row
    # count and with the parallel/serial choice), and neither can the
    # non-outer arm below.
    #
    # `field_nullable` above reads `src_col._validity or is_nullable` too, so
    # the output SCHEMA and the column agree on nullability.
    #
    # COST on the common path (no source validity, no outer padding): the
    # `if` is False and nothing is allocated or walked. On an outer join it is
    # one pass. The per-row `test()` only runs when the source actually carries a
    # validity bitmap, so the hot prefetch+typed-store loops below keep their
    # shape and never grow a validity branch.
    var fw_validity = Optional[Bitmap[HeapRegion]](None)
    var fw_null_count = 0
    if src_col._validity or is_nullable:
        var fw_src_off = src_col._offset
        var bm = Bitmap.create(count)
        for i in range(count):
            var idx = (idx_ptr + i)[]
            if idx == -1:
                bm.clear(i)
                fw_null_count += 1
            elif src_col._validity:
                if not src_col._validity.value().test(fw_src_off + idx):
                    bm.clear(i)
                    fw_null_count += 1
                else:
                    bm.set(i)
            else:
                bm.set(i)
        fw_validity = bm^

    if is_nullable:
        # ----------------------------------------------------------------
        # PARALLEL PATH: the SHARED sort fixed-width
        # kernel fills `data_buf` (pre-zeroing it + skipping `-1` slots
        # via allow_null_sentinel). The validity bitmap comes from the ONE
        # pass above — shared with the serial arm, so the two cannot
        # diverge. Off-pool only.
        # ----------------------------------------------------------------
        if gather_parallel:
            data_buf = _parallel_fixedwidth_gather[has_pool, D, disp_o](
                src_col,
                indices,
                count,
                elem_size,
                data_buf^,
                gather_nw,
                dispatcher_ptr,
                allow_null_sentinel=True,
                index_base=index_base,
            )
            var new_col_p = Column(
                arrow_type=at,
                data=data_buf^,
                offsets=None,
                validity=fw_validity^,
                length=count,
                null_count=fw_null_count,
                offset=0,
            )
            # DECIMAL (p, s) IS PER-COLUMN AND THE 7-ARG CTOR ZEROES IT.
            # Mirror of `compiler_helpers.gather_batch_dispatch`'s
            # DECIMAL128-CORRECTNESS arm: prefer the SOURCE column's own
            # (p, s), fall back to the source batch's schema Field for a
            # column that was not built through `Column.from_decimal128`.
            # Without this, `Column.as_decimal128` on the join output raises
            # "column carries no precision/scale metadata".
            if at == ArrowType.DECIMAL128 or at == ArrowType.DECIMAL256:
                if src_col._decimal_p > 0:
                    new_col_p._decimal_p = src_col._decimal_p
                    new_col_p._decimal_s = src_col._decimal_s
                elif col_idx >= 0 and col_idx < batch.schema.num_columns():
                    new_col_p._decimal_p = batch.schema.field_decimal_precision(col_idx)
                    new_col_p._decimal_s = batch.schema.field_decimal_scale(col_idx)
            builder.add_column(new_col_p^)
            return

        # The zero fill goes through `view_range_mut.fill`; the prefetch +
        # typed-store hot path below needs raw typed pointers.
        data_buf.view_range_mut(0, count * elem_size).fill(0)
        # The validity bitmap was built ONCE above (shared with the parallel
        # arm). These loops only move DATA; a `-1` slot keeps the zero fill.
        var off = src_col._offset
        comptime _NP_PF: Int = 16
        if elem_size == 8:
            # Pattern AB-pair: dst (fresh-allocated data_buf) + src (src_col._data).
            # PERF-CRITICAL: bitcast chain is comptime-constant; final IR
            # matches the legacy typed-store + prefetch hot path.
            var dst8_view = data_buf.view_mut()
            var dst8 = dst8_view._unsafe_ptr().bitcast[Scalar[DType.int64]]()
            var src8_view = src_col._data.view_ro()
            var src8 = src8_view._unsafe_ptr().bitcast[Scalar[DType.int64]]()
            for i in range(count):
                if i + _NP_PF < count:
                    var fi = (idx_ptr + i + _NP_PF)[]
                    if fi != -1:
                        prefetch[params = PrefetchOptions().for_read().high_locality()](
                            (src8 + off + fi).bitcast[Scalar[DType.int64]]()
                        )
                var idx = (idx_ptr + i)[]
                if idx != -1:
                    (dst8 + i)[] = (src8 + off + idx)[]
        elif elem_size == 4:
            # Pattern AB-pair (see 8-byte arm above).
            var dst4_view = data_buf.view_mut()
            var dst4 = dst4_view._unsafe_ptr().bitcast[Scalar[DType.int32]]()
            var src4_view = src_col._data.view_ro()
            var src4 = src4_view._unsafe_ptr().bitcast[Scalar[DType.int32]]()
            for i in range(count):
                if i + _NP_PF < count:
                    var fi = (idx_ptr + i + _NP_PF)[]
                    if fi != -1:
                        prefetch[params = PrefetchOptions().for_read().high_locality()](
                            (src4 + off + fi).bitcast[Scalar[DType.int64]]()
                        )
                var idx = (idx_ptr + i)[]
                if idx != -1:
                    (dst4 + i)[] = (src4 + off + idx)[]
        elif elem_size == 2 or elem_size == 1:
                # Widths 2 and 1 get typed arms: in the per-row byte copy
                # below, a SMALLINT payload would be slower than the BIGINT
                # one it strictly undercuts in useful bytes. Same loop, same
                # prefetch distance, `int16` / `int8` store.
            #
            # ⚠ THE `-1` GUARD IS NOT DROPPABLE HERE. This is the null-aware
            # arm: a `-1` slot must keep the zero fill written above, so the
            # per-row branch survives in the narrow arms exactly as it does in
            # the 8- and 4-byte ones.
            if elem_size == 2:
                var dst2_view = data_buf.view_mut()
                var dst2 = dst2_view._unsafe_ptr().bitcast[Scalar[DType.int16]]()
                var src2_view = src_col._data.view_ro()
                var src2 = src2_view._unsafe_ptr().bitcast[Scalar[DType.int16]]()
                gather_note_narrow_typed(count)
                for i in range(count):
                    if i + _NP_PF < count:
                        var fi2 = (idx_ptr + i + _NP_PF)[]
                        if fi2 != -1:
                            prefetch[params = PrefetchOptions().for_read().high_locality()](
                                (src2 + off + fi2).bitcast[Scalar[DType.int64]]()
                            )
                    var idx2 = (idx_ptr + i)[]
                    if idx2 != -1:
                        (dst2 + i)[] = (src2 + off + idx2)[]
            else:
                var dst1_view = data_buf.view_mut()
                var dst1 = dst1_view._unsafe_ptr().bitcast[Scalar[DType.int8]]()
                var src1_view = src_col._data.view_ro()
                var src1 = src1_view._unsafe_ptr().bitcast[Scalar[DType.int8]]()
                gather_note_narrow_typed(count)
                for i in range(count):
                    if i + _NP_PF < count:
                        var fi1 = (idx_ptr + i + _NP_PF)[]
                        if fi1 != -1:
                            prefetch[params = PrefetchOptions().for_read().high_locality()](
                                (src1 + off + fi1).bitcast[Scalar[DType.int64]]()
                            )
                    var idx1 = (idx_ptr + i)[]
                    if idx1 != -1:
                        (dst1 + i)[] = (src1 + off + idx1)[]
        else:
            # Per-row view-based copy fallback.
            # ⛔ IT SURVIVES AND MUST: DECIMAL128 / INTERVAL_MONTH_DAY_NANO are
            # 16 bytes and DECIMAL256 is 32, and none of them has a typed arm.
            # The invariant is "no fallback at width 1 or 2", not "no fallback".
            gather_note_width_fallback(count, elem_size)
            for i in range(count):
                var idx = (idx_ptr + i)[]
                if idx != -1:
                    var src_offset = (off + idx) * elem_size
                    var dst_offset = i * elem_size
                    data_buf.view_range_mut(
                        dst_offset, elem_size
                    ).copy_from_view_at(
                        0,
                        src_col._data.view_range_ro(src_offset, elem_size),
                    )
        data_buf.set_length(Int64(count * elem_size))


        var new_col = Column(
            arrow_type=at,
            data=data_buf^,
            offsets=None,
            validity=fw_validity^,
            length=count,
            null_count=fw_null_count,
            offset=0,
        )
        # DECIMAL (p, s) IS PER-COLUMN AND THE 7-ARG CTOR ZEROES IT.
        # Mirror of `compiler_helpers.gather_batch_dispatch`'s
        # DECIMAL128-CORRECTNESS arm: prefer the SOURCE column's own
        # (p, s), fall back to the source batch's schema Field for a
        # column that was not built through `Column.from_decimal128`.
        # Without this, `Column.as_decimal128` on the join output raises
        # "column carries no precision/scale metadata".
        if at == ArrowType.DECIMAL128 or at == ArrowType.DECIMAL256:
            if src_col._decimal_p > 0:
                new_col._decimal_p = src_col._decimal_p
                new_col._decimal_s = src_col._decimal_s
            elif col_idx >= 0 and col_idx < batch.schema.num_columns():
                new_col._decimal_p = batch.schema.field_decimal_precision(col_idx)
                new_col._decimal_s = batch.schema.field_decimal_scale(col_idx)
        builder.add_column(new_col^)
    else:
        # ----------------------------------------------------------------
        # PARALLEL PATH: non-nullable fixed-width gather
        # via the SHARED sort kernel. No `-1` (is_nullable is False), so
        # allow_null_sentinel=False — the path is byte-identical to the
        # serial typed-store arm below + to the sort gather. Off-pool only.
        # ----------------------------------------------------------------
        if gather_parallel:
            data_buf = _parallel_fixedwidth_gather[has_pool, D, disp_o](
                src_col,
                indices,
                count,
                elem_size,
                data_buf^,
                gather_nw,
                dispatcher_ptr,
                allow_null_sentinel=False,
                index_base=index_base,
            )
            var new_col_p = Column(
                arrow_type=at,
                data=data_buf^,
                offsets=None,
                validity=fw_validity^,
                length=count,
                null_count=fw_null_count,
                offset=0,
            )
            # DECIMAL (p, s) IS PER-COLUMN AND THE 7-ARG CTOR ZEROES IT.
            # Mirror of `compiler_helpers.gather_batch_dispatch`'s
            # DECIMAL128-CORRECTNESS arm: prefer the SOURCE column's own
            # (p, s), fall back to the source batch's schema Field for a
            # column that was not built through `Column.from_decimal128`.
            # Without this, `Column.as_decimal128` on the join output raises
            # "column carries no precision/scale metadata".
            if at == ArrowType.DECIMAL128 or at == ArrowType.DECIMAL256:
                if src_col._decimal_p > 0:
                    new_col_p._decimal_p = src_col._decimal_p
                    new_col_p._decimal_s = src_col._decimal_s
                elif col_idx >= 0 and col_idx < batch.schema.num_columns():
                    new_col_p._decimal_p = batch.schema.field_decimal_precision(col_idx)
                    new_col_p._decimal_s = batch.schema.field_decimal_scale(col_idx)
            builder.add_column(new_col_p^)
            return

        # Non-nullable fixed-width gather: typed stores + prefetch.
        # The 8B/4B prefetch hot paths use raw typed pointers
        # (see compiler_helpers.mojo gather_batch for rationale).
        comptime _GATHER_PF: Int = 16
        var off = src_col._offset
        if elem_size == 8:
            # Pattern AB-pair: non-nullable fixed-width gather (no validity check).
            # PERF-CRITICAL: bitcast chain is comptime-constant; final IR
            # matches the legacy typed-store + prefetch hot path.
            var dst8_view = data_buf.view_mut()
            var dst8 = dst8_view._unsafe_ptr().bitcast[Scalar[DType.int64]]()
            var src8_view = src_col._data.view_ro()
            var src8 = src8_view._unsafe_ptr().bitcast[Scalar[DType.int64]]()
            for i in range(count):
                if i + _GATHER_PF < count:
                    prefetch[params = PrefetchOptions().for_read().high_locality()](
                        (src8 + off + (idx_ptr + i + _GATHER_PF)[]).bitcast[Scalar[DType.int64]]()
                    )
                (dst8 + i)[] = (src8 + off + (idx_ptr + i)[])[]
        elif elem_size == 4:
            # Pattern AB-pair (see 8-byte arm above).
            var dst4_view = data_buf.view_mut()
            var dst4 = dst4_view._unsafe_ptr().bitcast[Scalar[DType.int32]]()
            var src4_view = src_col._data.view_ro()
            var src4 = src4_view._unsafe_ptr().bitcast[Scalar[DType.int32]]()
            for i in range(count):
                if i + _GATHER_PF < count:
                    prefetch[params = PrefetchOptions().for_read().high_locality()](
                        (src4 + off + (idx_ptr + i + _GATHER_PF)[]).bitcast[Scalar[DType.int64]]()
                    )
                (dst4 + i)[] = (src4 + off + (idx_ptr + i)[])[]
        elif elem_size == 2:
                # Widths 2 and 1 get typed arms: in the per-row byte copy
                # below, a SMALLINT payload would be slower than the BIGINT
                # one it strictly undercuts in useful bytes. Same loop, same
                # prefetch distance, `int16` / `int8` store.
            var dst2_view = data_buf.view_mut()
            var dst2 = dst2_view._unsafe_ptr().bitcast[Scalar[DType.int16]]()
            var src2_view = src_col._data.view_ro()
            var src2 = src2_view._unsafe_ptr().bitcast[Scalar[DType.int16]]()
            gather_note_narrow_typed(count)
            for i in range(count):
                if i + _GATHER_PF < count:
                    prefetch[params = PrefetchOptions().for_read().high_locality()](
                        (src2 + off + (idx_ptr + i + _GATHER_PF)[]).bitcast[Scalar[DType.int64]]()
                    )
                (dst2 + i)[] = (src2 + off + (idx_ptr + i)[])[]
        elif elem_size == 1:
            var dst1_view = data_buf.view_mut()
            var dst1 = dst1_view._unsafe_ptr().bitcast[Scalar[DType.int8]]()
            var src1_view = src_col._data.view_ro()
            var src1 = src1_view._unsafe_ptr().bitcast[Scalar[DType.int8]]()
            gather_note_narrow_typed(count)
            for i in range(count):
                if i + _GATHER_PF < count:
                    prefetch[params = PrefetchOptions().for_read().high_locality()](
                        (src1 + off + (idx_ptr + i + _GATHER_PF)[]).bitcast[Scalar[DType.int64]]()
                    )
                (dst1 + i)[] = (src1 + off + (idx_ptr + i)[])[]
        else:
            # View-based copy fallback.
            # ⛔ IT SURVIVES AND MUST -- see the null-aware arm above.
            gather_note_width_fallback(count, elem_size)
            for i in range(count):
                var src_offset = (off + (idx_ptr + i)[]) * elem_size
                var dst_offset = i * elem_size
                data_buf.view_range_mut(
                    dst_offset, elem_size
                ).copy_from_view_at(
                    0, src_col._data.view_range_ro(src_offset, elem_size)
                )
        data_buf.set_length(Int64(count * elem_size))


        var new_col = Column(
            arrow_type=at,
            data=data_buf^,
            offsets=None,
            validity=fw_validity^,
            length=count,
            null_count=fw_null_count,
            offset=0,
        )
        # DECIMAL (p, s) IS PER-COLUMN AND THE 7-ARG CTOR ZEROES IT.
        # Mirror of `compiler_helpers.gather_batch_dispatch`'s
        # DECIMAL128-CORRECTNESS arm: prefer the SOURCE column's own
        # (p, s), fall back to the source batch's schema Field for a
        # column that was not built through `Column.from_decimal128`.
        # Without this, `Column.as_decimal128` on the join output raises
        # "column carries no precision/scale metadata".
        if at == ArrowType.DECIMAL128 or at == ArrowType.DECIMAL256:
            if src_col._decimal_p > 0:
                new_col._decimal_p = src_col._decimal_p
                new_col._decimal_s = src_col._decimal_s
            elif col_idx >= 0 and col_idx < batch.schema.num_columns():
                new_col._decimal_p = batch.schema.field_decimal_precision(col_idx)
                new_col._decimal_s = batch.schema.field_decimal_scale(col_idx)
        builder.add_column(new_col^)


def assemble_join_result(
    ref left: RecordBatch,
    ref right: RecordBatch,
    left_indices: List[Int],
    right_indices: List[Int],
    output_schema: Schema,
    left_nullable: Bool = False,
    right_nullable: Bool = False,
    key_alias_of_right: Optional[JoinKeyAliasMap] = None,
    gather_parallel_min_rows: Int = GATHER_PARALLEL_MIN_ROWS,
    offset_promote_at: Int = ARROW_INT32_OFFSET_MAX,
) raises -> RecordBatch:
    """Dispatcher-less (SERIAL gather) entry — forwards to
    `assemble_join_result_dispatch` with comptime `has_pool=False`.

    READ THIS BEFORE ADDING A NEW CALLER. See
    `assemble_join_result_projected`'s docstring: `has_pool=False` prunes the
    parallel gather arm at COMPTIME, so an assemble reached through THIS entry is
    honestly serial regardless of output size. Correct for an ON-pool per-morsel
    caller (already runtime-suppressed by `_on_pool_dispatch_active`) and for
    small outputs; a LARGE (>= 64K row) OFF-pool assemble MUST reach
    `assemble_join_result_dispatch` with its dispatcher.

    `key_alias_of_right` is threaded through this entry so that every
    INNER-full caller can carry the JOIN-KEY CSE; a transport parameter that
    stops one frame short of its callers leaves the lever unreachable from
    them.

    ⛔ THE FORWARD IS POSITIONAL past `right_nullable`, so it passes
    `index_lo=0, index_count=-1` -- the DEFAULT window. Do not "simplify"
    by dropping them: `index_count` treats any negative value other than the
    exact `-1` sentinel as a caller arithmetic slip and raises.

    Args:
        left: The left (probe) side RecordBatch (borrowed).
        right: The right (build) side RecordBatch (borrowed).
        left_indices: Left-side row indices (-1 means null when left_nullable).
        right_indices: Right-side row indices (-1 means null when right_nullable).
        output_schema: The output schema.
        left_nullable: If True, left_indices may contain -1 (null rows).
        right_nullable: If True, right_indices may contain -1 (null rows).
        key_alias_of_right: JOIN-KEY CSE map, or None (the default: every
            column is gathered). Its proof obligation lives
            in `komira_join_assembly.join_key_cse` and NOT here; this entry only
            transports it. `JoinKeyAliasMap` is a distinct TYPE and not a
            `List[Int]` so that the ASOF and CROSS kernels which also call this
            entry cannot hand one in — see that type's docstring. See
            `assemble_join_result_dispatch`.
        gather_parallel_min_rows: See `assemble_join_result_projected_dispatch`.
        offset_promote_at: See `assemble_join_result_projected_dispatch`.

    Returns:
        A RecordBatch with assembled columns from both sides.
    """
    # Class C serial-fallback shape: D=NoDispatch with a CONCRETE origin from a
    # stack-local, never a MutAnyOrigin wildcard.
    var _nd = NoDispatch()
    comptime nd_o = origin_of(_nd)
    return assemble_join_result_dispatch[False, NoDispatch, nd_o](
        left,
        right,
        left_indices,
        right_indices,
        output_schema,
        Optional[Pointer[NoDispatch, nd_o]](None),
        left_nullable,
        right_nullable,
        0,
        -1,
        key_alias_of_right,
        gather_parallel_min_rows=gather_parallel_min_rows,
        offset_promote_at=offset_promote_at,
    )


def assemble_join_result_dispatch[
    has_pool: Bool, D: ParallelDispatch, disp_o: Origin[mut=True],
](
    ref left: RecordBatch,
    ref right: RecordBatch,
    left_indices: List[Int],
    right_indices: List[Int],
    output_schema: Schema,
    dispatcher_ptr: Optional[Pointer[D, disp_o]],
    left_nullable: Bool = False,
    right_nullable: Bool = False,
    index_lo: Int = 0,
    index_count: Int = -1,
    key_alias_of_right: Optional[JoinKeyAliasMap] = None,
    gather_parallel_min_rows: Int = GATHER_PARALLEL_MIN_ROWS,
    offset_promote_at: Int = ARROW_INT32_OFFSET_MAX,
) raises -> RecordBatch:
    """Assemble a join result from matched left and right row indices.

    The dispatcher-threaded twin of `assemble_join_result`. Full rationale
    (and the parallel-gather decision) on
    `assemble_join_result_projected_dispatch`.

    Unified function for all join types:
    - INNER: left_nullable=False, right_nullable=False
    - LEFT:  left_nullable=False, right_nullable=True
    - RIGHT: left_nullable=True,  right_nullable=False
    - FULL:  left_nullable=True,  right_nullable=True

    When a side is nullable, indices of -1 produce null values in the output
    and the validity bitmap is set accordingly.

    PERF-CRITICAL:
        `left` and `right` take `ref` (borrow) instead of value to avoid
        RecordBatch ownership transfer. The function only reads columns
        through `.column_at(c)`, `.num_columns()`, and `.schema`; it never
        mutates or stores either batch. Taking by value would force callers
        on the chunked probe hot-path (`JoinProbeOp.execute`) to
        pre-`copy_batch` both the probe morsel and the build batch twice per
        chunk -- a memcpy that can dominate the probe budget.

    Args:
        left: The left (probe) side RecordBatch (borrowed).
        right: The right (build) side RecordBatch (borrowed).
        left_indices: Left-side row indices (-1 means null when left_nullable).
        right_indices: Right-side row indices (-1 means null when right_nullable).
        output_schema: The output schema.
        dispatcher_ptr: The caller's dispatcher, or None. Dereferenced only
            under `has_pool=True`.
        left_nullable: If True, left_indices may contain -1 (null rows).
        right_nullable: If True, right_indices may contain -1 (null rows).
        index_lo: First element of `left_indices` / `right_indices` to
            materialize. Default 0.
        index_count: How many index elements to materialize starting at
            `index_lo`. Exactly `-1` (the default) means "to the end of
            `left_indices`". Any OTHER negative
            value is a bad window and raises — `-1` is a named sentinel, not
            "negative means unset", so an arithmetic slip that computes a
            negative count cannot be absorbed as "the whole list".
        key_alias_of_right: JOIN-KEY CSE map, or None (the default: every
            column is gathered). Element `c` is the LEFT
            column index whose gathered OUTPUT is byte-identical to right
            column `c`'s would be, or `-1`. Built and PROVED by
            `komira_join_assembly.join_key_cse.join_key_cse_aliases`, which
            owns every decline condition; this function only executes the map
            and re-states the one precondition it can check locally (both sides
            non-nullable — see below).
            ⛔ IT IS A `JoinKeyAliasMap`, NOT A `List[Int]`, AND THAT IS LOAD-
            BEARING. This frame is shared with `asof_join_sink` (an INEQUALITY
            join) and `cross_join_kernel` (no join condition at all), for which
            an alias map is false by construction. A bare list would have been
            constructible at either; the named type is what makes that
            unstateable. See the type's docstring.
        gather_parallel_min_rows: See `assemble_join_result_projected_dispatch`.
        offset_promote_at: See `assemble_join_result_projected_dispatch`.

    Returns:
        A RecordBatch with assembled columns from both sides.

    Raises:
        Error: If a NON-DEFAULT window falls outside either index list.

    INDEX WINDOW. A chunked caller passes the ORIGINAL index lists plus
    `(index_lo, index_count)` rather than copying each chunk's slice of BOTH
    lists into fresh `List[Int]`s. The copy would buy nothing: both parameters
    are BORROWED, each is passed to `emit_gather_column_projected_dispatch`
    ONCE PER COLUMN in the loops below, and that callee declares `read
    indices: List[Int]`.

    ⚠ THE WINDOW IS A READ WINDOW ONLY. It selects which INDEX ELEMENTS this
    call materializes; the output RecordBatch is still `count` rows numbered
    from 0, and every output-side array (data, offsets, validity bitmap) is
    0-based. See `emit_gather_column_projected_dispatch`.

    ⚠ THE RANGE VALIDATION IS LOAD-BEARING. A bad window does not trip a
    `List.__getitem__` bounds check — it would silently feed
    arbitrary `Int`s to the gather as SOURCE ROW indices, which is a wrong-
    VALUES defect that no row-count assertion can see. It is checked ONCE per
    assemble (not per column, not per row), against BOTH lists.
    """
    # The DEFAULT window is validated by construction — `index_lo == 0` and
    # `index_count == -1` give `count == len(left_indices)`, which cannot
    # raise. Only a caller that actually asks for a window pays for the check,
    # and only that caller can be rejected -- including the default-window
    # callers that pass a SHORTER `right_indices` because `right` contributes
    # no output columns.
    var _lhs_n = len(left_indices)
    var count: Int
    if index_lo == 0 and index_count == -1:
        count = _lhs_n
    else:
        # ONLY the exact `-1` sentinel means "to the end". A count of `-3` is a
        # caller arithmetic slip, and absorbing it as "the whole list" would
        # turn a wrong window into a silently WIDER one.
        count = (_lhs_n - index_lo) if index_count == -1 else index_count
        if (
            index_lo < 0
            or count < 0
            or index_lo + count > _lhs_n
            or index_lo + count > len(right_indices)
        ):
            raise Error(
                "assemble_join_result_dispatch: index window [ "
                + String(index_lo)
                + ", "
                + String(index_lo + count)
                + " ) is outside the index lists (left="
                + String(_lhs_n)
                + ", right="
                + String(len(right_indices))
                + ")"
            )

    # STRUCTURAL FALSIFIER (join index window). ONE note per assemble —
    # not per column, not per row. This frame is where a windowed BORROW and a
    # per-chunk COPY become distinguishable: a copy arrives with `index_lo == 0`
    # over a list whose length IS `count`; a window arrives with a non-zero
    # `index_lo` over a LONGER list. Since the two are byte-identical on OUTPUT,
    # no correctness assertion anywhere can see the lever stop applying — see
    # `join_index_window_counter`.
    #
    # COST: at most three relaxed `fetch_add`s (exactly ONE on the default,
    # non-windowed path) per ASSEMBLE call. It is not on any per-column or
    # per-row path.
    join_index_window_note_gather(count, _lhs_n, index_lo)

    # ------------------------------------------------------------------
    # The per-column gather is delegated to `emit_gather_column_projected`
    # so STRING build-side columns flow through the offsets-rebuilding path
    # (a fixed-width-only gather would read STRING columns as int64-shaped
    # garbage with no offsets buffer).
    #
    # The prefetch + typed-store hot paths live inside
    # `emit_gather_column_projected`. Each List is
    # passed by borrow (`read indices: List[Int]`); Mojo tracks each
    # origin independently and keeps it alive for the duration of the call
    # (the origin-guard idiom — no Int laundering, no wildcard
    # origin, no manual keepalive).
    # ------------------------------------------------------------------
    var builder = RecordBatchBuilder()
    var sb = SchemaBuilder()

    # --- Gather left-side columns ---
    for c in range(left.num_columns()):
        emit_gather_column_projected_dispatch[has_pool, D, disp_o](
            left,
            c,
            output_schema.field_name(c),
            left_nullable,
            left_indices,
            count,
            dispatcher_ptr,
            builder,
            sb,
            index_lo,
            gather_parallel_min_rows=gather_parallel_min_rows,
            offset_promote_at=offset_promote_at,
        )

    # --- Gather right-side columns ---
    #
    # JOIN-KEY CSE. When `key_alias_of_right[c] >= 0`, right column `c` is the
    # equi-join partner of left column `key_alias_of_right[c]`, so on EVERY
    # emitted row the two hold the same value — that is what the join condition
    # means. The left column has already been materialized into `builder` at
    # slot `alias` by the loop above, so the second output column is an
    # Arc-SHARE of it and the gather is DELETED, not moved.
    #
    # ⚠ THE MAP IS NOT RE-DERIVED HERE. Its proof lives in `join_key_cse`
    # (join type, key pairing, type equality, the null-freedom and physical-
    # shape gates, and the FLOAT / DECIMAL / DICTIONARY refusals). What IS
    # re-stated here is the one precondition this frame can check for itself:
    # aliasing is applied only when NEITHER side is nullable. A nullable side
    # means `-1` sentinels in its index list, i.e. an OUTER join, where the two
    # key columns differ precisely on the rows that make it an outer join. A
    # caller that hands a map to an outer assemble gets the plain gather, not a
    # wrong answer.
    #
    # ⚠ THE COUNTERS ARE ACCUMULATED IN LOCALS AND FLUSHED ONCE PER ASSEMBLE,
    # never per column. The streaming probe calls this once per morsel, so a
    # per-column atomic multiplies into tens of thousands of increments per
    # query -- a cost small enough to hide under a timing noise floor.
    # Batching gives at most FOUR relaxed `fetch_add`s per assemble, the same
    # cost profile as `join_index_window_counter`, and changes no reported
    # total.
    var left_ncols = left.num_columns()
    var cse_on = (
        key_alias_of_right.__bool__()
        and not left_nullable
        and not right_nullable
    )
    var _cse_shared_cols = 0
    var _cse_shared_bytes = 0
    var _cse_gathered_cols = 0

    for c in range(right.num_columns()):
        var out_idx = left_ncols + c
        if out_idx >= output_schema.num_columns():
            break
        var alias_idx = -1
        if cse_on:
            # `alias_of` is TOTAL: an out-of-range build column reads -1, so a
            # map/schema length disagreement degrades to the plain gather. The
            # bounds check lives with the data.
            alias_idx = key_alias_of_right.value().alias_of(c)
        if alias_idx >= 0 and alias_idx < builder.num_columns():
            # The field is derived from the RIGHT source column, exactly as the
            # gather below would have derived it — NOT from the shared column —
            # so the emitted schema is independent of the lever.
            ref rsrc = right.column_at(c)
            var shared = builder.share_column(alias_idx)
            sb.add_field(
                Field(
                    output_schema.field_name(out_idx),
                    rsrc.arrow_type,
                    rsrc._validity.__bool__() or right_nullable,
                )
            )
            _cse_shared_cols += 1
            _cse_shared_bytes += shared._data.len()
            builder.add_column(shared^)
            continue
        # ⛔ A RIGHT-SIDE GATHER NEEDS A RIGHT-SIDE INDEX, AND SOME CALLERS
        # LEGITIMATELY PASS A SHORT ONE. This frame's own contract allows
        # `right_indices` shorter than `left_indices` when `right` contributes
        # no gathered output column (e.g. every build column is shared by the
        # JOIN-KEY CSE). Reaching the gather with a short list is not a bounds
        # trap -- `emit_gather_column_projected` walks the list on a raw
        # pointer, so it would read whatever the allocator last left there and
        # use it as a SOURCE ROW. A wrong answer with a correct row count, a
        # correct schema and a clean bitmap, which no value oracle can see.
        #
        # ⚠ ONE COMPARISON PER GATHERED BUILD COLUMN -- not per row, and not on
        # the shared columns, which `continue` above.
        if len(right_indices) < index_lo + count:
            raise Error(
                "assemble_join_result_dispatch: build column "
                + String(c)
                + " must be GATHERED but the right index list holds only "
                + String(len(right_indices))
                + " of the "
                + String(index_lo + count)
                + " entries the window needs"
            )
        _cse_gathered_cols += 1
        emit_gather_column_projected_dispatch[has_pool, D, disp_o](
            right,
            c,
            output_schema.field_name(out_idx),
            right_nullable,
            right_indices,
            count,
            dispatcher_ptr,
            builder,
            sb,
            index_lo,
            gather_parallel_min_rows=gather_parallel_min_rows,
            offset_promote_at=offset_promote_at,
        )

    # ONE flush per assemble. Zero-guarded so an assemble with no build-side
    # output columns (a projected shape, a count-only) touches no atomic at all.
    if _cse_shared_cols > 0:
        join_key_cse_note_shares(_cse_shared_cols, _cse_shared_bytes)
    if _cse_gathered_cols > 0:
        join_key_cse_note_gathers(_cse_gathered_cols)

    var schema = sb.build()
    return builder.build(schema^)

