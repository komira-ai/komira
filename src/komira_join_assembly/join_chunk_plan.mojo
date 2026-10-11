# =============================================================================
# join_chunk_plan — BYTE-BUDGETED output-chunk boundaries for a join assemble
# =============================================================================
#
# WHY THIS EXISTS
# ---------------
# `Column` is a FLAT single-buffer Arrow array whose STRING offsets are
# **Int32**. One output column therefore cannot address more than
# `ARROW_INT32_OFFSET_LIMIT` = 2,147,483,647 bytes of packed UTF-8.
#
# An inner join over a wide string key can produce an output column of more
# than 2 GiB of packed UTF-8 -- over the ceiling -- which a single flat column
# cannot address. This module computes
# where to CUT the output so each chunk's per-column byte total fits, which is
# what lets the join emit `List[RecordBatch]` instead of failing.
#
# THE BUDGET IS IN BYTES, NOT ROWS — read this before "simplifying" it
# ---------------------------------------------------------------------
# A row constant is fixture-local: bytes per row are a property of the data,
# not of the shape. A join over 8-byte keys and one over 512-byte keys need
# chunk sizes 64x apart. Worse, an AVERAGE-derived row count is not even safe
# on one input -- string lengths are skewed, so a chunk sized at the mean can
# overshoot.
#
# So the planner walks the ACTUAL gathered indices and accumulates the EXACT
# per-column byte cost, cutting when any single output column would cross the
# budget. That is O(rows x string-columns) of pure int32 offset subtraction —
# negligible against the multi-GB gather it guards, and skew-proof by
# construction.
#
# WHICH COLUMNS ARE PRICED
# ------------------------
# Only PLAIN int32-offset STRING columns (`Column.is_plain_string()`), because
# only those can overflow:
#   * fixed-width columns have no offsets buffer at all;
#   * DICTIONARY columns are gathered as CODES with the dictionary SHARED
#     (the gather in `compiler_helpers` copies the dict's own offsets buffer, sized by `_dict_size`, the DISTINCT count), so their
#     output offsets are bounded by cardinality and not by the output row count;
#   * LARGE_STRING carries int64 offsets and has no 2 GiB ceiling.
# Pricing a column that cannot overflow would only over-chunk (harmless but
# wasteful); MISSING one that can would reintroduce the bug, so the predicate
# lives on `Column` next to the layout it tests, not here.
#
# ⚠ THIS MODULE COMPUTES BOUNDARIES. IT DOES NOT COPY INDEX LISTS.
# ----------------------------------------------------------------
# The assemble BORROWS its index lists, so the chunked terminal passes the
# originals plus an `(index_lo, index_count)` window and copies nothing. A
# per-chunk copy of each side's index list would be pure chunking tax on the
# driver thread, because the gather reads the same bytes either way, just from
# the original allocation.
#
# DO NOT ADD A PER-CHUNK COPY. The window's range validation lives in
# `assemble_join_result_dispatch`, where the window enters. The output is
# byte-identical either way, so only the join index-window counter
# (`join_index_window_counter`) can tell the two apart.
# =============================================================================

from std.collections import List
from std.memory import UnsafePointer

from komira_async_api.fork_join_shared import fork_join_shared
from komira_async_api.parallel_dispatch import NoDispatch, ParallelDispatch
from komira_async_api.sched_sites import SITE_JOIN_CHUNK_PRICE
from komira_async_api.shared_chunk_work import SharedChunkWork
from komira_async_api.token import CancellationToken

from komira_arrow.schema import RecordBatch
from komira_arrow.column import Column
from komira_arrow.offset_overflow import ARROW_INT64_OFFSET_MAX
from komira_buffer.heap_region import HeapRegion

# The Arrow spec's int32 offset ceiling: `offsets[N]` must fit in an Int32, so a
# single string/binary column addresses at most this many data bytes.
comptime ARROW_INT32_OFFSET_LIMIT: Int = 2147483647

# Default per-column chunk budget: 1 GiB. Deliberately ~2x under the ceiling
# rather than just under it, because the planner prices the SOURCE bytes each
# output row copies and a caller may add columns (e.g. an outer-join null
# sentinel expands nothing, but a future projected arm could reorder). At 1 GiB
# a 2.35 GB string column lands in 3 chunks.
comptime DEFAULT_JOIN_CHUNK_BUDGET_BYTES: Int = 1 << 30

