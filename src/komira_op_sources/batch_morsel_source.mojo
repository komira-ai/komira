# =============================================================================
# BatchMorselSource -- Rev 4.3 MorselSourceImpl for in-memory RecordBatch
# =============================================================================
#
# Per an internal doc Rev 4.3 §4.3 (source
# contract + as_source() cost table) and §7 Phase 5a.
#
# Phase 5a deliverable. Produces morsels over a RecordBatch that has
# already been materialized in memory. Used in Phase 5c (scan-dedup
# rewrite) where the optimizer materializes a shared Parquet scan once
# and substitutes Plan[BatchMorselSource] for each duplicate. Also the
# building block for Phase 5b CteMorselSource (thin wrapper that resolves
# a registry handle, then delegates to this source).
#
# Design mirrors the Phase 1c ParquetMorselSource template:
#   * State behind a heap `_State` slab reached via UnsafePointer so the
#     Atomic cursor stays race-free while the outer struct remains
#     Movable (Atomic is not Movable in Mojo).
#   * `next_morsel(self, wid)` is an immutable-borrow method -- workers
#     share ONE source, claim morsels via `fetch_add` on the atomic
#     cursor.
#   * Heavy per-morsel column-slice work runs ONCE at construction via
#     `split_record_batch`; the resulting `MorselArray` lives in the
#     heap slab and workers swap slot `c` with a
#     `Morsel.empty` placeholder so the Slab destructor stays
#     consistent. This matches the ParquetMorselSource intra-RG drain
#     pattern (swap with a placeholder) but across workers rather than
#     within one worker.
#
# Capabilities (Phase 5a):
#   supports_projection        = False -- data is already materialized
#   supports_decode_filter     = False -- no decode step
#   supports_dict_preservation = False -- dict merging is sink-side
#   supports_dynamic_filter    = False
#   supports_row_group_pruning = False -- no RGs
#   supports_bypass_columns    = False -- no raw parquet chunks
#   supports_as_source         = False -- Phase 5c/5d (needs shared Arc
#                                          over the batch; today the
#                                          source owns the batch single-
#                                          pass)
#
# §4.3 as_source() cost model: BatchMorselSource::as_source() is targeted
# to be O(1) (shared Arc over the batch) when it lands. Phase 5a leaves
# the capability off because the source currently consumes the batch
# (single-pass). Phase 5c/5d will lift the single-pass restriction if a
# later rewrite rule needs it; for the scan-dedup driver (5c.1) the
# materialization site builds ONE BatchMorselSource per duplicate scan
# and threads it through `execute_collect`, so each source is drained
# exactly once -- the O(1) as_source is not yet on the hot path.
# =============================================================================

from std.builtin.swap import swap
from std.memory import UnsafePointer, alloc
from komira_atomic_alias import AtomicI64
from std.collections import Array
from std.time import perf_counter_ns

from komira_arrow.schema import Field, RecordBatch, Schema, SchemaBuilder
from komira_buffer.constants import DEFAULT_MORSEL_ROWS
from komira_collections.slab import Slab
from komira_host.cpu_topology import engine_worker_count
from komira_host.engine_placement import EnginePlacement
from komira_morsel.morsel import Morsel, MorselArray, split_record_batch
from komira_morsel.morsel_source import MorselSourceImpl, SourceCapabilities
from komira_plan_stats.source_statistics import SourceStatistics


# P0-1 range-claim stride. Workers grab `_CURSOR_STRIDE` morsel indices
# with one atomic, then walk through them locally via a wid-partitioned
# `(next, end)` slab. DuckDB dispenses 60 vectors per mutex acquisition;
# we pick 32 as a conservative starting point. At v0.4's 2048-row morsel
# sizing on B-1 (~6M rows / 2048 = ~2,930 morsels), this drops the
# shared-cursor fetch_add count from 2,930 to ~92. See
# an internal doc §5 P0-1. `_MAX_WORKERS`
# must cover the scheduler's worst-case worker_id (matches the
# parquet_morsel_source._MAX_WORKERS_FOR_SPLIT choice).
comptime _CURSOR_STRIDE: Int64 = 32
comptime _MAX_WORKERS: Int = 128


# =============================================================================
# DELTA-2 WAVE-1 work-stealing (; design
# the work-stealing design note, §W1). Dark flag
# `BatchMorselOptions.steal` (still dark). The claim policy over the
# in-mem morsel feed becomes two-level: a coarse per-worker reserve claimed
# from the shared `_State.cursor` (Level 1, the existing stride-32 claim), and
# a per-worker ATOMIC sub-cursor that a stealer can advance to take the
# victim's UN-STARTED reserve tail (Level 2, the C2 requirement). See §1.5.
#
# The sub-cursor + reserve-end are PACKED into ONE `Atomic[int64]` per worker:
#   packed = (end << 32) | sub          (sub, end are morsel indices in [0,n))
# so a claim is a SINGLE atomic `fetch_add(1)` (increments `sub`, no carry into
# `end` while sub < 2^32) and a coarse-reserve refill is a SINGLE atomic
# `store` that swaps the WHOLE reserve at once. Because both fields live in one
# atomic word, a claimer's RMW and a refiller's store can never observe a torn
# (new-sub, old-end) pair -- this is what makes the refill race-free against a
# concurrent stealer (design §1.5 "disjointness / exactly-once -- SOUND"). A
# claim of index `c` is valid iff `sub < end` at the RMW snapshot; sub-values
# >= end are handed to rejected claims (harmless bounded overshoot, wiped by
# the next refill store). Steal is enabled only when n < 2^31 (guards the
# 32-bit pack); larger inputs fall back to the byte-identical OFF claim.
comptime _STEAL_SHIFT: Int64 = 32
comptime _STEAL_MASK: Int64 = 0xFFFFFFFF
comptime _STEAL_MAX_MORSELS: Int = 1 << 31


