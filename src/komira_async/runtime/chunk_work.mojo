# =============================================================================
# ChunkWork — the per-chunk work-unit trait for `parallel_fork_join`.
#
# Promoted from the poc_parallel_fork_join probe (3 GREEN POCs; never
# committed, so nothing in git recovers it) into production. The shared
# `parallel_fork_join` layer owns the
# State/Task/3-entry split + the destroy-recreate/gap7 safety contract ONCE so that
# call sites can't break it. A consumer implements ChunkWork with the
# per-chunk work it already does inside its hand-written parallelize body.
#
# This helper centralizes the fork-join safety contract.
# =============================================================================


trait ChunkWork(Copyable, Movable, Deinitable):
    """Per-chunk work unit for `parallel_fork_join`.

    `process(chunk_id, n_chunks, input, out_slot)` is invoked once per
    chunk id in [0, n_chunks). It reads `input` (borrowed read-only)
    and writes its result into `out_slot` (its own disjoint owned
    output slot, an `Optional[O]` pre-filled None). It must touch ONLY
    chunk `chunk_id`'s share of the input and ONLY its own `out_slot` —
    disjointness is the call site's responsibility, exactly as it was
    in the hand-written parallelize bodies.

    `In` and `O` are method-level parameters (Mojo 1.0.0b1 traits have
    no associated types); both resolve at the
    `parallel_fork_join[W, In, O, ...]` call site.
    """

    def process[
        In: Deinitable, O: Movable & Deinitable
    ](
        self,
        chunk_id: Int,
        n_chunks: Int,
        ref input: In,
        mut out_slot: Optional[O],
    ) raises:
        ...