# =============================================================================
# Why the pricing pass forks.
# =============================================================================
#
# The byte-pricing loop costs a few dozen instructions per priced column per
# output row. On a join emitting tens of millions of rows that is billions of
# instructions of real work on ONE thread, between the last probe fork and the
# first gather fork, with every pool worker idle. The IDENTICAL quantity
# (`offsets[col_offset+idx+1] - offsets[col_offset+idx]` per output row) is
# already computed in parallel by the gather's length pass
# (`compiler_helpers._GatherStrLenWork`), so it is serial because nothing was
# dispatched, not by necessity.
#
# THE ALGORITHM, AND WHY IT IS EXACTLY EQUIVALENT.
# The cut decision is a running total that RESETS at each cut, so it cannot be
# parallelised directly. But it can be SKIPPED in bulk:
#
#   PHASE 1 (parallel, one wave per priced column): tile [0, n) into `n_tiles`
#   contiguous ranges and compute each tile's TOTAL bytes for that column.
#   O(n) work spread over the pool; O(n_tiles x n_priced) memory — a few KB, NOT
#   the hundreds of MB a per-output-row length array would cost.
#
#   PHASE 2 (serial, cheap): walk the tiles. If `running[p] + tile_total[p][t]
#   <= budget` for EVERY priced column p, then no cut can occur anywhere inside
#   tile t — because the per-row running total is monotone nondecreasing within
#   a chunk and is bounded above by that sum. So the whole tile is ABSORBED in
#   O(n_priced), and the serial pass never touches its rows. Otherwise the tile
#   is DESCENDED with the original per-row body (`_price_rows_serial`).
#
# The fallback makes the SAME per-row decisions in the SAME order as the
# untiled serial planner, so the bounds this returns are BIT-IDENTICAL to it
# for every input — not merely "a valid partition". That is the property
# `test_tiled_pricing_matches_the_serial_oracle` pins, and it is why the fast
# path can be aggressive: being wrong about "this tile fits" is impossible (the
# predicate is a sound over-approximation), and being conservative only costs a
# descent.
#
# Both phases read through `_ResolvedCol.byte_len_at` over a per-column value
# resolved ONCE (a pure loop-invariant hoist: same operands, same order, same
# branches, same `-1` guard), so the fast path and its fallback share one
# definition of the arithmetic.
#
# At a 1 GiB budget a 2.35 GB column cuts into 3 chunks, so at most 3 tiles
# are ever descended.

# Tiles per worker for the pricing wave. > 1 on purpose, for two reasons:
# (a) load balance — `fork_join_shared` hands chunk `c` to shard `c % nw`, and
#     tiles are equal in ROWS but not in BYTES on a skewed fixture;
# (b) descent cost — a cut lands inside exactly one tile, and that tile's rows
#     are re-priced serially. Smaller tiles shrink the serial residue directly.
comptime _JOIN_PRICE_TILES_PER_WORKER: Int = 4

# Below this many output rows the pricing pass stays on ONE tile and runs the
# original serial loop with no fork at all. A fork-join barrier costs more than
# pricing a few thousand rows, so small inputs run the serial loop's exact
# instructions.
comptime _JOIN_PRICE_MIN_PARALLEL_ROWS: Int = 1 << 16


