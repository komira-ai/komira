# =============================================================================
# CteMorselSource -- Rev 4.3 MorselSourceImpl resolving an InMemoryRegistry
# handle to a materialized RecordBatch, delegating to BatchMorselSource.
# =============================================================================
#
# Per an internal doc Rev 4.3 §4.3 (source
# contract + as_source() cost table) and §7 Phase 5b.
#
# Phase 5b deliverable. Thin wrapper over Phase 5a's BatchMorselSource that
# resolves a `String` handle into `InMemoryRegistry` at first-use (lazy)
# and constructs an embedded BatchMorselSource over a fresh deep-copy of
# the underlying RecordBatch. All trait methods delegate to the embedded
# source once built.
#
# Architectural decisions
# -----------------------
# 1) Wrap, not peer. Per recon architectural decision #1 and the Phase 5b
#    context: CteMorselSource is a thin wrapper on BatchMorselSource, not
#    a reimplementation of the MorselSourceImpl hot path. All production
#    perf characteristics (atomic cursor, disjoint-slot swap,
#    Phase 1d.4.1 immutable-borrow pulls) carry over from 5a with zero
#    code duplication.
#
# 2) Lazy resolution. The registry lookup + deep-copy + split happen on
#    the FIRST `next_morsel` call, not at construction. Matches §4.3 cost
#    table ("O(1) once producer finished"). Two-consumer case: each
#    CteMorselSource resolves independently on first pull, so if one
#    consumer starts before the producer has committed, it still blocks
#    only at pull time, not construction.
#
# 3) Deep-copy per consumer. `InMemoryRegistry::lookup` returns a `ref`
#    tied to the registry's Slab origin (see compiler_registry.mojo).
#    That reference cannot be stored in our heap slab (origin composition
#    would fail), and BatchMorselSource takes `var RecordBatch` (moving it
#    out of the registry would break shared-consumer semantics). We use
#    the existing `_copy_batch` helper (sdk.compiler_helpers) -- the same
#    helper already in production use for JoinProbeOp -- to take an owned
#    copy under the immutable borrow, then move it into a freshly-built
#    BatchMorselSource. Cost: one column-deep copy per consumer, identical
#    to the scan_cache path already used for self-join dedup.
#
#    The alternative "view" pattern (a shared Arc + non-owning Morsel
#    refs) is not wired yet in v0.4 (Column / PrimitiveArray buffer
#    ownership is still `Movable` rather than `Arc`). Revisit in 5d if
#    the per-consumer copy shows up as a hotspot.
#
# Concurrency contract
# --------------------
# After the first pull, `self._inner` is populated; subsequent pulls are
# a direct delegate. Phase 1d.4.1 immutable-borrow contract on
# `next_morsel(self, wid)` holds unchanged. The one-shot initialization
# path runs exactly once per CteMorselSource; multiple concurrent first
# pulls would race -- we serialize via an Atomic[int8] init flag +
# compare-and-exchange (see `_ensure_inner`). Losers spin-wait on the
# `ready` flag. In practice the scheduler's Phase 1 driver constructs
# one CteMorselSource per consumer and only starts workers after setup,
# so the race window is tight but non-zero; the atomic gate is cheap
# insurance.
#
# Capabilities
# ------------
# All False, matching BatchMorselSource (Phase 5a). CTE sources operate
# on already-materialized data; projection / decode-filter / pushdown
# are all upstream of the registry by construction.
# =============================================================================

from std.memory import ArcPointer, UnsafePointer
from komira_atomic_alias import AtomicI8

from komira_arrow.schema import RecordBatch, Schema
from komira_buffer.constants import DEFAULT_MORSEL_ROWS
from komira_collections.slab import Slab
from .batch_morsel_source import BatchMorselSource
from komira_morsel.morsel import Morsel
from komira_morsel.morsel_source import MorselSourceImpl, SourceCapabilities
from komira_plan_stats.source_statistics import SourceStatistics
from komira_column_kernels.compiler_helpers import copy_batch
from komira_scan_source.compiler_registry import InMemoryRegistry


# =============================================================================
# _CteState -- heap slab holding the handle, registry pointer, init
# gate, and the lazily-built inner source.
# =============================================================================


