# =============================================================================
# MultiPhaseWork — the per-(worker,partition) work-unit trait for
# `parallel_multiphase`, the MULTI-PHASE sibling of `StealWork` /
# `parallel_steal`.
#
# Where `parallel_steal` does a SINGLE work-stealing pass and returns
# per-worker bands for the CALLER to merge, `parallel_multiphase` keeps
# the per-worker bands LIVE across multiple phases: a work-stealing
# Phase 1 fill, followed by one-or-more STATIC partition-strided Phase-N
# passes over the SAME persisted bands. The bands are NOT reclaimed
# between phases — they live (at stable heap addresses) across every
# fork-join barrier.
#
# This is the shape `agg_radix` / `agg_perfect_hash` / `spill_parallel_insert`
# all share:
#   * N workers `fetch_add` morsels off a shared
#     atomic counter and scatter each grabbed morsel by radix into THEIR
#     OWN per-worker band of `num_partitions` sub-accumulators.
#   * `num_partitions` tasks; task p folds every
#     worker's partition-p sub-accumulator into worker 0's partition-p.
#   * `num_partitions` tasks; task p reads
#     worker 0's (now-merged) partition-p and writes its output slice.
#
# The persisted per-worker bands across the phase barrier — at stable
# addresses, with no wildcard origin — is the make-or-break safety
# property the shared `parallel_multiphase` layer centralizes.
#
# `In`, `Band`, and `Out` are method-level parameters (Mojo 1.0.0b1 traits
# have no associated types); all resolve at the
# `parallel_multiphase[W, In, Band, Out, ...]` call site.
#
# This helper centralizes the fork-join safety contract.
# =============================================================================

from komira_core.collections.slab import Slab


trait MultiPhaseWork(Copyable, Movable, Deinitable):
    """Per-(worker,partition) work unit for `parallel_multiphase`.

    Four methods drive the three-phase pipeline. The shared
    `parallel_multiphase` layer owns the per-worker band Slab across the
    phases + the shared atomic morsel counter + the immutable input borrow
    + the hardware-derived worker count + the serial fallback + the
    error-caught contract ONCE so call sites can't break it.


      * `init_band(n_partitions, n_items, out_slot)` — invoked once per
        WORKER to build that worker's fresh band of `n_partitions`
        sub-accumulators INTO `out_slot` (which arrives as `None`). Filling
        an out_slot (rather than returning `Band` by value) sidesteps the
        "opaque trait-parameter has no default ctor" wall — the consumer
        writes its concrete band through a typed-pointer bitcast on
        `out_slot`.
      * `process_morsel(item_idx, n_items, input, band)` — invoked once per
        morsel index the worker steals off the shared atomic counter, in
        arbitrary order. Reads `input` (borrowed read-only) and scatters
        each row of the morsel into the worker's OWN `band` (its disjoint
        per-worker sub-accumulators). Item indices are claimed exactly once
        across all workers (no double-grab, no skip).


      * `process_partition(partition_idx, n_partitions, n_workers, bands)` —
        invoked once per partition index in [0, n_partitions). It receives
        a mutable view of the WHOLE per-worker band Slab (`bands`, length
        `n_workers`) and operates on partition `partition_idx` ACROSS all
        worker-bands — e.g. fold every worker's partition-p sub-table into
        worker 0's partition-p. Task `p` must touch ONLY partition-p slots
        across the worker-bands (disjoint per-task destinations); the
        per-partition disjointness is the call-site contract, exactly as it
        was in the hand-written merge/emit segments. The driver runs as
        many static partition passes as the caller requests
        (`n_static_phases`), each a fresh fork-join barrier over the SAME
        bands; `phase_no` (1-based: 1 == the first static pass after the
        work-stealing fill) tells the consumer which pass this is.
      * `process_partition` carries `phase_no` so one impl can serve
        multiple static passes (merge on phase 1, emit on phase 2, ...).
    """

    def init_band[
        Band: Movable & Deinitable
    ](
        self, n_partitions: Int, n_items: Int, mut out_slot: Optional[Band]
    ) raises:
        """Build a fresh per-worker band of `n_partitions` sub-accumulators
        INTO `out_slot` (which arrives as `None`). Invoked once per worker
        before that worker steals any morsel. `n_items` is the total morsel
        count (a pre-sizing hint).

        Filling an `out_slot: Optional[Band]` sidesteps the opaque
        trait-parameter default-ctor wall — write the concrete band through
        a typed-pointer bitcast on `out_slot`. Mirrors
        `StealWork.init_worker_state`'s out_slot shape."""
        ...

    def process_morsel[
        In: Deinitable, Band: Movable & Deinitable
    ](
        self,
        item_idx: Int,
        n_items: Int,
        ref input: In,
        mut band: Band,
    ) raises:
        """Scatter morsel `item_idx` into the
        worker's own `band`. Invoked once per morsel the worker steals
        (arbitrary order)."""
        ...

    def process_partition[
        Band: Movable & Deinitable
    ](
        self,
        phase_no: Int,
        partition_idx: Int,
        n_partitions: Int,
        n_workers: Int,
        mut bands: Slab[Optional[Band]],
    ) raises:
        """Operate on partition
        `partition_idx` across ALL worker-bands in `bands` (length
        `n_workers`). `phase_no` (1-based) selects which static pass this
        is so one impl can serve merge (phase 1), emit (phase 2), etc.

        Task `p` must touch ONLY partition-`p` slots across the worker
        bands — disjoint per-task destinations. The bands persist (at
        stable addresses) from the Phase-1 fill through every static
        pass; the helper guarantees they are not reclaimed between
        passes."""
        ...