struct _WorkerClaim:
    """One cache-line-padded per-worker two-level claim slot (Level 2).

    `packed` holds `(end << 32) | sub` -- a claim is `packed.fetch_add(1)`
    (own OR stolen), a coarse-reserve refill is `Atomic.store` of a fresh
    packed word. Padded to 64 bytes so distinct workers' claim slots never
    share a cache line (R9: no false-sharing on the sub-cursor Slab). Holds an
    Atomic -> non-Movable; lives once per slot in a `Slab[_WorkerClaim]`
    zero-filled by `create_prefilled` (packed == 0 => sub==end==0 => empty
    reserve, the correct cold-start state).
    """

    var packed: AtomicI64
    # Pad to a full 64-byte cache line (8B atomic + 7 * 8B = 64B).
    var _pad: Array[Int64, 7]


# =============================================================================
# _clone_schema -- Schema is Movable-only; there is no `.copy()` method on
# the arrow Schema struct. Mirrors plan_compiler._copy_schema so we don't
# pull in a plan_compiler -> engine import cycle. Cheap: a handful of
# String clones per field.
# =============================================================================


def _clone_schema(schema: Schema) -> Schema:
    # AGG-SCHEMA-METADATA-PROPAGATION-V0.4: preserve metadata
    # via the non-raising `field_at_unchecked` accessor (this helper is
    # called from `MorselSource.output_schema` which is non-raising per
    # the trait contract).
    var sb = SchemaBuilder()
    for i in range(schema.num_columns()):
        sb.add_field(schema.field_at_unchecked(i))
    return sb.build()


# =============================================================================
# _State -- heap slab holding the shared atomic cursor + the pre-split
# morsel array + the output schema.
#
# Not Movable / Copyable -- it lives exactly once on the heap (allocated
# by `BatchMorselSource.__init__`, freed by its `__del__`). Atomic fields
# are assigned in place (`ptr[].field = Atomic(...)`) rather than moved.
# =============================================================================


struct _State:
    """Heap POD slab for BatchMorselSource.

    Fields:
      morsels         -- pre-split MorselArray covering the input batch.
                         Workers swap slot `c` with an
                         empty Morsel (see next_morsel).
      cursor          -- next morsel slot index to claim (fetch_add).
                         Shared across workers.
      morsel_counter  -- monotonic morsel_id stamp. Bumped on every take
                         so downstream sinks get stable unique ids.
      schema          -- the RecordBatch schema, retained so
                         `output_schema()` can return it after the batch
                         has been consumed into the MorselArray. Schema
                         is Movable-only so it can live on the slab.
      total_rows      -- cached sum-of-num_rows across all morsels.
                         Returned by `row_count_hint()`.
    """

    var morsels: MorselArray
    var cursor: AtomicI64
    var morsel_counter: AtomicI64
    var schema: Schema
    var total_rows: Int
    # DELTA-2 WAVE-1 fire-pin: monotonic count of morsels claimed via a STEAL
    # (a stealer advancing a victim's sub-cursor), NOT own-reserve claims. The
    # gate/tests read it via `steal_fire_count()` to assert the steal path
    # actually fired (a silent decline must not pass a value-equiv gate
    # vacuously -- design §4 flip discipline "fire-pin").
    var steal_hits: AtomicI64


# =============================================================================
# BatchMorselOptions -- the source's dark switches, as a VALUE
# =============================================================================


struct BatchMorselOptions(Copyable, ImplicitlyCopyable, Movable):
    """Switches of `BatchMorselSource`, passed to its constructors.

    Each was once read from the process environment at construction (or, for
    the steal trace, at every worker's last pull). The caller decides now and
    nothing in this module reads the environment. The defaults are the shipped
    behaviour, so a constructor call that passes nothing is unchanged.

    Fields:
      * `steal` -- the two-level coarse-reserve claim with work stealing
        instead of the non-atomic per-worker range walk. DEFAULT OFF. It takes
        effect only below 2^31 morsels; larger inputs keep the default claim.
      * `steal_trace` -- print each worker's running steal count when that
        worker's pull returns None, so a run can prove the steal fired.
      * `trace_split` -- print one line of constructor timing (batches, rows,
        morsels, total and split microseconds).
      * `placement` -- the CPU placement policy the latched worker count is
        derived from (the tail zone of the claim and the victim scan). The
        default is every policy off.
    """

    var steal: Bool
    var steal_trace: Bool
    var trace_split: Bool
    var placement: EnginePlacement

    def __init__(
        out self,
        steal: Bool = False,
        steal_trace: Bool = False,
        trace_split: Bool = False,
        placement: EnginePlacement = EnginePlacement(),
    ):
        self.steal = steal
        self.steal_trace = steal_trace
        self.trace_split = trace_split
        self.placement = placement


