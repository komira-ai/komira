# =============================================================================
# Paginated materialize result types
# =============================================================================
#
# These are the EAGER-materialize-then-chunk types: they run the WHOLE query to
# completion and then hand the single result out in pages. They are NOT the
# first-class streaming surface (the `StreamingMorselSource` /
# `StreamingMorselSink` traits and the streaming job handle). Names starting
# `Stream*` are reserved for that work: an eager run never terminates on an
# unbounded input, so a type that looks like a stream but runs eagerly is a
# landmine.
#
# Two pure-data types live here (NO EngineContext dependency: this module sits
# BELOW the session context in the import graph so EngineContext can carry a
# `Slab[Optional[PaginatedState]]` field):
#
#   * `PaginatedResult` -- the value the user holds. Opaque `_stream_id` +
#     a cached `_exhausted` hint. Movable + Copyable so users can pass it
#     freely. ALL mutable cursor state lives ctx-side in `PaginatedState`; a
#     handle holds no context back-reference.
#
#   * `PaginatedState` -- ctx-side per-page state. Holds the eager-materialized
#     result, already pre-chunked into `rows_per_batch`-sized RecordBatches
#     (eager-materialize-then-chunk; true on-demand streaming is a separate
#     substrate, NOT this module). Carries the cursor + the pinned Layer-2
#     resolved cache idx so LRU eviction can skip in-flight paginated results.
#
# The for-loop ergonomics wrapper `PaginatedIter[origin]` and the
# `iterate_paginated` free function live in a separate module (they DO depend
# on EngineContext, so they sit ABOVE the session context to avoid the import
# cycle).
#
# Prior art:
#   * DuckDB `StreamQueryResult`: holds a shared client context and a
#     buffered result; its fetch returns the next data chunk or null at
#     end-of-stream, and close releases. The cursor lives ctx-side. Here that maps onto `ctx.advance_paginated(p) ->
#     Optional[RecordBatch]` with page-state ctx-side and
#     `close_paginated`/exhaustion releasing the pin.
#   * DataFusion `SendableRecordBatchStream`: a `Stream<Item =
#     Result<RecordBatch>>` that also knows its schema; once a stream returns
#     an error / EOF, do not poll it again. Maps to the `_exhausted` flag.
#
# Concurrency: NOT thread-safe. Paginated results are advanced only from the
# EngineContext-owning thread (same SERIAL invariant as the plan-compile
# path / `_parquet_stats_cache` / `_scan_dedup_cache`).
# =============================================================================

from komira_arrow.record_batch import RecordBatch
from komira_collections.slab import Slab
from komira_column_kernels.batch_slice import _slice_batch_range


# -----------------------------------------------------------------------------
# Stream-registry capacity cap
# -----------------------------------------------------------------------------

comptime PAGINATED_REGISTRY_CAP: Int = 64
"""Maximum number of concurrently-open paginated results per EngineContext.

Matches the Layer-2 resolved-cache cap (64): every open paginated result
pins a resolved-cache entry, so over-capacity results would force-pin the
whole Layer-2 cache. `materialize_paginated` raises when this cap would be
exceeded (this bounds the leak surface for a user who drops a PaginatedResult
without exhausting it / calling `close_paginated`).
"""


# -----------------------------------------------------------------------------
# PaginatedResult — the value the user holds
# -----------------------------------------------------------------------------


@fieldwise_init
struct PaginatedResult(Movable, Copyable, Deinitable):
    """Handle to an in-flight paginated materialization.

    Caller-managed iteration,
    NO ctx back-reference. Carries only an opaque `_stream_id` (the slab
    index into `EngineContext._paginated`) and a cached `_exhausted` hint.
    All mutable cursor state lives on the ctx side in `PaginatedState`.

    User invokes `ctx.advance_paginated(p)` per batch — the cursor
    advances on the ctx side because `ctx` is `mut self` at the call site
    (matches DuckDB's `StreamQueryResult` fetch, which locks the
    ClientContext to fetch the next chunk).

    `_exhausted` is a non-authoritative HINT: it is only ever set on the
    user's copy if they round-trip through a `PaginatedIter` (which copies
    the handle and updates its local copy). The authoritative end-of-pages
    signal is `advance_paginated` returning `None`, or
    `ctx.paginated_has_next` returning `False`. Movable + Copyable so users
    can stash it freely.
    """

    var _stream_id: UInt64
    var _exhausted: Bool

    @always_inline
    def stream_id(self) -> UInt64:
        """The opaque page-result id (slab index into `EngineContext._paginated`)."""
        return self._stream_id

    @always_inline
    def is_exhausted_hint(self) -> Bool:
        """Cached end-of-stream hint (non-authoritative — see struct doc)."""
        return self._exhausted


# -----------------------------------------------------------------------------
# PaginatedState — ctx-side per-page state
# -----------------------------------------------------------------------------


