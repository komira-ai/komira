# =============================================================================
# SharedChunkWork — the per-chunk work-unit trait for
# `parallel_fork_join_shared`.
#
# This is a CLEAN LEAF — it has ZERO imports — and it lives in `komira_core`
# because the shared-payload fork-join DRIVER lives in
# `komira_concurrency/fork_join_shared.mojo`, so that
# `komira_column_kernels/compiler_helpers.mojo.gather_batch` — the stage-4 gather of
# every ORDER BY — can dispatch onto the engine's own runtime without core
# taking an up-edge to `komira_async`.
#
# The SHARED-PAYLOAD sibling of `ChunkWork` / `parallel_fork_join`.
#
# `ChunkWork` fits the "each chunk PRODUCES an owned output `O`" shape (the
# driver fans the per-chunk `Optional[O]` slots in afterwards). A large family
# of kernels — every phase of the parallel SORT family — has the OTHER shape:
# one pre-sized destination buffer that all chunks write DISJOINT slices of
# (a permutation, a scratch band, a per-worker histogram band). Routing those
# through `ChunkWork` would force an extra full-width copy of the destination
# per phase, so they get their own trait: the whole mutable destination is
# passed to every chunk as `mut payload: P`, and DISJOINTNESS of the writes is
# the call site's contract — exactly the contract the hand-written
# `parallelize` bodies carry, and the same one the tiled streaming concat
# documents for its shared fixed-width buffers.
#
# `In` and `P` are method-level parameters (Mojo traits have no associated
# types); both resolve at the
# `parallel_fork_join_shared[W, In, P, ...]` call site.

# =============================================================================


trait SharedChunkWork(Copyable, Movable, Deinitable):
    """Per-chunk work unit for `parallel_fork_join_shared`.

    `process(chunk_id, n_chunks, input, payload)` is invoked once per chunk id
    in [0, n_chunks). It reads `input` (borrowed read-only, shared by every
    chunk) and mutates `payload` — the ONE shared, driver-owned destination —
    at the slots that belong to chunk `chunk_id`.

    THE CALL-SITE CONTRACT (identical to a hand-written parallelize body's):
      * Disjointness — chunk `c` must write ONLY slots no other chunk writes.
        The `mut payload` reference is aliased across the concurrent chunks by
        construction; the type system cannot police which slots each chunk
        touches, so the call site must document the tiling in a
        DISPATCH-BOUNDARY SAFETY block.
      * No-realloc — `payload`'s containers must be pre-sized by the driver
        BEFORE the dispatch; chunks may only `setitem` live slots, never
        append/resize (a realloc would move the buffer under a peer chunk).
    """

    def process[
        In: Deinitable, P: Movable & Deinitable
    ](
        self,
        chunk_id: Int,
        n_chunks: Int,
        ref input: In,
        mut payload: P,
    ) raises:
        ...