@always_inline
def _budget_can_bind(budget_bytes: Int) -> Bool:
    """Can `budget_bytes` cut ANY chunk, over ANY input? O(1), no data read.

    ⭐ THE WHOLE PRICING PASS IS O(output rows x priced STRING columns), and it
    exists to answer ONE question: *where does a running per-column byte total
    first cross `budget_bytes`?* When no reachable total can cross it, every
    cut test in that walk is FALSE BY CONSTRUCTION and the answer is a single
    chunk — so the walk is every output row's arithmetic spent deriving
    `[0, n]`.

    TWO WAYS A BUDGET CANNOT BIND, and they are the two ENDS of the range:

      * `<= 0` — the caller's explicit UNLIMITED. This is how the chunked
        terminal reproduces the exact single-batch behaviour of the unchunked
        one.
      * `>= ARROW_INT64_OFFSET_MAX` — an UNREACHABLE ceiling. That is ~9.2
        exabytes; a per-column total is a count of bytes in a buffer that is
        RESIDENT, so nothing that can be allocated reaches it. Unlike the
        int32 ceiling it is *"of a different kind"* (`offset_overflow.mojo`) —
        it is not crossed in production, ever.

    ⚠ WHY THE SECOND FORM HAS TO EXIST SEPARATELY FROM THE FIRST, WHICH IS THE
    ONLY SUBTLE THING HERE. They are NOT interchangeable at the call site.
    `materialize_composite_join_over_batches_chunked` routes
    `chunk_budget_bytes <= 0` to a DIFFERENT LEAF entirely
    (`materialize_composite_join_over_batches`, wrapped in a one-element list),
    so a caller that wants *"this leaf, but stop pricing"* cannot say it with a
    0 — a 0 also says *"take the other leaf"*, and a lever built on it would be
    a route change (which can move wall time a lot with byte-identical output)
    reported as a pricing win. A POSITIVE-but-unreachable
    budget says exactly one thing, and it is the thing meant.

    ⚠ AND IT IS NOT A TOLERANCE. This does not widen a budget, skip a cut that
    was due, or approximate anything: it recognises the case where the exact
    walk's own answer is already known. The oracle test
    (`test_tiled_pricing_matches_the_serial_oracle`) compares against the
    per-row planner, and at an unreachable budget that planner returns `[0, n]`
    too — `chunk_rows > 0 and running[p] + nbytes > budget_bytes` cannot be
    true when `budget_bytes` exceeds every attainable `running[p] + nbytes`.

    Args:
        budget_bytes: The per-column ceiling the caller asked for.

    Returns:
        True if some input could make this budget cut; False if none can.
    """
    return budget_bytes > 0 and budget_bytes < ARROW_INT64_OFFSET_MAX


struct _PricedCol(Copyable, Movable):
    """One plain-STRING source column that participates in the byte budget.

    `from_left` selects which index list addresses it, `col` is the source
    column ordinal on that side, and `slot` is its position in THAT SIDE's
    resolved-column list (see `_ResolvedCol`). Kept as a tiny POD so the hot
    loop indexes a `List[_PricedCol]` rather than re-deriving types per row."""

    var from_left: Bool
    var col: Int
    var slot: Int

    def __init__(out self, from_left: Bool, col: Int, slot: Int = 0):
        self.from_left = from_left
        self.col = col
        self.slot = slot


def _collect_priced_cols(
    ref left: RecordBatch, ref right: RecordBatch
) raises -> List[_PricedCol]:
    """Enumerate the plain-STRING columns of both sides, left-side first.

    Mirrors the composite join's FULL-output column order
    (`_mk_build_composite_join_output_schema`: every left column, then every
    right column with a `_right` suffix on collision) — but the ORDER is
    irrelevant to the budget, only membership is. Each priced column gets its
    own running total because the Arrow limit is PER COLUMN, not per row.

    `slot` is assigned here, per side, in emission order — it is the index the
    matching `_ResolvedCol` will occupy in that side's resolved list, and the
    two are built from this ONE enumeration so they cannot disagree."""
    var out = List[_PricedCol]()
    var nl = 0
    var nr = 0
    for c in range(left.num_columns()):
        if left.column_at(c).is_plain_string():
            out.append(_PricedCol(True, c, nl))
            nl += 1
    for c in range(right.num_columns()):
        if right.column_at(c).is_plain_string():
            out.append(_PricedCol(False, c, nr))
            nr += 1
    return out^


