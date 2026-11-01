# =============================================================================
# MorselSink — RFC v4.2 Local/Global/Source/whole-segment-combine trait
# =============================================================================
#
# RFC v4.2 (an internal doc,
# additive on top of v4 an internal doc and v4.1 amendments)
# replaces the v3 per-worker-fold combine + single-arm finalize with the
# whole-segment combine shape (`combine(ref global, var states, ref
# reservation)`) and a two-arm finalize (`-> FinalizeOutput[Self]`).
#
# WHY THIS LANDS — gap6 fix-by-design
# ---------------------------------------------------------------
# The 18 Bucket A `UnsafePointer(to=struct.field).take_pointee()`
# partial-move sites institutionalized in the engine during Waves 2-4
# all stem from the v3 trait shape, where the driver had to extract
# Locals from a `_StreamingState` field via partial-move recovery and
# the per-worker-fold combine had no way to express "merge all workers
# at once". The v4.2 trait surface eliminates the partial-move pattern
# at the trait layer:
#   * `combine(ref global, var states, ref reservation)` consumes a
#     `Slab[OwnedPointer[Local]]` whole-segment — sink chooses merge
#     topology (sequential / partition-parallel / tree).
#   * `finalize(var sink_global) -> FinalizeOutput[Self]` returns a
#     two-arm result. v0.4 sinks always emit Finished (states=None,
#     sink_global=None); v0.5+ spill / streaming sinks emit
#     HasMoreOutput { ... }.
#   * `as_source(ref [o] sink_global) -> Source` lets the next-segment
#     pipeline borrow Global — no consume-by-move; supports recursive
#     CTE, multi-pipeline source, broadcast hash join (DuckDB §3 +
#     Daft (i)).
#   * `MemoryReservation` parameter on combine — DataFusion HIGH (A2-2);
#     forward-compat for v0.5 spill quota plumbing without re-migrating
#     23 sinks.
#   * `num_output_partitions` + `as_source_partition` defaults —
#     DataFusion Path A (A3-2); multi-partition source opt-in.
#   * `prepare_finalize` no-op default — DuckDB §6 missing-primitive;
#     reserved between combine_partition loop and finalize.
#
# Spike outcomes — an internal doc
# ----------------------------------------------------------------
#   * OQ-1 GREEN: parameterized `Self.Source: MorselSourceImpl` with
#     `o_global: Origin[mut=True]` parameter elaborates cleanly.
#   * OQ-5 RED: two simultaneous interior refs into
#     `Slab[OwnedPointer[Local]]` mis-lower borrow tracking — the
#     unwrap-per-iter fallback (`take_slot_unchecked(w) -> .take()`)
#     is canonical for any whole-segment combine that touches
#     multiple worker states.
#   * v4.1 MINOR-1 Option A (drop Slab → List): UNWORKABLE — `List[T]`
#     requires `T: Copyable`; `OwnedPointer[T]` is RegisterPassable
#     only. Step 1 ships Option B (keep Slab, add `set_len_unchecked(0)`
#     post-drain).
#
# Trait shape syntactic notes (carried from v4 doc + spikes)
# ---------------------------------------------------------
#   * `ref [o] name: T`, NOT `mut name: ref [o] T` (X1b).
#   * `def ... raises: ...` body, NOT `fn ... :` (X1b).
#   * `Self.` prefix on struct-parameter references inside struct bodies
#     and method signatures (X1c).
#   * Never use `global` as a parameter name — reserved word. Use
#     `sink_global` (X1c Q1).
#   * `raises` on `init_local`/`init_global` MUST be on the trait decl;
#     the impl alone cannot raise if the trait does not (NM-3 V3).
# =============================================================================

from std.builtin.swap import swap
from std.collections.optional import Optional
from std.memory import OwnedPointer
from std.atomic import Atomic

from komira_arrow.schema import RecordBatch
from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.local_dispatcher import LocalDispatcher
from komira_collections.slab import Slab
from .memory_reservation import MemoryReservation
from komira_morsel.morsel import Morsel
from komira_morsel.morsel_source import MorselSourceImpl
from komira_async_api.worker_pool_traits import KeepAlive


# =============================================================================
# SinkCapabilities — extensibility surface (RFC v2 §3.3, v4.1 amended)
# =============================================================================