struct PaginatedState(Movable, Deinitable):
    """Ctx-side state for one open paginated result.

    Eager-materialize-then-chunk: `materialize_paginated`
    runs the full query to completion (reusing the existing materialize
    path), then pre-chunks the single result RecordBatch into a list of
    `rows_per_batch`-sized RecordBatches (via `_slice_batch_range`). The
    cursor (`_cursor`) walks that list; `next_batch()` pops the next chunk
    or returns `None` at end.

    Pinning interaction: `_resolved_idx` is
    the Layer-2 resolved-cache slab index this result pins (`ref_count > 0`).
    The LRU eviction policy skips pinned entries, so a concurrent
    `materialize` call that overflows the Layer-2 cache cannot evict a
    resolved plan a live paginated result is holding. `_resolved_idx == -1`
    means "no pin" (e.g. the resolved cache wasn't populated for this plan).
    The pin is released when the result is
    exhausted or `close_paginated` is called — the EngineContext does the
    `unpin_resolved` then; `PaginatedState.__del__` is a no-op w.r.t. the
    pin (it has no ctx reference, by design).

    NOT Copyable (holds a `Slab[RecordBatch]`). Stored ctx-side in a
    `Slab[Optional[PaginatedState]]` so closed slots can be set to `None`
    without shifting other results' ids.

    Internal layout note: `_chunks_rev` holds the result chunks in REVERSE
    order, so `next_batch()` is a cheap `Slab.pop()` (pop-from-end) that
    properly shrinks the slab (no O(n) left-shift, no moved-out-slot
    double-drop hazard). `RecordBatch` is not `Copyable`, so a Slab (whose
    element bound is just `Movable & Deinitable`) is used —
    `List[RecordBatch]` would not type-check. `_yielded` tracks how many
    chunks have been handed out, purely for diagnostics / accessors.
    """

    var _chunks_rev: Slab[RecordBatch]
    var _yielded: Int
    var _resolved_idx: Int

    def __init__(
        out self, var chunks: Slab[RecordBatch], resolved_idx: Int
    ):
        # Store reversed so `next_batch` is `pop()` from the end (= front
        # of the user-visible order).
        var rev = Slab[RecordBatch]()
        var n = chunks.len()
        for _i in range(n):
            var popped = chunks.pop()
            rev.append(popped.take())
        self._chunks_rev = rev^
        self._yielded = 0
        self._resolved_idx = resolved_idx

    @always_inline
    def resolved_idx(self) -> Int:
        """Layer-2 resolved-cache slab idx pinned by this stream (-1 = none)."""
        return self._resolved_idx

    @always_inline
    def remaining_chunks(self) -> Int:
        return self._chunks_rev.len()

    @always_inline
    def yielded_chunks(self) -> Int:
        return self._yielded

    @always_inline
    def has_next(self) -> Bool:
        return self._chunks_rev.len() > 0

    def next_batch(mut self) raises -> Optional[RecordBatch]:
        """Return the next chunk and advance the cursor, or `None` at EOF.

        Hands out an OWNED RecordBatch each call (popped from the internal
        reversed slab — `Slab.pop()` shrinks the slab, so the moved-out
        chunk is never double-dropped). After the last chunk, every
        subsequent call returns `None`.
        """
        if self._chunks_rev.len() == 0:
            return Optional[RecordBatch](None)
        var out = self._chunks_rev.pop()
        self._yielded += 1
        # `out` is Some here (len > 0 above) — `Slab.pop` already returns
        # `Optional[RecordBatch]`, so just forward it.
        return out^


# -----------------------------------------------------------------------------
# _chunk_record_batch — eager-materialize-then-chunk (Option (b))
# -----------------------------------------------------------------------------


def _chunk_record_batch(
    var batch: RecordBatch, rows_per_batch: Int
) raises -> Slab[RecordBatch]:
    """Split `batch` into a slab of `rows_per_batch`-sized RecordBatches.

    The last chunk holds the remainder (`num_rows % rows_per_batch` rows,
    or `rows_per_batch` if it divides evenly). A 0-row input produces a
    single 0-row chunk (so a downstream consumer always sees ≥ 1 batch,
    matching DuckDB's "empty result still has a schema" contract).

    Uses `_slice_batch_range` (contiguous-memcpy column slicing) — O(cols *
    total_rows * elem_size) overall, the same cost as one full copy. A
    `Slab` (not a `List`) holds the chunks because `RecordBatch` is not
    `Copyable`.

    `rows_per_batch` MUST be > 0 (caller validates).
    """
    var chunks = Slab[RecordBatch]()
    var total = batch.num_rows()
    if total <= 0:
        # Preserve the schema with a single empty chunk.
        chunks.append(_slice_batch_range(batch, 0, 0))
        return chunks^
    var start = 0
    while start < total:
        var length = rows_per_batch
        if start + length > total:
            length = total - start
        chunks.append(_slice_batch_range(batch, start, length))
        start += length
    return chunks^