@fieldwise_init
struct _ResolvedCol[o_off: ImmOrigin](ImplicitlyCopyable, Copyable, Movable):
    """One priced column's offsets buffer + slice base, resolved ONCE.

    ★ THE HOIST IS THE WHOLE POINT. Reached through `batch.column_at(col)`
    per descended row, each priced column's byte read re-derives several
    loop-invariants every time: the RecordBatch column-list base, the Column
    stride multiply, the `Optional[_offsets]` discriminant AND its per-row
    raise edge, the `_offset` add and the offsets base load -- a 3-deep
    dependent load chain (stack -> RecordBatch -> column list -> offsets).
    This POD holds the two values those compute, resolved once per column per
    call, so the descent's body collapses to the same two `movslq` + `sub` the
    parallel wave's worker runs, over a 2-deep chain (stack -> resolved list
    -> offsets).

    ⚠ `col_offset` IS NOT OPTIONAL. It is the column's `_offset`; dropping it
    prices rows [0, n) of the buffer instead of [_offset, _offset + n) — an
    offset-blind read, which produces a plausible wrong answer rather than a
    crash. It is also the
    ONE direction that can UNDER-count and so cause a wrong fast-absorb.
    Falsified by `test_tiled_pricing_honors_the_column_slice_base` (whose
    `force_price_tiles=1` oracle arm is the DESCENT) and by
    `test_descent_reads_through_the_resolved_column`.
    """

    # SAFETY: raw offsets pointer with a CONCRETE origin pinned to the borrowed
    # source batch (`view_ro()._unsafe_ptr()` carries the origin of the
    # underlying `_offsets` BUFFER, not of the view local). Read-only; never
    # escapes this module.
    var off_ptr: UnsafePointer[Scalar[DType.int32], Self.o_off]
    var col_offset: Int

    @always_inline
    def byte_len_at(self, idx: Int) -> Int:
        """Source UTF-8 byte length of row `idx` — `Column.string_byte_length_at`
        with the per-call-invariant part already resolved away.

        THE ONE DEFINITION OF THE PRICING ARITHMETIC. Both phases read through
        it (`_TilePriceWork.process` in parallel, `_price_rows_serial` in the
        descent), so the fast path and the fallback cannot drift — which is
        exactly what "the tiled bounds are BIT-IDENTICAL to the serial oracle"
        depends on.

        Precondition: `0 <= col_offset + idx` and `col_offset + idx + 1` within
        the offsets buffer. Callers MUST reject the `-1` outer-join sentinel
        BEFORE calling (see the guard notes on `_TilePriceWork`)."""
        var row = self.col_offset + idx
        var start = Int((self.off_ptr + row)[])
        var end = Int((self.off_ptr + row + 1)[])
        return end - start


def _resolve_priced_cols[
    o: ImmOrigin, //,
](
    ref [o] batch: RecordBatch, imm cols: List[Int]
) raises -> List[_ResolvedCol[o]]:
    """Resolve each of `cols`' offsets buffer + slice base ONCE.

    This is where the `Optional[_offsets]` discriminant is tested and where the
    RAISE for a column that has no offsets buffer lives. Reading per row
    through `Column.string_byte_length_at` would test it INSIDE the loop
    (`_offsets.value()` -> abort edge); hoisting it moves a fail-loud out of
    the loop, so it is made EXPLICIT here rather than left implicit in `.value()` — a caller that hands
    this a non-plain-STRING column must still fail loudly and not silently price
    garbage. `test_resolve_refuses_a_column_with_no_offsets` pins it.

    The precondition holds by construction for the planner: `_collect_priced_cols`
    admits a column only if `is_plain_string()`, which requires `Bool(_offsets)`.
    """
    var out = List[_ResolvedCol[o]](capacity=len(cols))
    for i in range(len(cols)):
        ref c = batch.column_at(cols[i])
        if not c.is_plain_string():
            raise Error(
                "join_chunk_plan: column "
                + String(cols[i])
                + " is not a plain int32-offset STRING column and cannot be"
                " byte-priced (no offsets buffer to read)"
            )
        var off_view = c._offsets.value().view_ro()
        # SAFETY / ORIGIN. `view_ro()._unsafe_ptr()` is typed at the origin of
        # the offsets buffer as reached through this batch — the compiler spells
        # it `origin_of(batch._columns._bytes._offsets._value)`, a projection
        # that CANNOT be written in a return type, which is why the pointer is
        # restated at `o` (the borrow of `batch` itself) here. This is a WIDENING
        # to the enclosing borrow, not a wildcard and not an erasure: `o` is a
        # concrete tracked origin, and the buffer is reachable only THROUGH
        # `batch`, so "valid while the `batch` borrow is live" is the true bound
        # — the same restatement `SharedAlignedBuffer.view_ro` performs one level
        # down. The `_ResolvedCol`s therefore cannot outlive `batch`, which is
        # what makes it safe for the phase-1 wave to read them across a
        # fork-join barrier the driver joins before returning.
        var off_ptr = (
            off_view._unsafe_ptr()
            .bitcast[Scalar[DType.int32]]()
            .unsafe_origin_cast[o]()
        )
        out.append(_ResolvedCol[o](off_ptr, c._offset))
        # ⚠ NOT A KEEPALIVE. The ORIGIN is what
        # keeps the pointer valid past this local: `view_ro()._unsafe_ptr()`
        # carries the origin of the underlying `_offsets` BUFFER, pinned to the
        # borrowed `batch`, which outlives every use. This line only marks the
        # local as deliberately unused after the pointer extraction.
        _ = off_view
    return out^