# =============================================================================
# BatchMorselSource -- the public MorselSourceImpl
# =============================================================================


struct BatchMorselSource(MorselSourceImpl):
    """Concrete `MorselSourceImpl` backed by an in-memory RecordBatch.

    Construction consumes the batch -- it is split into a MorselArray
    once, and workers subsequently claim morsels via an atomic cursor.
    See the module header for rationale; the design mirrors Phase 1c.

    Concurrency contract (Phase 1d.4.1 revision):
      * `next_morsel(self, wid)` is safe for N concurrent workers through
        a shared immutable borrow. Only `_state[].cursor` and
        `_state[].morsel_counter` are mutated during pulls -- both are
        Atomic and race-free.
      * The `MorselArray` inside `_state[].morsels` is NOT protected by
        a lock -- mutation is restricted to the single slot identified
        by a successful `fetch_add`, so two workers never touch the
        same slot. Workers swap in `Morsel.empty` via the internal
        Slab pointer (mut access via the slab's raw pointer,
        permissible while `self` is immutably borrowed because the
        mutation target is heap storage, not `self` itself).

    Single-pass contract (§4.3): each morsel is returned exactly once.
    After `None`, workers must stop pulling. Re-scan requires
    `as_source()` which Phase 5a does not implement (capability off).
    """

    # Single-element heap slab holding the Movable-incompatible _State
    # (it has Atomic fields). AtomicSlab[_State] is the existing encapsu-
    # lation primitive for exactly this case: heap allocation of non-
    # Movable types, with in-place initialization via unsafe_element_ptr.
    # The slab owns the allocation and destroys every slot + frees the
    # backing buffer in its auto-synth destructor.
    var _state: Slab[_State]

    # P0-1 range-claim cache: 2 Int64 slots per worker: [next, end).
    # When `next < end`, the worker consumes slot `next` locally and
    # bumps without touching the shared atomic. When `next >= end` (zero-
    # init state), it calls `cursor.fetch_add(_CURSOR_STRIDE)` and refills.
    # wid-partitioned: only worker `wid` writes its slot, so no atomics
    # are needed on the cache itself. Slab[Int64] owns the heap
    # allocation; interior mutation under the borrowed-self `next_morsel`
    # receiver goes through Slab.get_mut_interior(self, i).
    var _range_slab: Slab[Int64]

    # RUNTIME-STRUCTURE-POC Phase 4: the C3
    # coarse-to-fine scheduler grain + the worker count used to size the tail
    # zone. UNCONDITIONAL in production (C3 flip, board
    # the kill-switch was deleted -- the fast arm is the only shipping arm). `next_morsel`'s
    # cursor refill SHRINKS the `fetch_add` addend from `_CURSOR_STRIDE` to 1
    # morsel once the cursor enters the tail zone (remaining <= workers *
    # stride), so no fork-join barrier is gated by a full 32-morsel straggle on
    # a slow core. Both fields are POD scalars (gap6-safe) latched at ctor.
    #
    # `_sched_c3_enabled` SURVIVES the flag deletion as a TEST-ONLY oracle
    # switch: the fixed-`_CURSOR_STRIDE` refill is the A/B reference the
    # work-stealing falsifiers need to manufacture coarse reserves at small n
    # (tests/engine/test_batch_morsel_source_steal.mojo). Production always
    # constructs it True; only `set_sched_c3_enabled_for_test` can clear it.
    var _sched_c3_enabled: Bool
    var _c3_num_workers: Int

    # DELTA-2 WAVE-1 (): work-stealing claim policy over the
    # in-mem morsel feed, behind `BatchMorselOptions.steal` (dark). When enabled,
    # `_claim_slab` holds one cache-line-padded `_WorkerClaim` (packed atomic
    # sub-cursor + reserve-end) per worker slot; `next_morsel` runs the §1.5
    # two-level claim + steal loop instead of the non-atomic `_range_slab`
    # walk. Default OFF -> `_claim_slab` is an empty slab and `next_morsel` is
    # byte- AND wall-identical to the C3/fixed path (the oracle). `_steal_nw`
    # bounds the victim scan (latched worker count, gap6-safe POD scalar).
    var _steal_enabled: Bool
    var _steal_trace: Bool
    var _steal_nw: Int
    var _claim_slab: Slab[_WorkerClaim]

    # --- construction ---

    def __init__(
        out self,
        var batch: RecordBatch,
        morsel_rows: Int = DEFAULT_MORSEL_ROWS,
        options: BatchMorselOptions = BatchMorselOptions(),
    ) raises:
        """Build a BatchMorselSource over a materialized RecordBatch.

        The batch is consumed: `split_record_batch` splits it into a
        `MorselArray` where each morsel holds up to `morsel_rows` rows.

        ⚠ THIS DOCSTRING SAID "Column data is copied into per-morsel Columns
        (not zero-copy); for a truly zero-copy path we'd need ArcPointer-backed
        buffers, which lands in a later phase." IT WAS FALSE,
        and it cost a campaign a wave. The later phase LANDED —
        made the Arc reslice unconditional — so a non-nullable
        offset-honoring column is already a refcount bump with no memcpy. When
        q21's decomposition put 40.1 ms/rep with `fork_ns=0` on this exact
        constructor, this sentence named the copy as the cause; the counters said
        otherwise. MEASURED on the benchmark host (`BatchMorselOptions.trace_split`): the
        3.79 M-row probe split reports `copy_slices=0 copy_rows=0` and cost
        17.1 ms, of which 8.6 ms was rebuilding one invariant `Schema` 2782
        times. That is now built once () and the constructor reads
        12.05 ms.

        Args:
            batch: Input RecordBatch. Ownership transferred.
            morsel_rows: Rows per morsel. Clamped to >= 1.
            options: The source's switches; the defaults are the shipped behaviour.
        """
        var batches = Slab[RecordBatch].create(1)
        batches.append(batch^)
        self = BatchMorselSource(batches^, morsel_rows, options)

    def __init__(
        out self,
        var batches: Slab[RecordBatch],
        morsel_rows: Int = DEFAULT_MORSEL_ROWS,
        options: BatchMorselOptions = BatchMorselOptions(),
    ) raises:
        """Build a BatchMorselSource that streams N materialized batches.

        DIRECT-N-STREAMING: `from_record_batches([b0..bN])`
        carries N inline chunks on the in-memory scan node. Rather than the
        SDK lowering eagerly concatenating them into ONE dense RecordBatch
        (a copy + a 2x momentary peak) and re-splitting downstream, this
        ctor splits EACH chunk into morsels and concatenates the per-chunk
        morsels into ONE combined `MorselArray`. The shared atomic cursor in
        `next_morsel` then walks morsels across ALL N batches transparently
        — multi-worker work-stealing spans the whole N-batch stream exactly
        like a multi-row-group Parquet scan, with no upfront concat.

        All N batches MUST share one schema (the `from_record_batches`
        contract enforces this; `next_morsel` re-validates each morsel's
        column tags against the cached schema). Empty `batches` yields a
        zero-row source. The single-batch `__init__` overload delegates here
        with a 1-element slab, so the two paths are byte-identical for N==1.

        Args:
            batches: Input RecordBatch chunks. Ownership transferred.
            morsel_rows: Rows per morsel. Clamped to >= 1.
            options: The source's switches; the defaults are the shipped behaviour.
        """
        # DIAG (dark, `options.trace_split`): ctor-level bracket so the region's
        # 40 ms can be attributed to the split loop vs the rest of the ctor.
        var _dg = options.trace_split
        var _dg_t0 = perf_counter_ns() if _dg else 0
        var _dg_split_ns = 0
        var rows = morsel_rows
        if rows < 1:
            rows = 1

        var n_batches = len(batches)

        # Derive the cached schema from the first non-empty-schema chunk and
        # sum total_rows across all chunks BEFORE consuming them.
        var total_rows = 0
        var schema = Schema()
        var have_schema = False
        for bi in range(n_batches):
            ref b = batches[bi]
            total_rows += b.num_rows()
            if not have_schema and b.num_columns() > 0:
                schema = _clone_schema(b.schema)
                have_schema = True

        # Split each chunk and drain its morsels into one combined slab. The
        # whole-slab moves keep this allocation-light: per-batch arrays move
        # their backing Slab[Morsel] out via `into_morsel_slab`, then each
        # morsel is moved (not copied) into the combined slab. partition_id /
        # morsel_id are re-stamped at claim time in `next_morsel`, so the
        # per-chunk indices need no global re-numbering here.
        var combined = Slab[Morsel].create(max(total_rows // rows + n_batches, 1))
        # ⛔⛔ `replace(bi, RecordBatch())`, NOT `take_slot_unchecked(bi)` +
        # a trailing `set_len_unchecked(0)`. THE LOOP BODY BELOW CAN RAISE --
        # `split_record_batch` is `raises`, and it DOES raise on real input:
        # `morsel._slice_column` has no LARGE_STRING / LARGE_BINARY arm and
        # refuses one by name (`ArrowFixedWidthFallthrough`).
        #
        # `take_slot_unchecked` moves a slot out WITHOUT adjusting `_len_t`
        # and WITHOUT poisoning the slot, so the length fix has to be a
        # SEPARATE statement after the loop -- which an error escaping the
        # loop SKIPS. The slab then unwinds still claiming all N slots are
        # live and `destroy_pointee`s the ones already moved out: for a
        # heap-owning T like `RecordBatch` that is a DOUBLE FREE, not a leak.
        # See `Slab.take_slot_unchecked`'s own ⛔⛔ clause, and
        # `engine_context.mojo`'s three UDF root arms (``), which
        # are the same defect at a different site.
        #
        # ⚠ IT IS UB, NOT A GUARANTEED CRASH, WHICH IS WHY IT SAT HERE. The
        # double free poisons tcmalloc's free list; whether that FAULTS
        # depends on what allocates next. MEASURED 2026-09-22 on darwin/arm64
        # over the cross-surface corpus (`//src/cmd/plan_matrix_rig`, fixture
        # `k int64, g int64, v large_string`, 6 rows): FIVE of twelve join
        # elements died with SIGSEGV in tcmalloc's free list -- in THREE
        # different destructors (`LogicalPlan`, `Slab[JoinProbeOpAdapter]`,
        # `SharedEngine` at exit) -- while `join_inner_k`, which raises at
        # this very line, refused cleanly. The FARM run at ``
        # crashed a DIFFERENT subset of the same cells. Same write, different
        # victim: that is what "the crash site is not the bug site" looks
        # like.
        #
        # `replace` swaps a default-constructed `RecordBatch` into the slot
        # it empties, so every slot is initialised at EVERY point and the
        # destructor is sound on every unwind path. No trailing length fix
        # exists to be skipped.
        for bi in range(n_batches):
            var chunk = batches.replace(bi, RecordBatch())
            if chunk.num_rows() == 0:
                continue
            var _dg_s0 = perf_counter_ns() if _dg else 0
            var chunk_morsels = split_record_batch(chunk^, rows)
            if _dg:
                _dg_split_ns += Int(perf_counter_ns() - _dg_s0)
            chunk_morsels.drain_morsels_into(combined)
            _ = chunk_morsels^
        # Every slot now holds an empty `RecordBatch`; the destructor walk is
        # correct and cheap. ⛔ DO NOT re-add `set_len_unchecked(0)` here --
        # it is what made the unwind unsound.
        _ = batches^

        var morsels = MorselArray.from_morsel_slab(combined^)
        var n_morsels = len(morsels)

        # Heap-allocate _State via AtomicSlab. AtomicSlab zero-fills the
        # buffer so direct assignment to Atomic fields does not run
        # destructors on uninitialized memory. Movable fields (MorselArray,
        # Schema) are initialized via init_pointee_move on the slot's
        # field pointers. AtomicSlab's auto-synth destructor runs
        # destroy_pointee on each slot and frees the buffer -- no manual
        # __del__ needed for this field.
        self._state = Slab[_State].create_prefilled(1)
        var state_ptr = UnsafePointer(to=self._state.get_mut_interior(0))
        UnsafePointer(to=state_ptr[].morsels).unsafe_write(morsels^)
        state_ptr[].cursor = AtomicI64(0)
        state_ptr[].morsel_counter = AtomicI64(0)
        UnsafePointer(to=state_ptr[].schema).unsafe_write(schema^)
        state_ptr[].total_rows = total_rows
        state_ptr[].steal_hits = AtomicI64(0)
        # P0-1 range-claim cache: 2 Int64 slots per worker, zero-initialized
        # so the first `next_morsel` call on each worker falls through to
        # the fetch_add(_CURSOR_STRIDE) refill path.
        var slab = Slab[Int64].create(2 * _MAX_WORKERS)
        for _ in range(2 * _MAX_WORKERS):
            slab.append(Int64(0))
        self._range_slab = slab^

        # RUNTIME-STRUCTURE-POC Phase 4: latch the C3 worker count once. C3 is
        # UNCONDITIONAL (flip, kill-switch
        # deleted). engine_worker_count(placement) parses sysfs
        # (CpuTopology.detect()) exactly once per source construction — the
        # expected cost of the C3 path, which is the only path.
        self._sched_c3_enabled = True
        var nw = engine_worker_count(options.placement)
        if nw < 1:
            nw = 1
        self._c3_num_workers = nw

        # DELTA-2 WAVE-1: latch the `options.steal` dark gate + the victim-scan
        # worker count once. Enabled only when n_morsels fits the 32-bit pack
        # (larger inputs fall back to the byte-identical OFF claim). When
        # enabled, `_claim_slab` is one zero-filled cache-line-padded slot per
        # worker (packed == 0 => empty reserve => cold-start refill on first
        # pull); when disabled it is empty (the OFF path never touches it ->
        # zero cost, preserving behavior-neutrality).
        # `options.steal` is still DARK (default-OFF).
        var steal_on = options.steal and n_morsels < _STEAL_MAX_MORSELS
        self._steal_enabled = steal_on
        self._steal_trace = options.steal_trace
        var steal_nw = 1
        var claim_cap = 0
        if steal_on:
            steal_nw = engine_worker_count(options.placement)
            if steal_nw < 1:
                steal_nw = 1
            if steal_nw > _MAX_WORKERS:
                steal_nw = _MAX_WORKERS
            claim_cap = _MAX_WORKERS
        self._steal_nw = steal_nw
        # create_prefilled zero-fills => every packed == 0 (sub==end==0), the
        # correct "empty reserve" cold-start state; no per-slot init needed.
        self._claim_slab = Slab[_WorkerClaim].create_prefilled(claim_cap)

        if _dg:
            print("BMS_CTOR batches=", n_batches, " rows=", total_rows,
                  " morsels=", n_morsels,
                  " total_us=", Int(perf_counter_ns() - _dg_t0) // 1000,
                  " split_us=", _dg_split_ns // 1000, sep="")

    # NOTE: No __del__. AtomicSlab and Slab both run auto-synth
    # destructors when the BatchMorselSource is dropped.

    def set_sched_c3_enabled_for_test(mut self, enabled: Bool):
        """TEST-ONLY oracle switch for the C3 coarse-to-fine refill grain.

        Production NEVER calls this: the ctor latches the C3 grain ON and it is
        the only shipping arm (its kill-switch was
        deleted). The fixed-`_CURSOR_STRIDE` refill
        it restores is the A/B reference the DELTA-2 work-stealing falsifiers
        need: with C3 on, a small morsel count is entirely inside the tail zone,
        so every claim is grain-1 and there is no un-started reserve tail for a
        stealer to take. Setting this False manufactures stride-32 reserves
        deterministically at small n.

        MUST be called before the source is handed to the executor: the field is
        read (never written) inside the parallel region, so a mid-flight flip
        would be a data race. Both arms are byte-identical in OUTPUT — only the
        claim grain differs.
        """
        self._sched_c3_enabled = enabled

    # --- DELTA-2 WAVE-1 work-stealing claim helpers () ---
    #
    # All three run under the SHARED immutable borrow of `self` (like
    # `next_morsel`): they mutate heap storage (`_claim_slab`, `_state.cursor`)
    # through the Slab interior pointers, never `self` itself. The claim/steal
    # correctness argument is the design's §1.5:
    #   * a claim (own OR stolen) is a SINGLE atomic `fetch_add(1)` on the
    #     victim's packed word -> each `sub` value handed to exactly one
    #     caller (disjoint by RMW); accepted iff `sub < end`.
    #   * a coarse-reserve refill is a SINGLE atomic `store` of the whole
    #     packed word -> a claimer's RMW can never observe a torn
    #     (new-sub, old-end) pair, so the refill is race-free against a
    #     concurrent stealer without any lock/CAS.

    @always_inline
    def _steal_claim(self, slot: Int) -> Int:
        """Atomically claim ONE unit from worker `slot`'s reserve (own or
        stolen). Returns the claimed absolute morsel index, or -1 if the
        reserve is exhausted (`sub >= end` at the RMW snapshot). The single
        `fetch_add` IS the reservation (C2). A rejected claim advances `sub`
        past `end` (bounded, harmless overshoot -- wiped by the next refill
        store; an exhausted reserve is never re-stolen because the victim scan
        skips `sub >= end`)."""
        # SAFETY: _claim_slab outlives this call; slot in [0, _MAX_WORKERS)
        # (checked by every caller). The packed atomic lives at a stable heap
        # address inside the Slab; the RMW is the only mutation. UnsafePointer
        # deref mirrors the file's proven `_state.cursor.fetch_add` form.
        var cp = UnsafePointer(to=self._claim_slab.get_mut_interior(slot))
        var old = cp[].packed.fetch_add(Int64(1))
        var sub = old & _STEAL_MASK
        var end = (old >> _STEAL_SHIFT) & _STEAL_MASK
        if sub < end:
            return Int(sub)
        return -1

    @always_inline
    def _steal_refill(self, worker_id: Int, n: Int) -> Bool:
        """Level-1 coarse reserve: claim `[base, base+stride)` from the shared
        `_State.cursor` and publish it to worker `worker_id`'s packed slot via
        a SINGLE atomic `store`. Returns False when the shared cursor is
        exhausted (`base >= n`) -> the caller advances to the steal phase. The
        store atomically swaps the entire reserve, so no stealer can read a
        torn (sub, end) pair.

        The coarse reserve SITS ON THE C3-flipped walk (,
        default-): when C3 is on (the default), the addend SHRINKS
        from `_CURSOR_STRIDE` to 1 morsel once the shared cursor enters the tail
        zone (remaining <= workers * stride) -- identical to the OFF-path C3
        claim. The pre-fetch_add `load()` only SIZES the addend; disjointness
        holds for ANY addend (the `fetch_add` still hands each base once). So
        Level-1 = the C3 coarse-to-fine claim, Level-2 = the atomic sub-cursor
        steal on top. `set_sched_c3_enabled_for_test(False)` (test-only) => fixed
        `_CURSOR_STRIDE` (the A/B oracle), and the level-2 steal is unchanged
        either way."""
        var state_ptr = UnsafePointer(to=self._state.get_mut_interior(0))
        var claim_stride = _CURSOR_STRIDE
        if self._sched_c3_enabled:
            var rem = Int64(n) - state_ptr[].cursor.load()
            if rem <= Int64(self._c3_num_workers) * _CURSOR_STRIDE:
                claim_stride = Int64(1)
        var base = state_ptr[].cursor.fetch_add(claim_stride)
        if base >= Int64(n):
            return False
        var end = base + claim_stride
        if Int(end) > n:
            end = Int64(n)
        var packed = (end << _STEAL_SHIFT) | base
        # SAFETY: static Atomic.store via UnsafePointer(to=field.value) is the
        # validated pattern (mirrors metrics_set.mojo:159). Single
        # atomic write installs the whole new reserve.
        var cp = UnsafePointer(to=self._claim_slab.get_mut_interior(worker_id))
        AtomicI64.store(
            UnsafePointer(to=cp[].packed).unsafe_bitcast[Scalar[DType.int64]](), packed
        )
        return True

    def _steal_select_victim(self, worker_id: Int) -> Int:
        """Pick a victim whose reserve still has un-started units
        (`sub < end`), scanning round-robin from `worker_id + 1` to spread
        contention. Returns the victim slot, or -1 if all reserves are drained.
        This is the HEURISTIC load (perf-only, racy-OK): it merely SELECTS a
        target; the atomic `fetch_add` in `_steal_claim` is what RESERVES
        (C2) -- a stale read here can pick an already-drained victim, which
        `_steal_claim` then rejects (never a double-claim)."""
        var nw = self._steal_nw
        for k in range(nw):
            var v = (worker_id + 1 + k) % nw
            # SAFETY: v in [0, nw) <= [0, _MAX_WORKERS); load-only.
            var cp = UnsafePointer(to=self._claim_slab.get_mut_interior(v))
            var cur = cp[].packed.load()
            var sub = cur & _STEAL_MASK
            var end = (cur >> _STEAL_SHIFT) & _STEAL_MASK
            if sub < end:
                return v
        return -1

    def _steal_next(self, worker_id: Int, n: Int) -> Int:
        """The §1.5 worker loop, one-unit-per-call. Returns a claimed absolute
        morsel index < n, or -1 when the own reserve, the shared cursor, AND
        every victim reserve are drained (worker done). A stolen unit is folded
        into the STEALER's worker-local sink state by the caller (the executor
        consumes with the stealer's `worker_id`); `combine()` merges all locals
        at the barrier, so which worker processed which unit is immaterial to
        the result multiset (design §1.5 / R5)."""
        while True:
            # 1. Own reserve (Level-2 atomic sub-cursor).
            var own = self._steal_claim(worker_id)
            if own >= 0:
                return own
            # 2. Own reserve exhausted -> claim a fresh coarse reserve.
            if self._steal_refill(worker_id, n):
                continue
            # 3. Shared cursor exhausted -> STEAL a victim's un-started tail.
            var victim = self._steal_select_victim(worker_id)
            if victim < 0:
                return -1  # all sub-cursors drained -> this worker is done
            var stolen = self._steal_claim(victim)
            if stolen >= 0:
                # Fire-pin: a steal actually fired (guards against a silent
                # decline passing a value-equiv gate vacuously -- design §4).
                var state_ptr = UnsafePointer(
                    to=self._state.get_mut_interior(0)
                )
                _ = state_ptr[].steal_hits.fetch_add(Int64(1))
                return stolen
            # Victim drained between select and claim -> re-select. Terminates
            # because sub-cursors are monotonic + bounded: eventually every
            # reserve is exhausted and _steal_select_victim returns -1.

    def steal_fire_count(self) -> Int:
        """DELTA-2 WAVE-1 fire-pin accessor: total morsels claimed via a STEAL
        (a stealer advancing a victim's sub-cursor) so far. 0 when
        `BatchMorselOptions.steal` is off or no steal fired. Read by the gate/tests to
        assert the steal path is not silently declining."""
        return Int(self._state.get_mut_interior(0).steal_hits.load())

    # --- trait methods ---

    def next_morsel(self, worker_id: Int) raises -> Optional[Morsel]:
        """Claim the next morsel slot via atomic fetch_add.

        Stateless work-stealing: any worker may claim any slot.
        `worker_id` is unused internally (reserved for per-worker sink
        scratch by the scheduler). Returns `None` on EOF; scheduler must
        not call again per the single-pass contract.

        Mutation rules while `self` is immutably borrowed:
          * Atomic fetch_add on `_state[].cursor` and
            `_state[].morsel_counter` -- race-free by construction.
          * `swap` of slot `c` with a placeholder in the
            internal Slab. Two workers never touch the same slot
            because `cursor.fetch_add` returns a unique `c`.

        PERF-CRITICAL: atomic cursor + disjoint-slot mutation is what
        keeps workers independent. Regressing to a lock or a per-call
        MorselArray copy would serialize pulls and eliminate the whole
        point of morsel-driven parallelism.
        """
        # P0-1 range-claim: per-worker `(next, end)` cache. Falls back to
        # fetch_add(1) if `worker_id` is outside the slab range (e.g.
        # single-threaded test callers passing -1).
        # SAFETY: state_ptr lifetime is tied to self._state which outlives
        # this call; AtomicSlab's slot 0 is initialized in __init__.
        var state_ptr = UnsafePointer(to=self._state.get_mut_interior(0))
        var n = len(state_ptr[].morsels)
        var use_cache = worker_id >= 0 and worker_id < _MAX_WORKERS
        var c: Int

        # DELTA-2 WAVE-1 (; design
        # the work-stealing design note, §W1). When
        # `BatchMorselOptions.steal` is set the claim policy is the §1.5 two-level
        # coarse-reserve + per-worker ATOMIC sub-cursor + steal loop: a worker
        # whose own reserve AND the shared cursor are exhausted STEALS the
        # un-started tail of a victim's reserve. Steal correctness rests on the
        # atomic `fetch_add` reservation, never the heuristic victim-scan load
        # (C2). Out-of-range worker_id (single-threaded -1 callers) and the
        # >2^31-morsel case fall through to the byte-identical OFF claim below.
        if self._steal_enabled and use_cache:
            c = self._steal_next(worker_id, n)
            if c < 0:
                # `options.steal_trace` (dark, measurement-only): at worker
                # termination print the running steal fire-pin so the q9
                # flip-gate can PROVE the steal actually fired (a silent decline
                # must not pass a value-equiv gate vacuously -- design §4). One
                # test per worker at EOF only; zero cost on the claim hot path.
                if self._steal_trace:
                    print(
                        "[STEAL] wid=",
                        worker_id,
                        " fires=",
                        Int(state_ptr[].steal_hits.load()),
                        sep="",
                    )
                return None
        else:
            if use_cache:
                # Slab.get_mut_interior(self, i) returns a mutable slot ref
                # through borrowed self -- the wid-partitioned invariant
                # means only worker `worker_id` writes these two slots.
                var nxt_ptr = UnsafePointer(to=self._range_slab.get_mut_interior(2 * worker_id))
                var end_ptr = UnsafePointer(to=self._range_slab.get_mut_interior(2 * worker_id + 1))
                var nxt = nxt_ptr[]
                var end = end_ptr[]
                if nxt >= end:
                    # RUNTIME-STRUCTURE-POC Phase 4: C3 coarse-to-fine
                    # grain (always on in production; only the test-only oracle
                    # switch clears it). Shrink the claim addend to 1 morsel once
                    # the cursor enters the tail zone so the LAST claim can't gate a
                    # barrier on a full 32-morsel straggle. The pre-fetch_add load()
                    # only SIZES the addend; a stale read mis-sizes G but never
                    # breaks disjointness (fetch_add still hands each base once).
                    var claim_stride = _CURSOR_STRIDE
                    if self._sched_c3_enabled:
                        var rem = Int64(n) - state_ptr[].cursor.load()
                        if rem <= Int64(self._c3_num_workers) * _CURSOR_STRIDE:
                            claim_stride = Int64(1)
                    var base = state_ptr[].cursor.fetch_add(claim_stride)
                    nxt = base
                    end = base + claim_stride
                    if Int(end) > n:
                        end = Int64(n)
                    end_ptr[] = end
                c = Int(nxt)
                nxt_ptr[] = nxt + Int64(1)
            else:
                c = Int(state_ptr[].cursor.fetch_add(Int64(1)))
            if c >= n:
                return None

        # Fresh morsel_id stamp; partition_id == c preserves ordering
        # when the downstream sink sorts by partition_id (matches
        # ParquetCollectSink combine() contract).
        var mid = Int(state_ptr[].morsel_counter.fetch_add(Int64(1)))

        # Swap slot `c` with an empty placeholder, so every slot in
        # [0, _size) stays initialized for the Slab destructor and no value
        # is moved out through a pointer.
        # SAFETY: `state_ptr` points at slot 0 of `self._state`, which
        # outlives this call; slot `c` is initialized (c < n); no other
        # worker touches slot `c` because `fetch_add` hands each c to
        # exactly one caller.
        var extracted = Morsel.empty(mid, c)
        swap(extracted, state_ptr[].morsels._inner.get_mut_interior(c))

        # Re-stamp morsel_id / partition_id in place then return the
        # whole morsel by move. Mojo forbids partial field moves
        # out of `extracted`, so we can't do `Morsel(extracted.batch^, ...)`
        # (that would orphan `extracted.morsel_id` etc.). Writing to the
        # fields directly and moving the whole value is the supported
        # idiom. `raw_chunks` stays None (BatchMorselSource has no
        # bypass path).
        extracted.morsel_id = mid
        extracted.partition_id = c
        extracted.origin_hint = 0

        # Phase 5d-A hazard #1 guard: assert column arrow_type tags on
        # the returned morsel match the cached schema. Without this,
        # a silent DICTIONARY -> flat fallback inside split_record_batch
        # (regression in _slice_dictionary, missing dispatch branch,
        # etc.) appears as correct row counts + wrong column types,
        # and dict-aware agg/filter silently downgrade to flat hashing
        # with no signal. See project_unfuse_phase5d_review.md hazard #1.
        # PERF-CRITICAL: tag compare only, no buffer walks -- O(cols).
        var cached_cols = state_ptr[].schema.num_columns()
        var batch_cols = extracted.batch.num_columns()
        if cached_cols != batch_cols:
            raise Error(
                "BatchMorselSource: morsel column count "
                + String(batch_cols)
                + " != cached schema column count "
                + String(cached_cols)
            )
        for ci in range(cached_cols):
            var schema_tag = state_ptr[].schema.field_arrow_type(ci)
            ref col = extracted.batch.column_at(ci)
            if schema_tag != col.arrow_type:
                raise Error(
                    "BatchMorselSource: column "
                    + String(ci)
                    + " arrow_type mismatch with cached schema"
                    + " -- silent DICTIONARY->flat fallback suspected"
                )
        return extracted^

    def output_schema(self) -> Schema:
        """Return a clone of the cached schema.

        Schema is Movable-only (no `.copy()` method), so we clone via
        the local `_clone_schema` helper. Cheap -- a handful of String
        clones per field. `_clone_schema` itself does not raise (it only
        builds Fields + a SchemaBuilder), so no fallback path is needed.
        """
        return _clone_schema(self._state.get_mut_interior(0).schema)

    def partition_hint(self) -> Int:
        """Number of pre-split morsels == natural parallelism upper
        bound. Scheduler may oversubscribe or undersubscribe (§4.10).
        """
        return len(self._state.get_mut_interior(0).morsels)

    def row_count_hint(self) -> Int:
        return self._state.get_mut_interior(0).total_rows

    def capabilities(self) -> SourceCapabilities:
        # Phase 5a: no hooks advertised. The source operates on data
        # that is already materialized; projection / decode-filter /
        # pushdown / dict-preservation are all upstream-of-here by
        # construction. Enabling any of these would require extending
        # the materialization driver (scan-dedup Phase 5c/5d), not the
        # source -- so we leave them off here.
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
        """Row count is known exactly; per-column stats are absent (the
        source has no access to Parquet footers). Phase 5d may widen
        this if a rewrite rule needs column stats on a materialized
        subplan.
        """
        return SourceStatistics()