@fieldwise_init
struct SinkCapabilities(Copyable, ImplicitlyCopyable, Movable, Deinitable):
    """Capability bit-set for a MorselSink impl.

    Default = fully-configured empty (`SinkCapabilities()`). Impls can
    fill in fields at construction time. Additions beyond v0.4 land as
    RFC addenda, never by widening trait bounds.

    Fields
    ------
    raw_column_format: format-native writer capability (legacy carry-over).

    supports_spill: sink declares it can survive running out of memory
        during consume by spilling Local state.

    (There is no `partitioned_combine` field. DELETED — see the
    `PARTITIONS_*` vocabulary below for why, and
    `scripts/check_sink_partition_contract.py` for the gate that keeps it
    deleted. In short: it was written by 22 sinks and read by nothing, and
    it was definitionally a restatement of `num_partitions() > 1`.)

    streaming_finalize: finalize returns incrementally — HasMoreOutput
        loop arm. Always False in v0.4.

    output_is_batch: finalize returns a meaningful RecordBatch (vs. a
        side-effecting writer that returns a tombstone). Most sinks True.

    max_combine_parallelism: hint to `CombinePartitionSegment` sizing.
        0 = unbounded (use the pool's worker count). Non-zero caps.

    supports_multi_phase: RFC v4.1 OQ-10 missing-primitive — DataFusion
        §5.3. Sinks that support `prepare_finalize`-followed-by-finalize
        with quota negotiation set True. v0.4 default False.

    requires_source_order: RFC v4.2 / v4.1 OQ-10 — DuckDB §6.3. Sinks
        that need source order (ordered Parquet write, BatchCopy,
        ASOFJoinSink) set True. Planner reads this to disable parallel
        morsel scheduling.
    """

    var raw_column_format: UInt8
    var supports_spill: Bool
    var streaming_finalize: Bool
    var output_is_batch: Bool
    var max_combine_parallelism: Int16
    var supports_multi_phase: Bool         # NEW v4.2 (DataFusion §5.3)
    var requires_source_order: Bool        # NEW v4.2 (DuckDB §6.3)

    def __init__(out self):
        """Default — non-partitioned, non-spilling, non-streaming, batch."""
        self.raw_column_format = UInt8(0)
        self.supports_spill = False
        self.streaming_finalize = False
        self.output_is_batch = True
        self.max_combine_parallelism = Int16(0)
        self.supports_multi_phase = False
        self.requires_source_order = False


# =============================================================================
# num_partitions vocabulary — a sink returning 1 must say WHICH 1 it means
# =============================================================================
#
# `num_partitions()` returning 1 is the sole gate that makes a sink's combine
# run DRIVER-SERIAL. Previously it was also the SILENT default: seventeen
# `MorselSink` impls carried a bare, uncommented `return 1`, and nothing
# anywhere distinguished the three very different facts that value can mean.
#
# All four constants are 1. They exist so the SOURCE says which one, and so
# `scripts/check_sink_partition_contract.py` can refuse a bare literal.
# A reviewer reading `return PARTITIONS_UNBUILT` learns something a reviewer
# reading `return 1` cannot: that parallel combine is available and unclaimed.
#
#   PARTITIONS_IMPOSSIBLE
#       The global state cannot be cut into disjoint pieces, so there is no
#       correct `combine_partition` to write. The canonical case is an OPEN
#       hash table (HashAggUntypedSink's FLAT route): two workers place the
#       same key at DIFFERENT slots, so a slot-range split is not disjoint and
#       a partition-parallel fold would CORRUPT GROUPS. This value is a
#       correctness statement — do not "optimise" it away.
#
#   PARTITIONS_TRIVIAL
#       The state IS splittable but `combine` already produced the whole
#       answer, so a partition fan-out would hand every worker zero work.
#
#   PARTITIONS_UNBUILT
#       The state can be partitioned disjointly and the arm was never built.
#       This is DEBT, not a property. The canonical case is the perfect-hash
#       route, whose slots are `key - key_min` and therefore disjoint by
#       construction. A site using this word MUST name the board card.
#
#   PARTITIONS_UNREVIEWED
#       Nobody has determined which of the three above applies. This is the
#       honest word for the seventeen pre-existing bare `return 1` sites that
#       were converted mechanically. The gate holds a FLOOR on how many of
#       these may exist and it only ever ratchets DOWN — replacing one with a
#       determined word is the only permitted edit direction.
#
# ⚠ Do NOT add a `Bool` capability restating any of this. That is precisely
# what `SinkCapabilities.partitioned_combine` was, and a second derivation of
# one fact is a thing that can silently disagree with the fact.
# -----------------------------------------------------------------------------
comptime PARTITIONS_IMPOSSIBLE: Int = 1
comptime PARTITIONS_TRIVIAL: Int = 1
comptime PARTITIONS_UNBUILT: Int = 1
comptime PARTITIONS_UNREVIEWED: Int = 1