@fieldwise_init
struct _TilePriceWork[o_off: ImmOrigin](SharedChunkWork):
    """Phase-1 worker: tile `c` sums the source string bytes its output rows
    `[tile_lo[c], tile_lo[c+1])` will gather from ONE priced column, and writes
    that one total into `totals[c]`.

    THE ARITHMETIC IS `Column.string_byte_length_at` UNROLLED, not a variant of
    it: that accessor is `i = self._offset + row; offsets[i+1] - offsets[i]`,
    and `_ResolvedCol.col_offset` IS the column's `_offset`. Carrying it is not
    optional — omitting it is an offset-blind read, which on a SLICED column
    silently prices the wrong rows and produces a plausible-looking wrong
    answer (`test_offset_bearing_string_column_prices_the_right_rows` guards
    it). This loop and the serial DESCENT call the SAME
    `_ResolvedCol.byte_len_at`, so the fast path and its fallback cannot drift.

    THE `-1` OUTER-JOIN SENTINEL contributes ZERO and is skipped BEFORE the
    offsets read. Unlike `_GatherStrLenWork` this is unconditional (no
    `allow_null_sentinel` flag): the planner is only ever called with join index
    lists, which are exactly the lists that may carry `-1`.

    ⚠ WHAT THAT GUARD IS AND IS NOT FOR. It is an OUT-OF-BOUNDS-READ guard,
    NOT a wrong-answer guard, and no bounds-equality test can falsify its
    removal: deleting it leaves the suite GREEN. The reason is the one-directional soundness
    of the fast-absorb below:

      * Arrow offsets are non-decreasing, so `offsets[r+1] - offsets[r] >= 0`
        for any IN-BOUNDS `r`. Pricing a sentinel therefore only ever ADDS —
        the tile total comes out too BIG.
      * A too-big tile total can only fail the `fits` test, which sends the
        tile down the DESCENT — the original per-row code, which has its own
        `idx < 0` guard and gets the answer right. So an over-count costs
        parallelism and nothing else.
      * Only an UNDER-count can cause a wrong ABSORB, and that is what
        dropping `col_offset` does — which is why THAT mutation IS falsifiable
        (`test_tiled_pricing_honors_the_column_slice_base`) and removing the
        sentinel guard is not.

    So the guard earns its place on two grounds a value test cannot see:
    (1) with `col_offset == 0`, `row = -1` reads four bytes BEFORE the offsets
    buffer — a genuine OOB read whose result is unconstrained, which is also
    the one way a missing guard could under-count and go wrong, flakily rather
    than reproducibly; and (2) on an outer join with many sentinels it would
    push every tile into the descent and silently delete the parallelism this
    struct exists to provide. Do not remove it because "the tests still pass".

    DISPATCH-BOUNDARY SAFETY:
      * Disjointness: `tile_lo` tiles [0, n) exactly, so no two chunks read the
        same input range, and `totals[c]` is chunk `c`'s private slot. The
        source offsets buffer is READ-ONLY and shared.
      * Liveness: `src_off_ptr` carries the CONCRETE immutable origin of the
        caller's borrowed source column (no wildcard); `fork_join_shared`'s
        barrier joins every chunk before the driver returns, so the borrowed
        `RecordBatch` cannot have been dropped under a worker.
      * No-realloc: `totals` is pre-sized to `n_tiles` by the driver before the
        move; chunks only `setitem` live slots, never append.
    """

    # SAFETY: `_ResolvedCol` holds a raw source-offsets pointer with a CONCRETE
    # origin pinned to the caller's borrowed column. Read-only; never escapes
    # this module.
    var res: _ResolvedCol[Self.o_off]
    var tile_lo: List[Int]

    def process[
        In: Deinitable, P: Movable & Deinitable
    ](
        self, chunk_id: Int, n_chunks: Int, ref input: In, mut payload: P,
    ) raises:
        _ = n_chunks
        # SAFETY: the driver instantiates this with In=List[Int] (the caller's
        # borrowed index list) and P=List[Int] (the per-tile totals) at the one
        # dispatch site in `_run_tile_price_wave` below.
        var ip = UnsafePointer(to=input).bitcast[List[Int]]()
        var tp = UnsafePointer(to=payload).bitcast[List[Int]]()
        var idx_ptr = ip[].unsafe_ptr()
        var lo = self.tile_lo[chunk_id]
        var hi = self.tile_lo[chunk_id + 1]
        var acc = 0
        for i in range(lo, hi):
            var ix = (idx_ptr + i)[]
            if ix < 0:
                continue  # outer-join NULL: gathers no bytes
            acc += self.res.byte_len_at(ix)
        tp[][chunk_id] = acc