struct _CteState:
    """Heap slab. Not Movable/Copyable -- owned exactly once by
    CteMorselSource (alloc in __init__, free in __del__).

    Fields
    ------
    handle         -- registered table name to look up in the registry.
    registry       -- shared-ownership handle to the InMemoryRegistry.
                      ArcPointer bumps refcount on CteMorselSource copy
                      (Movable copyinit path) and drops it automatically
                      when the last handle goes out of scope. Only
                      immutable-`self` methods (`.lookup()`) are called
                      through the Arc; all mutation (`.register()`) must
                      happen BEFORE the registry is wrapped (the caller
                      registers, then hands the Arc to the source).
    init_state     -- 0 = not yet initialized, 1 = initializing, 2 = ready.
                      Atomic CAS-driven one-shot gate so concurrent first
                      pulls serialize on the lookup + deep-copy.
    inner          -- the embedded BatchMorselSource, initialized on
                      first pull. Reached via UnsafePointer so we can
                      init_pointee_move into the slot under the atomic
                      gate without making the slab Movable.
    morsel_rows    -- forwarded to BatchMorselSource at init time.
    """

    var handle: String
    # ArcPointer encapsulates shared ownership. CteMorselSource only
    # calls `.lookup()` (immutable-self) on the registry, which works
    # through Arc's immutable `[]` ref without copy.
    var registry: ArcPointer[InMemoryRegistry]
    var init_state: AtomicI8
    var inner: BatchMorselSource
    var morsel_rows: Int


# =============================================================================
# CteMorselSource -- the public MorselSourceImpl
# =============================================================================