# =============================================================================
# NeverMorselSource — zero-byte never-instantiated stub for non-composing sinks
# =============================================================================


from komira_arrow.schema import Schema
from komira_scan_source.source_capabilities import SourceCapabilities


@fieldwise_init
struct NeverMorselSource(MorselSourceImpl):
    """Sentinel `MorselSourceImpl` for sinks that don't compose.

    Sinks that only support `finalize` (terminal) and never `as_source`
    (non-terminal) declare `alias Source = NeverMorselSource` and
    inherit the default-raise body of `as_source`. The struct itself
    is never instantiated — the default trait body raises before any
    Source construction.

    Belt-and-suspenders: `as_source` raises first; the four conformant
    methods below also raise / return zeroes for any caller that
    bypasses the default body.
    """

    var _pad: UInt8

    def next_morsel(self, worker_id: Int) raises -> Optional[Morsel]:
        raise Error(
            "NeverMorselSource.next_morsel: this sink declared"
            " Source=NeverMorselSource and does not support as_source;"
            " caller should not have built this Source"
        )

    def output_schema(self) -> Schema:
        return Schema()

    def partition_hint(self) -> Int:
        return 0

    def row_count_hint(self) -> Int:
        return 0

    def capabilities(self) -> SourceCapabilities:
        return SourceCapabilities()


# =============================================================================
# FinalizeOutput[K: MorselSink] — two-arm finalize result (v4.1 A2-1, v4.2 A3-1)
# =============================================================================


struct FinalizeOutput[K: MorselSink](Movable, Deinitable):
    """Finalize result — the Finished arm carrier.

    A terminal `finalize` returns one of these: the `output` Slab the
    sink produced this round. The driver collects `output` and returns.

    NOE-T3 ruling (an internal doc §3,
    an internal doc): the dead `states` /
    `sink_global` re-thread fields are **removed**. They only existed to
    feed a `HasMoreOutput`-arm "re-thread a fresh `Global` back into
    `finalize`" loop that the rebuild SUPERSEDES — that loop forced a
    move-out of a non-Movable `Global: KeepAlive` (impossible; the
    `KeepAlive` RAII bound is deliberately non-Movable,
    `worker_pool_traits.mojo:53`), and it is the only mechanism that did.
    Bounded multi-yield instead lives at layer (B): the node's
    `materialize() → as_source(ref Global) → next_morsel` pull-stream,
    where the driver-owned `Global` is **borrowed** by the `Source` and
    never moved out. So `finalize` stays Finished-arm-only and
    byte-identical, and this carrier holds only `output`.

    Fields
    ------
    output: Slab of K.Output produced this round. Slab (not List) because
        the trait only constrains `K.Output: Deinitable` —
        not Copyable, which List would require. v0.4 / Finished-arm
        sinks emit exactly one Output per sink (slab of len 1).

    Why explicit __init__ (not @fieldwise_init): Slab's __init__ has a
    default-construct overload, but @fieldwise_init expects every field
    to be passable positionally and Slab[T] requires T to satisfy
    `Deinitable`. Mojo elaborates the explicit ctor
    cleanly; @fieldwise_init had trouble when K.Output had a non-trivial
    Output type during local testing.
    """

    var output: Slab[Self.K.Output]

    def __init__(
        out self,
        var output: Slab[Self.K.Output],
    ):
        self.output = output^


# =============================================================================
# MorselSink trait (RFC v4.2 final shape)
# =============================================================================