def _run_tile_price_wave[
    o_off: ImmOrigin,
    has_pool: Bool,
    D: ParallelDispatch,
    disp_o: Origin[mut=True],
](
    imm res: _ResolvedCol[o_off],
    imm indices: List[Int],
    var tile_lo: List[Int],
    n_tiles: Int,
    dispatcher_ptr: Optional[Pointer[D, disp_o]],
) raises -> List[Int]:
    """Phase 1 for ONE priced column: per-tile source-byte totals.

    Thin by design, exactly as `_run_gather_len_wave` is: `o_off` has to be
    INFERRED from `res` (it is the origin of the borrowed source batch, restated
    by `_resolve_priced_cols`; see the SAFETY block there), while `has_pool` /
    `D` / `disp_o` arrive by keyword. No wildcard origin."""
    var totals = List[Int](capacity=n_tiles)
    for _ in range(n_tiles):
        totals.append(0)
    var work = _TilePriceWork[o_off](res, tile_lo^)
    return fork_join_shared[
        _TilePriceWork[o_off],
        List[Int],
        List[Int],
        origin_of(indices),
        D,
        has_pool=has_pool,
        disp_o=disp_o,
    ](
        work^,
        indices,
        totals^,
        n_tiles,
        2,
        0,
        dispatcher_ptr,
        CancellationToken.never(),
        SITE_JOIN_CHUNK_PRICE,
    )


def _price_rows_serial[
    o_l: ImmOrigin,
    o_r: ImmOrigin,
](
    imm priced: List[_PricedCol],
    imm lres: List[_ResolvedCol[o_l]],
    imm rres: List[_ResolvedCol[o_r]],
    imm left_indices: List[Int],
    imm right_indices: List[Int],
    budget_bytes: Int,
    tlo: Int,
    thi: Int,
    mut running: List[Int],
    mut chunk_rows: Int,
    mut bounds: List[Int],
) raises:
    """THE DESCENT — the exact per-row cut scan, over output rows [tlo, thi).

    This is the untiled planner's loop in EVERY decision it makes; its byte
    read goes through `_ResolvedCol.byte_len_at` on a per-column value
    resolved once by the caller rather than through
    `left.column_at(pc.col).string_byte_length_at`. That is a pure
    loop-invariant hoist: same operands, same order, same
    branches, so the bounds stay BIT-IDENTICAL — which is the property
    `test_tiled_pricing_matches_the_serial_oracle` pins (this function IS the
    oracle at `force_price_tiles=1`).

    ★ NOTE WHAT THIS SIGNATURE DOES NOT TAKE: `left` / `right`. The
    `RecordBatch`es are NOT in scope here, so a per-row re-derivation cannot
    silently come back — an edit that wants
    `column_at(...)` per row has to add a parameter, and
    `test_descent_reads_through_the_resolved_column` (which calls this with
    resolved columns and nothing else) stops compiling. The hoist is structural,
    not a convention, because a hoist that regresses is byte-identical on output
    and no value test would ever notice.
    """
    var np = len(priced)
    for r in range(tlo, thi):
        # Price row `r` against EVERY tracked column first, then decide, so a
        # single row that is itself over budget still makes progress (it becomes
        # a chunk of its own rather than looping forever). If that row's column
        # genuinely exceeds the Arrow ceiling on its own, the gather's own guard
        # raises — which is the correct fail-loud, not a silent wrap.
        var over = False
        for p in range(np):
            ref pc = priced[p]
            var idx = left_indices[r] if pc.from_left else right_indices[r]
            if idx < 0:
                continue  # outer-join NULL: gathers no bytes
            var nbytes: Int
            if pc.from_left:
                nbytes = lres[pc.slot].byte_len_at(idx)
            else:
                nbytes = rres[pc.slot].byte_len_at(idx)
            if chunk_rows > 0 and running[p] + nbytes > budget_bytes:
                over = True
                break
            running[p] += nbytes

        if over:
            bounds.append(r)
            chunk_rows = 0
            for p in range(np):
                running[p] = 0
            # Re-price row `r` as the first row of the NEW chunk. Not doing this
            # would drop its bytes from every total and let a later chunk creep
            # past the budget by one row's worth.
            for p in range(np):
                ref pc = priced[p]
                var idx = left_indices[r] if pc.from_left else right_indices[r]
                if idx < 0:
                    continue
                if pc.from_left:
                    running[p] += lres[pc.slot].byte_len_at(idx)
                else:
                    running[p] += rres[pc.slot].byte_len_at(idx)
        chunk_rows += 1