struct CteMorselSource(MorselSourceImpl):
    """Concrete MorselSourceImpl resolving an InMemoryRegistry handle.

    Construction is O(1) (no registry access). First `next_morsel` call
    resolves the handle, deep-copies the batch out of the registry, and
    builds an embedded BatchMorselSource. Subsequent calls delegate.
    """

    # Single-element heap slab holding the Movable-incompatible _CteState
    # (it contains an Atomic init gate). AtomicSlab[_CteState] is the
    # codebase's standard primitive for this shape: heap alloc of a
    # non-Movable struct with in-place init via unsafe_element_ptr. The
    # slab's auto-synth destructor runs destroy_pointee on the slot and
    # frees the buffer.
    var _state: Slab[_CteState]

    # --- construction ---

    def __init__(
        out self,
        var handle: String,
        var registry: ArcPointer[InMemoryRegistry],
        morsel_rows: Int = DEFAULT_MORSEL_ROWS,
    ) raises:
        """Build a CteMorselSource that will resolve `handle` on first use.

        Args:
            handle: Registry table name. Moved into the slab.
            registry: Shared-ownership handle to the registry. The caller
                keeps a copy (refcount bump) or moves this one in. The
                registry MUST already contain `handle` by the time the
                first `next_morsel` lookup fires (typical production
                pattern: the driver registers the CTE producer's output,
                then hands the Arc to the consumer).
            morsel_rows: Forwarded to the embedded BatchMorselSource.
        """
        var rows = morsel_rows
        if rows < 1:
            rows = 1

        # AtomicSlab zero-fills the slot so direct assignment to Atomic
        # fields does not run destructors on uninitialized memory.
        # Movable fields (String, BatchMorselSource, ArcPointer) go
        # through init_pointee_move on the field's address. The slab's
        # auto-synth destructor runs destroy_pointee on the slot (which
        # drops handle, inner, and ArcPointer -- the Arc drop decrements
        # the registry refcount) and frees the backing allocation --
        # no manual __del__ required on CteMorselSource.
        self._state = Slab[_CteState].create_prefilled(1)
        var state_ptr = UnsafePointer(to=self._state.get_mut_interior(0))
        UnsafePointer(to=state_ptr[].handle).unsafe_write(handle^)
        # ArcPointer is Movable; init_pointee_move handles the transfer
        # (no refcount bump on move, just the value relocation).
        UnsafePointer(to=state_ptr[].registry).unsafe_write(registry^)
        state_ptr[].init_state = AtomicI8(Int8(0))
        # Placeholder inner BatchMorselSource -- built from an empty
        # RecordBatch so destruction is well-defined if the source is
        # dropped before first use. First pull destroys this and
        # re-initializes with the real batch.
        var empty = RecordBatch()
        UnsafePointer(to=state_ptr[].inner).unsafe_write(
            BatchMorselSource(empty^, morsel_rows=1)
        )
        state_ptr[].morsel_rows = rows

    # NOTE: No __del__. AtomicSlab runs destroy_pointee on the slot and
    # frees the buffer in its auto-synth destructor, which chains through
    # the placeholder/real BatchMorselSource destructor and the handle
    # String destructor.

    # --- lazy init helper ---

    def _ensure_inner(self) raises:
        """Ensure `state_ptr[].inner` is the real BatchMorselSource.

        Atomic CAS-driven one-shot gate:
          state 0 -> 1  : we won, perform lookup + deep-copy + rebuild.
          state 1       : someone else is initializing; spin.
          state 2       : ready; return immediately.

        PERF-CRITICAL: the spin-wait path is cold (only hit when two
        workers call next_morsel concurrently on a fresh source; the
        plan_compiler driver typically warms the source with one pull
        before parallelize). A proper condvar is overkill for the
        expected narrow race window; if this ever shows up in profiles,
        replace with `os.futex_wait`.
        """
        # SAFETY: slot 0 is initialized in __init__; state_ptr lifetime
        # is tied to self._state which outlives this call.
        var state_ptr = UnsafePointer(to=self._state.get_mut_interior(0))
        var cur = state_ptr[].init_state.load()
        if Int(cur) == 2:
            return

        # Try to take the init token: CAS 0 -> 1.
        # Mojo Atomic.compare_exchange(expected, new) returns Bool;
        # see engine/task_queue.mojo for the in-tree pattern.
        var expected = Int8(0)
        var won = state_ptr[].init_state.compare_exchange(expected, Int8(1))

        if won:
            # We own the init. Look up the batch, deep-copy, rebuild
            # the embedded BatchMorselSource.
            var batch_copy = copy_batch(state_ptr[].registry[].lookup(state_ptr[].handle))
            var rows = state_ptr[].morsel_rows
            var fresh = BatchMorselSource(batch_copy^, morsel_rows=rows)
            # Replace the placeholder with the real source (the assignment
            # destroys the placeholder).
            state_ptr[].inner = fresh^
            # Publish ready. Bump 1 -> 2 via fetch_add (we are the
            # only publisher since we won the CAS, so this is a
            # simple release). Atomic.store's in-tree surface takes
            # (ptr, value) as a free fn; the member fetch_add form is
            # what's exercised elsewhere in engine/.
            _ = state_ptr[].init_state.fetch_add(Int8(1))
            return

        # Lost the race: spin until the winner publishes ready.
        while Int(state_ptr[].init_state.load()) != 2:
            pass

    # --- trait methods ---

    def next_morsel(self, worker_id: Int) raises -> Optional[Morsel]:
        self._ensure_inner()
        return self._state.get_mut_interior(0).inner.next_morsel(worker_id)

    def output_schema(self) -> Schema:
        # Schema is only meaningful after the inner source is built
        # (the placeholder is an empty-batch source, whose schema is
        # also empty). Callers per the Phase 5b contract invoke
        # output_schema during materialization, which happens AFTER
        # the CTE producer committed -- so we force init here. If
        # lookup fails (unknown handle), surface the error.
        try:
            self._ensure_inner()
        except:
            # output_schema is non-raising in the trait -- we cannot
            # propagate. Return an empty schema on failure; the
            # downstream sink will fail loudly on the first pull with
            # a lookup error carrying the handle name.
            return Schema()
        return self._state.get_mut_interior(0).inner.output_schema()

    def partition_hint(self) -> Int:
        try:
            self._ensure_inner()
        except:
            return 1
        return self._state.get_mut_interior(0).inner.partition_hint()

    def row_count_hint(self) -> Int:
        try:
            self._ensure_inner()
        except:
            return 0
        return self._state.get_mut_interior(0).inner.row_count_hint()

    def capabilities(self) -> SourceCapabilities:
        # Phase 5b mirrors Phase 5a -- all False. The CTE source
        # operates on already-materialized data; projection etc. are
        # applied upstream, before the registry handoff.
        return SourceCapabilities(
            supports_projection=False,
            supports_decode_filter=False,
            supports_dict_preservation=False,
            supports_dynamic_filter=False,
            supports_row_group_pruning=False,
            supports_bypass_columns=False,
            supports_as_source=False,
        )

    def statistics(self) -> SourceStatistics:
        return SourceStatistics()