trait MorselSink(Movable, Deinitable):
    """Per-dispatch sink with Local/Global/Source/whole-segment-combine shape.

    See module header for the v3 → v4.2 design rationale and gap6
    fix-by-design framing.

    Threading model (v4.2)
    ----------------------
    1. Driver calls `init_global(out sink_global)` once (return-slot).
    2. Driver builds a `Slab[OwnedPointer[Local]]` of size num_workers,
       initializing each via `sink.init_local()`. The OwnedPointer wrap
       is the gap6-executor-level fix: heap-stable 8-byte handles in
       the byte-backed slab; Locals are heap-stashed individually.
    3. Workers call `consume_morsel(wid, ref local_i, ref sink_global,
       var morsel)` concurrently. Sinks that don't override
       `consume_morsel` inherit a default body that extracts batch and
       delegates to `consume(batch)`.
    4. After the streaming barrier (every worker drained):
       a. Driver builds `var states: Slab[OwnedPointer[K.Local]]` from
          the per-worker slab and calls
          `sink.combine(ref sink_global, var states, ref reservation)`
          ONCE — whole-segment.
       b. If `num_partitions(ref sink_global) > 1`, executor dispatches
          `combine_partition(ref sink_global, partition_idx)` across
          workers via `CombinePartitionSegment[S]`.
       c. Driver calls `prepare_finalize(ref sink_global)` (no-op
          default; v0.5+ TemporaryMemoryManager wiring).
    5. Driver calls finalize ONCE (terminal-collect):
       - `var fr = sink.finalize(var sink_global, dispatcher_ptr, ct)` returns
         `FinalizeOutput[Self]`. The driver passes
         `Pointer(to=dispatcher)` + a clone of the runtime cancel_token
         (Phase 1 Layer A2); sinks that need parallel dedup /
         partition-fan-out dispatch via
         `dispatcher_ptr[].run_with_state[..., ct^]`.
       - `finalize` is Finished-arm-only: the driver collects `fr.output`
         and returns. There is NO re-thread loop (NOE-T3 ruling):
         re-feeding a fresh non-Movable `Global` into `finalize` is
         structurally impossible, so bounded multi-yield does NOT live in
         `finalize`.
    6. For non-terminal / bounded-multi-yield plan shapes, the driver
       routes through `as_source(ref [o] sink_global) -> Source` and
       drains `Source.next_morsel(worker_id)` until `None` (layer (B);
       the driver-owned `Global` is BORROWED by the Source for its whole
       life, never moved out). Multi-partition output:
       `num_output_partitions` + per-partition `as_source_partition`.

    Gap6 audit
    ----------
    Every `K.Local` field tree must be reviewed against
    an internal doc §7.11 before merge:
      * Heap-owning fields (List[T], String, OwnedPointer[V],
        ArcPointer[V]) require an OwnedPointer wrap or InlineArray[T,N]
        replacement.
      * No wildcard-origin pointer fields (per bug #60 closure).
      * Run `pixi run lint-unsafe-pointer*` +
        `scripts/lint_wildcard_field.sh` on the touched files.
    """

    # Associated types
    # Local: Movable & Deinitable (v4 §3). Not Defaultable —
    # default-construction not required by the v4.2 driver flow (driver
    # builds Locals via `sink.init_local()`, not via a default ctor).
    # Defaultable would help placeholder-reinstall patterns in some
    # legacy combine bodies but those are eliminated by the whole-segment
    # combine shape, so the bound is unnecessary in v4.2.
    comptime Local: Movable & Deinitable
    comptime Global: KeepAlive
    comptime Output: Movable & Deinitable
    comptime Source: MorselSourceImpl

    # Lifecycle
    def init_local(self) raises -> Self.Local: ...

    def init_global(self, out sink_global: Self.Global) raises:
        ...

    # Hot path (unchanged from RFC v2)
    def consume[
        o_local: Origin[mut=True], o_global: Origin[mut=True],
    ](
        self,
        worker_id: Int,
        ref [o_local] local: Self.Local,
        ref [o_global] sink_global: Self.Global,
        var batch: RecordBatch,
    ) raises: ...

    # RFC v3 Path Y — sinks that need morsel metadata override; default
    # swaps the batch out of the morsel and delegates to consume(batch).
    def consume_morsel[
        o_local: Origin[mut=True], o_global: Origin[mut=True],
    ](
        self,
        worker_id: Int,
        ref [o_local] local: Self.Local,
        ref [o_global] sink_global: Self.Global,
        var morsel: Morsel,
    ) raises:
        var taken = RecordBatch()
        swap(taken, morsel.batch)
        _ = morsel^
        self.consume(worker_id, local, sink_global, taken^)

    # Combine — whole-segment, var-consumed states, ref-borrowed reservation
    # (RFC v4.1 A2-2: MemoryReservation forward-compat hook). Per OQ-5
    # spike outcome: impls SHOULD use the unwrap-per-iter shape
    # (`take_slot_unchecked(w) -> .take()`) rather than two simultaneous
    # `ref states.get_mut_interior(i)[]` borrows; the latter mis-lowers
    # borrow tracking on Mojo.
    def combine[
        o_global: Origin[mut=True], o_mem: Origin[mut=True],
    ](
        self,
        ref [o_global] sink_global: Self.Global,
        var states: Slab[OwnedPointer[Self.Local]],
        ref [o_mem] reservation: MemoryReservation,
    ) raises: ...

    # Partition-parallel barrier (unchanged from RFC v2 CL-4 / CL-5).
    #
    # THIS DEFAULT IS THE SILENT-SERIAL PATH. Inheriting it means "my combine
    # runs driver-serial" and says nothing about why. Overriding it with one of
    # the `PARTITIONS_*` words above is how a sink states which of the three
    # reasons applies; `scripts/check_sink_partition_contract.py` refuses a bare
    # `return 1` in any override so the choice cannot be skipped silently.
    def num_partitions[o: Origin](
        self, ref [o] sink_global: Self.Global
    ) -> Int:
        return PARTITIONS_UNREVIEWED

    def combine_partition[o_global: Origin[mut=True]](
        self,
        ref [o_global] sink_global: Self.Global,
        partition_idx: Int,
    ) raises:
        # Default no-op: non-partitioned sinks (returning 1 from
        # num_partitions) never see combine_partition called.
        pass

    # NEW v4.2 (RFC v4.1 OQ-10 + DuckDB §6 missing-primitive). Single-
    # threaded phase between combine_partition and finalize. v0.4 default
    # no-op; v0.5+ TemporaryMemoryManager wiring.
    def prepare_finalize[o: Origin[mut=True]](
        self,
        ref [o] sink_global: Self.Global,
    ) raises:
        pass

    # Terminal — choose ONE per dispatch (driver checks plan shape).
    # Contract (NOE-T3): finalize ALWAYS returns the Finished arm — one
    # `FinalizeOutput.output` Slab, no re-thread. Bounded multi-yield is
    # NOT routed through finalize (it would force a move-out of a
    # non-Movable Global); it lives in `as_source` -> `next_morsel`.
    #
    # Phase 1 Layer A2: migrated `pool_ptr: Pointer[WorkerPool, ...]`
    # to `dispatcher_ptr: Pointer[LocalDispatcher[NoopSink], ...]` +
    # `cancel_token: CancellationToken`. The substrate dispatcher API is
    # the new dispatch surface; sinks that want parallel finalize work
    # (e.g. CountDistinctAggSink's per-group `_dedup_*_with_pool` /
    # `_with_dispatcher`) call `dispatcher_ptr[].run_with_state[..., ct^]`.
    # Most sinks ignore both parameters entirely. Bug #60 / encapsulation
    # rule: the dispatcher ref lives on the call frame (per-dispatch),
    # never on a struct field — typed `disp_o` origin, no wildcard widening.
    def finalize[disp_o: Origin[mut=True]](
        self,
        var sink_global: Self.Global,
        dispatcher_ptr: Pointer[LocalDispatcher[NoopSink], disp_o],
        cancel_token: CancellationToken,
    ) raises -> FinalizeOutput[Self]: ...

    # Non-terminal — sink composes into next pipeline segment.
    # Default raise: sinks that don't compose declare
    # `alias Source = NeverMorselSource` and inherit this body.
    def as_source[o_global: Origin[mut=True]](
        self,
        ref [o_global] sink_global: Self.Global,
    ) raises -> Self.Source:
        raise Error("MorselSink.as_source: not supported by this sink")

    # NEW v4.2 — multi-partition output (DataFusion Path A, A3-2).
    # Default 1 (single-partition source). Override + return >1 for
    # partition-parallel output; must also override as_source_partition.
    def num_output_partitions[o: Origin](
        self,
        ref [o] sink_global: Self.Global,
    ) -> Int:
        return 1

    def as_source_partition[o_global: Origin[mut=True]](
        self,
        ref [o_global] sink_global: Self.Global,
        partition_idx: Int,
    ) raises -> Self.Source:
        # Default raises — misconfiguration (override num_output_partitions
        # without overriding this) surfaces immediately at runtime, not
        # silently as wrong output.
        raise Error(
            "MorselSink.as_source_partition: not supported by this sink"
            " (num_output_partitions returned >1 but as_source_partition"
            " is not implemented)"
        )

    # Capabilities (RFC v2 §3.3, v4.2-amended)
    def capabilities(self) -> SinkCapabilities:
        return SinkCapabilities()

    # Diagnostic label for the executor's combine trace (KOMIRA_COMBINE_TRACE).
    #
    # Read by exactly ONE caller — `combine_trace.emit_combine_trace`, inside the
    # executor's `if trace_on:` arm — which is the entire reason it exists. That
    # single reader is what makes this method different in kind from the deleted
    # `SinkCapabilities.partitioned_combine`: this is a NAME the executor prints,
    # not a PREDICATE that can silently disagree with behaviour.
    #
    # Sinks with a runtime route (HashAggUntypedSink's FLAT / PH / RADIX) should
    # fold the route into the label, so one trace line answers "which sink AND
    # which strategy" without a second field.
    #
    # The default is honest: a sink that has not said anything prints
    # `unlabeled`, and a census of `unlabeled` lines in a trace dump is a
    # to-do list rather than a false claim of coverage.
    def combine_trace_label(self) -> StaticString:
        return "unlabeled"