def join_output_chunk_bounds[
    has_pool: Bool = False,
    D: ParallelDispatch = NoDispatch,
    disp_o: Origin[mut=True] = MutAnyOrigin,
](
    ref left: RecordBatch,
    ref right: RecordBatch,
    left_indices: List[Int],
    right_indices: List[Int],
    budget_bytes: Int = DEFAULT_JOIN_CHUNK_BUDGET_BYTES,
    dispatcher_ptr: Optional[Pointer[D, disp_o]] = Optional[
        Pointer[D, disp_o]
    ](None),
    nw: Int = 1,
    force_price_tiles: Int = 0,
) raises -> List[Int]:
    """Compute output-row CUT POINTS so each chunk's per-column string byte
    total stays within `budget_bytes`.

    Returns a list of boundaries `b` with `b[0] == 0`, `b[-1] == n_out`, and
    chunk `k` covering output rows `[b[k], b[k+1])`. There is ALWAYS at least
    one chunk (a 0-row result yields `[0, 0]`), so a caller can loop over
    `len(b) - 1` unconditionally and never lose the output schema.

    Args:
        left: Probe-side source batch (borrowed; not modified).
        right: Build-side source batch (borrowed; not modified).
        left_indices: Per-output-row source row on the left. `-1` (the outer-join
            null sentinel) contributes ZERO bytes — a null gathers no data.
        right_indices: Per-output-row source row on the right; same `-1` rule.
        budget_bytes: Per-column ceiling. A budget that CANNOT BIND — `<= 0`
            (the caller's explicit UNLIMITED) or `>= ARROW_INT64_OFFSET_MAX`
            (an unreachable ceiling) — returns a single chunk in O(1), without
            pricing a row. See `_budget_can_bind` for why the two spellings are
            NOT interchangeable at the call site. `<= 0` is how the chunked
            terminal reproduces the exact single-batch behaviour of the
            unchunked one.
        dispatcher_ptr: The caller's dispatcher, threaded to the PARALLEL
            per-tile pricing wave. `None` (the default) with `has_pool=False`
            prunes the dispatch entirely and prices inline — bit-identical
            results, no fork, which is what every unit test and every small
            join takes.
        nw: Worker count hint for tiling. Only read when the pricing wave runs.
        force_price_tiles: TEST HOOK — `> 0` pins the tile count instead of
            deriving it from `nw`, so the TILING SEAM logic can be exercised on
            the inline (`has_pool=False`) arm without standing up a pool. It
            cannot change the RESULT (see the equivalence argument at the top of
            this file); it only changes which rows the fast path skips.

    Returns:
        The cut points, ascending, first `0` and last `len(left_indices)`.

    Raises:
        Error if the two index lists disagree in length (a caller bug — the
        gather would silently truncate to the shorter one).
    """
    var n = len(left_indices)
    if len(right_indices) != n:
        raise Error(
            "join_output_chunk_bounds: index-list length mismatch left="
            + String(n)
            + " right="
            + String(len(right_indices))
            + " (both lists must carry one entry per OUTPUT row)"
        )

    var bounds = List[Int]()
    bounds.append(0)
    if n == 0 or not _budget_can_bind(budget_bytes):
        bounds.append(n)
        return bounds^

    var priced = _collect_priced_cols(left, right)
    if len(priced) == 0:
        # Nothing can overflow: no plain-STRING output column exists. One chunk,
        # byte-identical to the unchunked assemble.
        bounds.append(n)
        return bounds^

    var np = len(priced)
    var running = List[Int](capacity=np)
    for _ in range(np):
        running.append(0)

    # -------------------------------------------------------------------------
    # RESOLVE ONCE. Both phases (the parallel wave and the serial descent)
    # read source string lengths through these. Cost is O(n_priced) per call,
    # against the per-row re-derivation it removes from every priced column of
    # every DESCENDED ROW.
    # -------------------------------------------------------------------------
    var lcols = List[Int]()
    var rcols = List[Int]()
    for p in range(np):
        if priced[p].from_left:
            lcols.append(priced[p].col)
        else:
            rcols.append(priced[p].col)
    var lres = _resolve_priced_cols(left, lcols)
    var rres = _resolve_priced_cols(right, rcols)

    # -------------------------------------------------------------------------
    # TILING. `n_tiles == 1` is the serial shape exactly: no wave, no fork,
    # the per-row loop over [0, n). Everything below is layered ON that
    # loop rather than replacing it, which is what makes the results bit-
    # identical rather than merely equivalent.
    # -------------------------------------------------------------------------
    var n_tiles = 1
    if force_price_tiles > 0:
        n_tiles = min(force_price_tiles, n)
    elif has_pool and n >= _JOIN_PRICE_MIN_PARALLEL_ROWS:
        n_tiles = min(max(nw, 1) * _JOIN_PRICE_TILES_PER_WORKER, n)

    var tile_lo = List[Int](capacity=n_tiles + 1)
    for t in range(n_tiles + 1):
        tile_lo.append((t * n) // n_tiles)

    # PHASE 1 — per-tile byte totals, one wave per priced column. Skipped
    # entirely at `n_tiles == 1`, where every tile-fits test would be a
    # tautology over the whole input and would buy nothing.
    var tile_tot = List[List[Int]]()
    if n_tiles > 1:
        for p in range(np):
            ref pc = priced[p]
            if pc.from_left:
                tile_tot.append(
                    _run_tile_price_wave[
                        has_pool=has_pool, D=D, disp_o=disp_o
                    ](
                        lres[pc.slot],
                        left_indices,
                        tile_lo.copy(),
                        n_tiles,
                        dispatcher_ptr,
                    )
                )
            else:
                tile_tot.append(
                    _run_tile_price_wave[
                        has_pool=has_pool, D=D, disp_o=disp_o
                    ](
                        rres[pc.slot],
                        right_indices,
                        tile_lo.copy(),
                        n_tiles,
                        dispatcher_ptr,
                    )
                )

    # PHASE 2 — the serial cut scan, tile by tile.
    var chunk_rows = 0
    for t in range(n_tiles):
        var tlo = tile_lo[t]
        var thi = tile_lo[t + 1]
        if thi <= tlo:
            continue  # cov: unreachable n_tiles <= n makes every tile hold at least one row

        if n_tiles > 1:
            # FAST ABSORB. Sound because the per-row running total is monotone
            # nondecreasing within a chunk: if `running[p] + tile_total[p]` is
            # already within budget then EVERY per-row prefix of this tile is
            # too, so the `over` test below cannot fire anywhere inside it.
            # (The converse is not claimed — a tile that fails this test may
            # still contain no cut. It is then descended and the original code
            # decides, which is why the answer is unchanged either way.)
            var fits = True
            for p in range(np):
                if running[p] + tile_tot[p][t] > budget_bytes:
                    fits = False
                    break
            if fits:
                for p in range(np):
                    running[p] += tile_tot[p][t]
                chunk_rows += thi - tlo
                continue

        _price_rows_serial(
            priced,
            lres,
            rres,
            left_indices,
            right_indices,
            budget_bytes,
            tlo,
            thi,
            running,
            chunk_rows,
            bounds,
        )

    bounds.append(n)
    return bounds^
