# =============================================================================
# StealWork — the per-item work-unit trait for `parallel_steal`, the
# WORK-STEALING sibling of `ChunkWork` / `parallel_fork_join`.
#
# Where `ChunkWork` does STATIC task_id-stride chunking (worker `tid`
# owns chunk `c` iff `c % n_workers == tid`), `StealWork` does DYNAMIC
# work-stealing: every worker pulls the next item index off a SHARED
# atomic counter via `fetch_add(1)` until the item space is exhausted,
# and accumulates each item it grabs into ITS OWN per-worker state
# (`WS`). Faster workers grab more items; load self-balances.
#
# The shared `parallel_steal` layer owns the State/Task/3-entry split +
# the shared-atomic-counter safety contract + the destroy-recreate/gap7 per-worker-
# state ownership ONCE so that call sites can't break it. A consumer
# implements StealWork with the per-item work it already does inside its
# hand-written `while True: morsel_counter.fetch_add(1)` body, plus the
# per-worker-state factory.
#
# This is the shape the engine-agg work-stealing consumers share
# (semi_join.probe_semi_parallel, agg_radix, agg_perfect_hash,
# partitioned_agg_steal_merge, spill_parallel_insert,
# compiler_parallel): a shared atomic morsel counter + per-(worker,...)
# sub-table accumulation + a caller-side merge.
#
# This helper centralizes the fork-join safety contract.
# =============================================================================


trait StealWork(Copyable, Movable, Deinitable):
    """Per-item work unit for `parallel_steal` (work-stealing fork-join).

    Two methods:

    `init_worker_state(n_items)` is invoked once per WORKER (not per
    item) to build that worker's own fresh accumulator `WS`. Each
    worker gets its own disjoint `WS`; there is no cross-worker sharing
    of the accumulator. `n_items` is provided so the factory can
    pre-size (e.g. a per-worker hash table capacity hint).

    `process_item(item_idx, n_items, input, ws)` is invoked once per
    item index the worker steals off the shared atomic counter, in
    arbitrary (work-stealing) order. It reads `input` (borrowed
    read-only) and folds the item into `ws` (the worker's own
    accumulator, mutated in place). Item indices are claimed exactly
    once across all workers (the shared atomic counter guarantees
    no double-grab, no skip), so `ws` accumulates a disjoint subset of
    the item space.

    After the dispatch the helper returns a `Slab[Optional[WS]]` of
    length `n_workers` — one accumulator per worker, reclaimed via
    `Optional.take()`. The CALLER merges the per-worker `WS` values
    (the merge is consumer-specific: fold per-worker hash tables, concat
    per-worker row lists, sum per-worker counters, ...).

    `In` and `WS` are method-level parameters (Mojo 1.0.0b1 traits have
    no associated types); both resolve at the
    `parallel_steal[W, In, WS, ...]` call site.

    The consumer must touch ONLY item `item_idx`'s share of the input
    and ONLY its own `ws` — disjointness is the call-site contract,
    exactly as it was in the hand-written work-stealing bodies. The
    shared atomic counter (owned by the helper) is the ONLY shared
    mutable state, and it is touched ONLY via `fetch_add` inside the
    helper — never by the consumer.
    """

    def init_worker_state[
        WS: Movable & Deinitable
    ](self, n_items: Int, mut out_slot: Optional[WS]) raises:
        """Build a fresh per-worker accumulator INTO `out_slot` (which
        arrives as `None`). Invoked once per worker before that worker
        steals any item. `n_items` is the total item count (a pre-sizing
        hint; the worker will process a disjoint subset of it).

        Filling an `out_slot: Optional[WS]` (rather than returning `WS`
        by value) sidesteps the "opaque trait-parameter has no default
        ctor" wall: the consumer writes its concrete accumulator through
        a typed-pointer bitcast on `out_slot` — no `take_pointee` /
        heap-stash dance. Mirrors `ChunkWork.process`'s `out_slot` shape."""
        ...

    def process_item[
        In: Deinitable, WS: Movable & Deinitable
    ](
        self,
        item_idx: Int,
        n_items: Int,
        ref input: In,
        mut ws: WS,
    ) raises:
        """Fold item `item_idx` into the worker's own accumulator `ws`.
        Invoked once per item the worker steals (arbitrary order)."""
        ...
