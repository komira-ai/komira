# =============================================================================
# Morsel -- A chunk of rows for parallel processing
# =============================================================================
#
# A morsel is the unit of work in the morsel-driven scheduler. Each worker
# thread processes one morsel at a time through a pipeline of operators.
#
# Morsel sizes are auto-derived from the detected hardware profile and the
# (schema, operator-tier) pair. See `komira_engine_runtime.morsel_sizing_policy`
# for the formula + tier multipliers. Production callers should obtain a
# tier-correct size via `ctx.<tier>_morsel_rows(schema)` on `EngineContext`.
# The legacy `DEFAULT_MORSEL_ROWS = 65536` fallback in
# `komira_arrow.constants` is retained only for primitive constructors
# (e.g. `BatchMorselSource`, `ScanSource`) where ctx is not threaded; those
# callers receive an explicit value from any production code path.
#
# Reference: Rust morsel at komira-engine/src/morsel.rs
# Reference: playbook Phase 2 (Morsel-Driven Scheduler)
# =============================================================================

# =============================================================================
# CLUSTER-Z TODO: scheduled migration per an internal doc
# =============================================================================
# Each remaining MutExternalOrigin in this file is either (a) a load-bearing
# interior pointer awaiting redesign onto a tight origin, or (b) a temporary
# shim into a primitive that will be removed in Cluster Z (e.g. Slab /
# Slab / Slab / AtomicSlab _mut_ptr / _unsafe_base_ptr helpers
# preserved for migration source callers).
#
# Remediation: replace each wildcard with one of
#   * a typed `ref [origin] T` return / parameter,
#   * a private `UnsafePointer[T, concrete_origin]` field + `# SAFETY:`
#     comment (inside a single struct only),
#   * a byte-view (`ByteView` / `ByteViewMut`) + typed scalar reads/writes.
#
# See an internal doc §5 for canonical API shapes
# and an internal doc §8 for the Cluster Z schedule.
# The baseline at scripts/mut_external_origin_allowlist.txt is
# monotonic-shrinking; do NOT add new wildcard sites to this file.
# =============================================================================

from std.memory import alloc, unsafe_memcpy, OwnedPointer
from std.sys import size_of
from std.time import perf_counter_ns

from komira_arrow.schema import RecordBatch, RecordBatchBuilder, Schema, SchemaBuilder, Field
from komira_arrow.column import Column
from komira_arrow.arrow_types import ArrowType, arrow_fixed_byte_width
from komira_arrow.varlen_width_guard import check_fixed_width_dispatch
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_arrow.bitmap import Bitmap, copy_bits_aligned_buffer
from komira_arrow.boolean_array import BooleanArray
from komira_buffer.heap_region import HeapRegion
from komira_collections.slab import Slab

from komira_arrow.batch_format import BatchFormat, FormatKind

from .bypass_ref import ParquetBypassRef
from .varlen_slice import (
    _payload_window_shareable,
    _slice_variable_width,
)
from .hash_agg_decoded import HashAggDecodedRG


# =============================================================================
# MorselFmt[F: BatchFormat] -- ADDITIVE parametric morsel carrier (P-2.C.1)
# =============================================================================
#
# The format-parametric morsel. It carries an `F: BatchFormat` batch (always
# `ColumnNativeBatch` in v0.4) instead of the concrete `RecordBatch` the legacy
# `Morsel` below carries. This is the unit that flows through the column-native
# pipeline driver (`komira_engine_dispatch.column_pipeline.run_column_pipeline`)
# so the batch travels as a `ColumnNativeBatch` END-TO-END instead of
# round-tripping through `RecordBatch` at each op boundary.
#
# ADDITIVITY (P-2.C.1 — plan §I, §III): this struct is ADDED ALONGSIDE the
# concrete `Morsel(Movable)` below; the concrete `Morsel` is UNCHANGED. The live
# executor (`morsel_executor.mojo`, `_execute_plan_column`) consumes the concrete
# `Morsel`; the spine cutover that feeds `MorselFmt[ColumnNativeBatch]` through
# the column path is P-2.C.2 (sequenced behind the orientation-spine freeze). The two are different types at the type level, so the additive add is
# a no-op for every concrete-`Morsel` consumer.
#
# Named `MorselFmt[F]` (not `Morsel[F]`) so the additive parametric carrier and
# the concrete `Morsel` coexist without a name collision (Mojo does not overload
# a struct name across a parametric / non-parametric pair). The spike used
# `Morsel[F]`; the production rename keeps both live simultaneously, which is the
# whole point of the additive C.1 step.
#
# SPIKE-BANKED SHAPE (poc_batchformat_dispatch, ):
#   * field is `var batch: Self.F` (per the spike — NOT a bare `F`).
#   * carrier is `Slab[MorselFmt[F]]` (Movable-only); `List[MorselFmt[F]]` fails
#     because List requires the element be Copyable and `F` is Movable-only.
#   * per-F monomorph is disasm-verified zero indirect/vtable calls.
#
# The legacy `raw_chunks` / `hash_agg_decoded` fields are NOT carried here (plan
# §III): they are RecordBatch / parquet-decode-specific and migrate in a later
# slot if a column-native bypass / decode-fusion path is needed. The parametric
# `MorselFmt[F]` is the clean path.
# =============================================================================
struct MorselFmt[F: BatchFormat](Movable, Deinitable):
    """Format-parametric morsel: a chunk of one `F: BatchFormat` batch for the
    column-native pipeline driver.

    Additive alongside the concrete `Morsel(RecordBatch)` below (P-2.C.1). The
    BATCHFORMAT spike modeled the field as `var batch: Self.F`; the production
    carrier wraps it as `Optional[Self.F]` so the pipeline driver can lift the
    `F` batch out of the morsel via `Optional.take()` — the project-sanctioned
    partial-move replacement (a field is never moved out of the middle of a struct; `Optional.take()` is the sanctioned spelling), and the SAME shape the
    `ColumnNativeBatch._body: Optional[...]` foundation field uses for its
    `take_body`. A bare `self.batch^` on a struct with a custom `__init__`
    raises "field destroyed out of the middle of a value" on Mojo (the
    custom `__init__` blocks field-wise decomposition); `Optional.take()` leaves
    `self` destructor-safe (the Optional drops as `None`). The Optional is
    ALWAYS `Some` for a live morsel; `num_rows` / `batch_ref` `.value()` it
    unconditionally. The carrier is `Slab[MorselFmt[F]]` (Movable-only).
    """

    var batch: Optional[Self.F]
    var morsel_id: Int
    var partition_id: Int
    var origin_hint: Int

    def __init__(
        out self,
        var batch: Self.F,
        morsel_id: Int,
        partition_id: Int,
        origin_hint: Int = 0,
    ):
        """Create a MorselFmt[F] from an `F: BatchFormat` batch.

        Args:
            batch: The format batch to wrap. Ownership is transferred.
            morsel_id: Unique identifier for this morsel.
            partition_id: Identifier for the source partition.
            origin_hint: Optional intra-partition ordering hint; defaults to 0
                (same semantics as the concrete Morsel's origin_hint).
        """
        self.batch = Optional(batch^)
        self.morsel_id = morsel_id
        self.partition_id = partition_id
        self.origin_hint = origin_hint

    @always_inline
    def num_rows(self) -> Int:
        """Return the number of rows in this morsel's batch."""
        return self.batch.value().num_rows()

    def take_batch(var self) -> Self.F:
        """Consume the morsel and return its `F` batch via `Optional.take()`
        (the sanctioned replacement for a partial move out of a struct). The
        Optional is left `None`; the POD Int fields drop normally. The pipeline
        driver uses this to lift the native batch out of the carrier."""
        return self.batch.take()


struct Morsel(Movable):
    """A chunk of rows for parallel processing.

    Contains a RecordBatch (typed columns + schema) representing a subset of
    a larger dataset. Morsels are the unit of work in the morsel-driven
    scheduler -- each worker thread processes one morsel through a pipeline
    of operators.

    Fields:
        batch: The underlying RecordBatch holding column data.
        morsel_id: Unique identifier for this morsel within a pipeline.
        partition_id: Identifier for the source partition (e.g., row group).
        origin_hint: Phase 1e.1 intra-RG ordering hint. For sources that
            split a row group into multiple morsels, origin_hint is the
            sub-slot index (0-based) within the source partition; the sink
            sorts morsels by (partition_id, origin_hint) to restore
            row-group ordering. Defaults to 0 (single morsel per
            partition).
        raw_chunks: Phase 1e.3 opt #9 bypass columns. When the source
            emits raw compressed bypass chunks alongside the decoded
            `batch`, an opaque `ParquetBypassRef` lives here.
            Downstream write-side sinks (parquet-internal) resolve the
            ref back to a List[RawColumnChunk] via the parquet-internal
            `resolve_to_raw_chunks` helper and splice the bytes into
            the output parquet without re-encoding.

            `None` when bypass is not active for this morsel; most
            sinks (including ParquetCollectSink which materializes to
            one RecordBatch) just carry the field through unchanged.

            Type-erasure note (cycle-fix,
            an internal doc §2.4 path iii): the
            field type is `Optional[ParquetBypassRef]` rather than
            `Optional[List[RawColumnChunk]]` so this `komira_morsel`
            package does NOT depend on `komira_parquet`. Engine
            consumers see the opaque ref and pass it through; only
            parquet-internal code resolves it.
    """

    var batch: RecordBatch
    var morsel_id: Int
    var partition_id: Int
    var origin_hint: Int
    # PERF-CRITICAL: bypass raw chunks. When present, the listed columns
    # were NOT decoded into `batch` -- the decode cost was skipped and
    # the raw compressed bytes are preserved for a downstream writer to
    # emit unchanged. The actual payload is owned in
    # `komira_parquet/parquet_bypass_payload.mojo`; this field carries
    # an opaque ArcPointer'd ref (POD; refcount-bump on copy). Carrying
    # `None` is free (sizeof(Optional<...>) is a few machine words).
    var raw_chunks: Optional[ParquetBypassRef]
    # Phase I-A (Wave 9 v4.1.3): decode-fused hash agg
    # payload. When the parquet source is given a `hash_agg_key_col_idx`
    # cap, it precomputes the per-row hash + fingerprint + partition_id
    # for the group-by key column and attaches the bundle here. The
    # SLAB hash agg sink's consume() body then probes against the
    # precomputed buffers instead of recomputing per-row.
    #
    # `OwnedPointer` wrapping keeps the field cost to a single
    # machine-word handle (Optional[OwnedPointer[T]] is 8B handle +
    # tag-byte) when the cap is not set; the heap allocation cost is
    # paid only on the decode-fused path.
    #
    # `None` for every non-hash-agg morsel (the steady-state for joins,
    # filters, sorts, and the uncapped agg path). Sinks that don't
    # consume the field carry it through unchanged on Morsel handoffs.
    var hash_agg_decoded: Optional[OwnedPointer[HashAggDecodedRG]]

    def __init__(
        out self,
        var batch: RecordBatch,
        morsel_id: Int,
        partition_id: Int,
        origin_hint: Int = 0,
    ):
        """Create a Morsel from a RecordBatch.

        Args:
            batch: The RecordBatch to wrap. Ownership is transferred.
            morsel_id: Unique identifier for this morsel.
            partition_id: Identifier for the source partition.
            origin_hint: Optional intra-partition ordering hint; defaults
                to 0. See the struct docstring.
        """
        self.batch = batch^
        self.morsel_id = morsel_id
        self.partition_id = partition_id
        self.origin_hint = origin_hint
        self.raw_chunks = None
        self.hash_agg_decoded = None

    def attach_bypass_ref(mut self, var ref_handle: ParquetBypassRef) -> None:
        """Phase 1e.3 opt #9: attach a parquet bypass-payload ref to this morsel.

        Called by parquet-internal source code after it has read (but not
        decoded) the raw bytes for configured bypass columns and built a
        `ParquetBypassRef` via
        `komira_parquet.parquet_bypass_payload.from_raw_chunks(...)`.

        Idempotent-ish: a second call replaces the previous attachment.

        Cycle-fix: signature changed from
        `attach_raw_chunks(List[RawColumnChunk])` to
        `attach_bypass_ref(ParquetBypassRef)` to keep `komira_morsel`
        free of any `komira_parquet` import. Audit confirmed no
        production caller invoked the old method as of ``.
        """
        self.raw_chunks = ref_handle^

    @always_inline
    def has_raw_chunks(self) -> Bool:
        """Return True iff this morsel carries a bypass payload ref."""
        return Bool(self.raw_chunks)

    def attach_hash_agg_decoded(
        mut self, var dec: OwnedPointer[HashAggDecodedRG],
    ) -> None:
        """Phase I-A: attach a decode-fused hash-agg payload to this morsel.

        Called by the parquet source's `next_morsel` when the
        `hash_agg_key_col_idx` cap is set and the per-RG decode produced
        a non-empty `HashAggDecodedRG`. Idempotent-ish: a second call
        replaces the previous attachment.
        """
        self.hash_agg_decoded = dec^

    @always_inline
    def has_hash_agg_decoded(self) -> Bool:
        """Return True iff this morsel carries a Phase I-A decode-fused
        hash-agg payload."""
        return Bool(self.hash_agg_decoded)

    @staticmethod
    def empty(morsel_id: Int, partition_id: Int) -> Morsel:
        """Create an empty Morsel with zero rows and zero columns.

        Args:
            morsel_id: Unique identifier for this morsel.
            partition_id: Identifier for the source partition.

        Returns:
            A Morsel containing an empty RecordBatch.
        """
        var batch = RecordBatch()
        return Morsel(batch^, morsel_id, partition_id)

    def replace_batch(mut self, var batch: RecordBatch):
        """Replace this morsel's `batch` with `batch`, dropping the old one.

        S5 (OpChainAdapter review): the safe, encapsulated batch
        swap for streaming operators that rebuild `morsel.batch` in place
        (filter survivors, projected columns, joined output). Body is a plain
        field-assign — `self.batch = batch^` drops the old RecordBatch and
        moves the new one in, destructor-safe on every path. This is NOT a
        partial move (the banned shape moves a field OUT of the middle
        of a struct; assigning INTO a field is fine — same idiom as
        `attach_bypass_ref`'s `self.raw_chunks = ref_handle^` and
        `MorselArray.set_morsel`). It deliberately does NOT reimplement the
        old `UnsafePointer(to=self.batch).destroy_pointee()/init_pointee_move()`
        dance (MapOp had that inline) — the whole point is a safe body with no
        raw pointer arithmetic.

        Replaces the BATCH ONLY. Any unapplied selection mask on the outgoing
        batch is dropped — callers that must preserve a mask across the swap
        transfer it onto `batch` themselves BEFORE calling (see
        `map_op.mojo`'s `has_selection_mask`/`set_selection_mask` block). The
        POD `morsel_id`/`partition_id`/`origin_hint` and the `raw_chunks`/
        `hash_agg_decoded` Optionals are untouched.

        Args:
            batch: The replacement RecordBatch. Ownership is transferred.
        """
        self.batch = batch^

    def take_batch(deinit self) -> RecordBatch:
        """Consume the morsel and return its underlying RecordBatch.

        Mojo rejects a single-field `^`-move out of the MIDDLE of a
        struct with a custom `__init__` ("field destroyed out of the middle of
        a value") — the rest of the struct can no longer be destroyed. This
        whole-value consume (`deinit self`) is the encapsulation-preferred way
        to extract the heap-owning `batch` field without a copy and without a
        partial-move: the caller hands ownership of the WHOLE morsel in, and
        gets the RecordBatch out (the `raw_chunks` / `hash_agg_decoded` Optional
        fields auto-drop as part of the `deinit`). Mirrors
        `ConsumeSegment.take_stream_bytes(deinit self)` / `MorselFmt.take_batch`.

        Every caller hands an OWNED morsel in via `^` (`m^.take_batch()`) and
        treats it as consumed: the streaming sink lifts the delta batch out for
        the broker produce path (`broker_streaming_sink.mojo`), and the fused-agg
        column pipeline lifts the batch out at the breaker ingress
        (`column_pipeline.mojo`). A prior `take_batch(var self)` swap variant
        (campaign PHASE2) was reconciled away into this one (commit unbreaking
        main): both lifted the same `RecordBatch` out, no caller
        needed the moved-from morsel to survive, and `deinit self` is the
        encapsulation-preferred destroy-on-consume with no extra empty-batch
        alloc.
        """
        return self.batch^

    # --- Accessors ---

    @always_inline
    def num_rows(self) -> Int:
        """Return the number of rows in this morsel."""
        return self.batch.num_rows()

    @always_inline
    def num_columns(self) -> Int:
        """Return the number of columns in this morsel."""
        return self.batch.num_columns()

    @always_inline
    def column_at(self, index: Int) -> ref [self.batch._columns._bytes] Column[HeapRegion]:
        """Return a safe reference to the Column[HeapRegion] at the given index.

        The reference's lifetime is tied to the Morsel's batch column storage.
        Preferred over _column_ref() for all new code.

        Args:
            index: Zero-based column index.

        Returns:
            An immutable reference to the Column.
        """
        return self.batch.column_at(index)

    def _column_ref[
        _mut: Bool, o: Origin[mut=_mut], //,
    ](ref [o] self, index: Int) raises -> UnsafePointer[Column[HeapRegion], o]:
        """Return a pointer to the Column[HeapRegion] at the given index
        with ORIGIN TIED to this Morsel.

        R3.2g.followup.2 fix: previously returned MutExternalOrigin
        (wildcard); see RecordBatch._column_ref docstring for rationale.

        Delegates to RecordBatch._column_ref (also origin-poly). The
        returned pointer's origin is bound to `self`, so the compiler
        statically tracks deref liveness against the Morsel.

        SAFETY: pointer valid for duration of `self`'s borrow `o`.
        """
        return self.batch._column_ref(index).unsafe_mut_cast[
            _mut
        ]().unsafe_origin_cast[o]()


# =============================================================================
# MorselArray -- Owning array of Morsels backed by Slab
# =============================================================================


struct MorselArray(Movable, Sized):
    """An owning array of Morsels, backed by Slab[Morsel].

    All slots are always initialized (either with real data or empty morsels).
    Slab handles destruction automatically.
    """

    var _inner: Slab[Morsel]

    def __init__(out self):
        """Create an empty MorselArray."""
        self._inner = Slab[Morsel]()

    def __init__(out self, count: Int):
        """Allocate a MorselArray with `count` slots, all initialized to empty morsels.

        Args:
            count: Number of morsel slots to allocate.
        """
        self._inner = Slab[Morsel].create(max(count, 0))
        for i in range(count):
            self._inner.append(Morsel.empty(i, 0))

    @always_inline
    def __len__(self) -> Int:
        """Return the number of morsels."""
        return len(self._inner)

    @always_inline
    def __getitem__(self, index: Int) -> ref [self._inner._bytes] Morsel:
        """Return a safe reference to the morsel at the given index.

        The reference's lifetime is tied to this MorselArray's storage.
        Preferred over _morsel_ref() for all new code.

        Args:
            index: Zero-based morsel index.

        Returns:
            An immutable reference to the Morsel.
        """
        return self._inner[index]

    #: the deprecated `_morsel_ref(index)`
    # wildcard-origin raw-pointer accessor was DELETED (zero callers; the
    # last 2 test callers migrated to the safe origin-tied `__getitem__`).
    # Use `array[index]` (`ref [self._inner._bytes] Morsel`) for safe
    # access — holding the wildcard raw pointer across heap-owning
    # RecordBatch field reads was the gap6 byte-slab + wildcard hazard.

    def replace_morsel(mut self, index: Int, var morsel: Morsel):
        """Replace the morsel at the given index, destroying the old one.

        Args:
            index: Zero-based morsel index.
            morsel: The new Morsel. Ownership is transferred.
        """
        self._inner.set(index, morsel^)

    def set_morsel(mut self, index: Int, var morsel: Morsel):
        """Replace the morsel at `index` (safe: destroys old, inits new).

        Args:
            index: Zero-based morsel index.
            morsel: The Morsel to store. Ownership is transferred.
        """
        self._inner.set(index, morsel^)

    @staticmethod
    def from_morsel_slab(var morsels: Slab[Morsel]) -> MorselArray:
        """Wrap an already-built `Slab[Morsel]` as a MorselArray (move).

        DIRECT-N-STREAMING: the multi-batch BatchMorselSource
        splits each of its N input batches into a per-batch MorselArray,
        drains them into ONE combined `Slab[Morsel]` (so the source's
        atomic cursor spans all N batches), then wraps the result here.
        No copy — the slab moves in wholesale. The default `__init__`
        leaves `_inner` empty; we reseat it by move. Mojo's custom-ctor
        decomposition rule (see MorselFmt header note) forbids a bare
        `result._inner^` move-out, but move-IN via assignment is fine.
        """
        var result = MorselArray()
        result._inner = morsels^
        return result^

    def drain_morsels_into(mut self, mut target: Slab[Morsel]):
        """Move every morsel out of `self` into `target`, leaving `self`
        empty (a valid, destructor-safe zero-morsel array).

        DIRECT-N-STREAMING: the move-out primitive for
        concatenating N per-batch MorselArrays into the combined slab the
        multi-batch BatchMorselSource's cursor walks. Drains via the
        encapsulated `Slab.take_slot_unchecked` (the partial-move-safe
        primitive defined inside `slab.mojo`) rather than a per-element
        `take_pointee` in this module, and resets `self`'s length to 0 so
        its destructor is a no-op. No copy — each morsel moves once.
        """
        var n = len(self._inner)
        for i in range(n):
            target.append(self._inner.take_slot_unchecked(i))
        self._inner.set_len_unchecked(0)

    def total_rows(self) -> Int:
        """Return the total row count across all morsels.

        Returns:
            Sum of num_rows() across all morsels.
        """
        var total = 0
        for i in range(len(self._inner)):
            total += self._inner[i].num_rows()
        return total

    @always_inline
    def num_rows_at(self, index: Int) -> Int:
        """Return the row count of the morsel at the given index.

        Args:
            index: Zero-based morsel index.

        Returns:
            Number of rows in that morsel.
        """
        return self._inner[index].num_rows()


# =============================================================================
# MorselView -- Zero-copy view into a RecordBatch range
# =============================================================================


struct MorselView(Copyable, Movable):
    """A zero-copy descriptor of a row range within a parent RecordBatch.

    A MorselView is a 2-Int POD recording a [start_row, start_row+num_rows)
    span; it does NOT carry any pointer back to the parent batch's column
    storage. Consumers extract typed column pointers BEFORE entering the
    parallelize barrier (anchored to `comptime bo = origin_of(batch)`)
    and read those tight-origin pointers indexed by `vp.start_row`. The
    parent batch's lifetime is held by the dispatching frame (synchronous
    fork-join semantics — see an internal doc §3); MorselView
    itself owns no borrow.

    Item 5 Tier 1a closure: the prior `_columns:
    UnsafePointer[Column, MutExternalOrigin]` field was the last
    wildcard-origin field in `komira_morsel/`. It was unused in
    production (the `_col_data_ptr_f64` / `borrow_col_f64` accessors had
    zero callers — every consumer pre-extracts typed column pointers
    onto its parametric State). Pure dead-code removal closes the gap6
    hazard at `:343` without touching the public source-trait shape.

    Fields:
        start_row: First row index in the parent batch.
        num_rows: Number of rows in this view.
    """

    var start_row: Int
    var num_rows: Int

    def __init__(
        out self,
        start_row: Int,
        num_rows: Int,
    ):
        """Create a MorselView describing a row range.

        Args:
            start_row: Starting row index in the parent batch.
            num_rows: Number of rows in this view.
        """
        self.start_row = start_row
        self.num_rows = num_rows


struct MorselViewArray(Movable, Sized):
    """An owning array of MorselViews, backed by Slab[MorselView].

    MorselViews are trivially copyable (2 Ints — start_row + num_rows;
    Item 5 Tier 1a). Slab handles allocation and destruction.
    """

    var _inner: Slab[MorselView]

    def __init__(out self, capacity: Int):
        """Create an empty MorselViewArray with the given capacity.

        Args:
            capacity: Number of view slots to pre-allocate.
        """
        self._inner = Slab[MorselView].create(max(capacity, 0))

    @always_inline
    def __len__(self) -> Int:
        """Return the number of views."""
        return len(self._inner)

    def append(mut self, var view: MorselView):
        """Append a MorselView to the array.

        Args:
            view: The MorselView to add. Ownership is transferred.
        """
        self._inner.append(view^)

    @always_inline
    def __getitem__(self, index: Int) -> ref [self._inner._bytes] MorselView:
        """Return a safe reference to the MorselView at the given index.

        The reference's lifetime is tied to this MorselViewArray's storage.
        Preferred over _view_ref() for all new code.

        Args:
            index: Zero-based view index.

        Returns:
            An immutable reference to the MorselView (Copyable, so callers
            may also copy out via `var v = arr[i]`).
        """
        return self._inner[index]

    #: the deprecated `_view_ref(index)`
    # wildcard-origin raw-pointer accessor was DELETED (zero callers).
    # Use `arr[i]` for safe origin-tied ref access.


def split_into_views(
    batch: RecordBatch, morsel_size: Int
) -> MorselViewArray:
    """Split a RecordBatch into zero-copy MorselViews.

    Each view records a row range within `batch`. No column-pointer is
    captured on the view (Item 5 Tier 1a): consumers
    pre-extract typed column pointers anchored to
    `comptime bo = origin_of(batch)` BEFORE the parallelize dispatch
    and index them by `vp.start_row`. Parent batch lifetime is held by
    the dispatching frame's synchronous fork-join barrier — see
    an internal doc §3.

    Args:
        batch: The RecordBatch to split (borrowed, not consumed).
        morsel_size: Maximum number of rows per view.

    Returns:
        A MorselViewArray of zero-copy views covering all rows.
    """
    var total_rows = batch._num_rows
    var num_cols = batch.num_columns()

    if total_rows == 0 or num_cols == 0:
        var result = MorselViewArray(1)
        result.append(MorselView(0, 0))
        return result^

    var num_views = (total_rows + morsel_size - 1) // morsel_size
    var views = MorselViewArray(num_views)

    for i in range(num_views):
        var start_row = i * morsel_size
        var rows_in_view = min(morsel_size, total_rows - start_row)
        views.append(MorselView(start_row, rows_in_view))

    return views^


# =============================================================================
# split_record_batch -- Split a RecordBatch into a MorselArray
# =============================================================================


def split_record_batch(
    var batch: RecordBatch,
    morsel_size: Int,
    string_view: Bool = True,
    trace_phases: Bool = False,
) raises -> MorselArray:
    """Split a RecordBatch into a MorselArray.

    Each morsel contains up to `morsel_size` rows; the last may contain fewer.

    ⚠ "COLUMNS ARE COPIED" WAS THIS DOCSTRING'S CLAIM AND HAS
    BEEN FALSE. It said *"Columns are copied (not zero-copy
    sliced) because Mojo does not yet have shared-ownership buffers
    (ArcPointer)"*; the copy-elim flip made the Arc reslice
    unconditional, so a NON-NULLABLE offset-honoring column is an Arc refcount
    bump with no memcpy. The stale sentence is corrected here rather than
    deleted because it is not harmless: it is the reason a decomposition that
    correctly localised 40.1 ms/rep to this function on q21 then attributed the
    cost to a data copy. MEASURED on that query, the largest of the three splits
    (3.79 M rows x 3 INT64) copies **zero** bytes — `copy_slices=0` on the
    `trace_phases` line — and the cost was per-morsel CONSTRUCTION, most
    of it rebuilding an invariant `Schema` once per morsel. Read the counter, do
    not read this paragraph.

    What is still copied, and it is a real cost when it fires: any column the
    `supports_zero_copy_slice()` whitelist declines (BOOL, nested) or that
    carries a validity bitmap. `copy_slices` / `copy_rows` on the counter line
    are how you price it.

    Plain STRING / BINARY are NOT on that list any more (lane G L3,
    2026-09-25): their PAYLOAD is an Arc window share of the source's data
    buffer, and only the (rows + 1) Int32 offsets and the validity bits are
    rebuilt — see `_slice_variable_width` for the layout and the aliasing
    argument, and `strview_slices` / `strview_rows` on the counter line for
    the arming count. `string_view=False` restores the payload copy (the A/B
    arm and the rollback path).

    Args:
        batch: The RecordBatch to split. Ownership is transferred.
        morsel_size: Maximum number of rows per morsel.
        string_view: Whether a plain STRING / BINARY column's payload is an Arc
            window share of the source's data buffer (the default) or a copy.
        trace_phases: Print one `SPLIT_PHASE` counter line per call.

    Returns:
        A MorselArray covering all rows in the batch.
    """
    var total_rows = batch.num_rows()
    var num_cols = batch.num_columns()

    if total_rows == 0:  # a count-only batch (no columns) still has rows
        return MorselArray(1)

    # SELECTION-VECTOR #2 (KOMIRA_SEL_PIPE): if the input batch carries a
    # deferred `_selection_mask`, the split must slice it per sub-morsel so the
    # (dense columns, mask) contract survives re-chunking — otherwise the split
    # would drop the mask and the consumer would over-aggregate the rejected
    # rows. Byte-neutral for every existing caller: no batch reaching split
    # carries a mask on the non-sel-pipe path, so `mask_opt` is None and no
    # sub-mask is built.
    var mask_opt = batch.take_selection_mask()

    var num_morsels = (total_rows + morsel_size - 1) // morsel_size

    # ONE SCHEMA REBUILD, NOT `num_morsels` OF THEM.
    #
    # Every morsel gets the SAME schema — it is `batch.schema` with nothing
    # changed. This used to run `_clone_schema_builder(batch.schema)` +
    # `SchemaBuilder.build()` INSIDE the per-morsel loop, i.e. it reconstructed a
    # `Field` per column (8 heap-owning members each), appended it into a
    # 15-parallel-`List` builder, and then copied that builder into a
    # 17-`List` `Schema` — once per morsel. On q21's 3.79 M-row probe that is
    # 2782 morsels x 3 columns, and it MEASURED as 8.60 ms of the split's
    # 17.10 ms, i.e. HALF the window, for a value that is invariant across the
    # loop.
    #
    # The template is built ONCE with exactly the old helper, so the schema VALUE
    # is bit-for-bit what it was (`_clone_schema_builder` drops table-level
    # metadata and preserves per-field parameters — both behaviours preserved by
    # construction, because it is still the thing that builds it). Each morsel
    # then takes `template.copy()`, which is one pass over the parallel lists
    # instead of three. `RecordBatchBuilder.build` may mutate its OWN copy (the
    # DICTIONARY-vs-STRING reconcile at `record_batch.mojo`), which is why each
    # morsel still needs its own copy and not a share — and why the template must
    # never be handed out by move.
    var schema_template_builder = _clone_schema_builder(batch.schema)
    var schema_template = schema_template_builder.build()

    # APPEND, DON'T PREFILL-THEN-REPLACE. `MorselArray(num_morsels)` fills every
    # slot with `Morsel.empty(i, 0)` — each of which constructs a `RecordBatch`,
    # hence a 17-`List` empty `Schema` — and `set_morsel` then destroys it to put
    # the real morsel in. That is `num_morsels` whole batch construct/destroy
    # pairs whose only observable effect is being overwritten. The slab is sized
    # exactly, so the appends never grow it.
    var morsel_slab = Slab[Morsel].create(num_morsels)

    # VECTOR-NATIVE INC-3 (design §B.1, DEFAULT-ON post copy-elim flip):
    # the RG->chunk reslice becomes an Arc refcount bump instead of a per-column
    # memcpy. A column whose layout honors `_offset` (fixed-width /
    # boolean / DECIMAL / DICTIONARY) AND carries NO validity bitmap is sliced via
    # `Column.slice` (zero-copy Arc view); STRING/BINARY/nested (accessors ignore
    # `_offset`) AND any NULLABLE column fall back to the copy slice so the result
    # is always byte-correct. (Since lane G L3, 2026-09-25, plain STRING/BINARY
    # take a THIRD arm between the two: the payload is Arc-shared as a WINDOW,
    # the offsets and validity are rebuilt rebased, so `_offset` stays 0 and the
    # `_offset`-ignoring accessors stay correct. Nullable included.)
    #
    # UNCONDITIONAL (kill-switch retirement sweep): the
    # `KOMIRA_ARC_RESLICE_OFF` kill-switch and the prior no-op opt-in
    # `KOMIRA_ARC_RESLICE` are both DELETED. The per-column COPY arm
    # (`_slice_column`) is NOT dead — it is the live path for every layout the
    # `supports_zero_copy_slice() and not _validity` gate declines — and the
    # arc-view-vs-source byte identity is guarded flag-free by
    # `tests/engine/test_arc_reslice_byte_equiv.mojo` (which reads the SOURCE
    # column directly at `start + i`, an independent oracle).
    #
    # NULLABLE EXCLUSION (): a zero-copy slice shares the WHOLE-
    # column validity bitmap and carries `_offset > 0`, so a valid-row lookup on
    # the result is `validity.test(_offset + i)`, NOT `validity.test(i)`. Every
    # post-split morsel column has, until now, upheld the copy-path invariant
    # (`_offset == 0` with validity rebased to bit 0), so raw `validity.test(i)`
    # readers are correct. A NULLABLE Arc-view morsel column with `_offset > 0`
    # silently breaks those readers. Diverting nullable columns to the copy slice
    # preserves the invariant — `_slice_column` rebases validity to a fresh 0-based
    # window bitmap and returns `_offset = 0` — while KEEPING zero-copy for the
    # common, perf-critical non-nullable numeric aggregands (there is no validity
    # to misread, so `_offset > 0` is safe). The nullable fallback copies the data
    # buffer too; only the non-null path stays zero-copy.

    # DARK COUNTER (`trace_phases`) — the fire-set for the schema-hoist
    # above. `schema_builds` is the falsifier: it is 1 with the hoist and would
    # be `num_morsels` without it, and unlike a wall it survives a loaded box.
    # `copy_slices` / `copy_rows` price the OTHER half of this window (the
    # layouts the zero-copy gate declines), so a future reader can tell a
    # per-morsel-overhead problem from a byte-copy problem without re-deriving
    # it — which is what this campaign had to do to find the lever at all.
    var _dg = trace_phases
    var _dg_t0 = perf_counter_ns() if _dg else 0
    var _dg_zc = 0
    var _dg_copy = 0
    var _dg_copy_rows = 0
    var _dg_view = 0
    var _dg_view_rows = 0

    # LANE G L3 — STRING / BINARY PAYLOAD VIEWS. `string_view` is DEFAULT ON;
    # `string_view=False` sends every variable-width column back to the payload
    # COPY, byte-identical by construction.

    for m in range(num_morsels):
        var start_row = m * morsel_size
        var rows_in_morsel = min(morsel_size, total_rows - start_row)

        # Build a new RecordBatch for this morsel from per-column row windows.
        # `with_capacity` sizes the column slab exactly, so the adds below never
        # grow it.
        var builder = RecordBatchBuilder.with_capacity(num_cols)

        for c in range(num_cols):
            ref src_col_ptr = batch.column_at(c)
            var arrow_type = src_col_ptr.arrow_type
            if (
                src_col_ptr.supports_zero_copy_slice()
                and not src_col_ptr._validity
            ):
                # Zero-copy Arc view (refcount++, NO memcpy) — byte-identical
                # reads to `_slice_column` for offset-honoring NON-NULLABLE
                # layouts. Nullable columns are excluded above (their shared
                # validity bitmap is offset-based); they take the copy slice.
                var morsel_col = src_col_ptr.slice(start_row, rows_in_morsel)
                builder.add_column(morsel_col^)
                _dg_zc += 1
            elif (
                string_view
                and (
                    arrow_type == ArrowType.STRING
                    or arrow_type == ArrowType.BINARY
                )
                and _payload_window_shareable(
                    src_col_ptr, start_row, rows_in_morsel
                )
            ):
                # Payload VIEW: rebased offsets + rebased validity are fresh,
                # the payload bytes are an Arc window share of the source's.
                # Same layout as the copy arm below (`_offset == 0`,
                # `offsets[0] == 0`), so no reader needs to honour an offset.
                var morsel_col = _slice_variable_width(
                    src_col_ptr, start_row, rows_in_morsel, arrow_type, True
                )
                builder.add_column(morsel_col^)
                _dg_view += 1
                _dg_view_rows += rows_in_morsel
            else:
                var morsel_col = _slice_column(src_col_ptr, start_row, rows_in_morsel, arrow_type)
                builder.add_column(morsel_col^)
                _dg_copy += 1
                _dg_copy_rows += rows_in_morsel

        var morsel_batch = (builder.build(schema_template.copy()) if num_cols > 0
                            else RecordBatch.count_only(rows_in_morsel))

        if mask_opt:
            # Slice the [start_row, start_row+rows_in_morsel) window of the
            # selection mask into a fresh non-nullable BooleanArray. One bit
            # per row (~1/64th the cost of the fixed-width column slices above)
            # and only fires on the partial-selectivity RGs that actually carry
            # a mask.
            ref full_mask = mask_opt.value()
            var sub_mask = BooleanArray.allocate(rows_in_morsel)
            for i in range(rows_in_morsel):
                if full_mask.get(start_row + i):
                    sub_mask.set(i, True)
            morsel_batch.set_selection_mask(sub_mask^)

        morsel_slab.append(Morsel(morsel_batch^, m, 0))

    if _dg:
        print("SPLIT_PHASE rows=", total_rows, " cols=", num_cols,
              " morsels=", num_morsels, " schema_builds=1",
              " zc_slices=", _dg_zc, " copy_slices=", _dg_copy,
              " copy_rows=", _dg_copy_rows,
              " strview_slices=", _dg_view, " strview_rows=", _dg_view_rows,
              " total_us=", Int(perf_counter_ns() - _dg_t0) // 1000, sep="")

    return MorselArray.from_morsel_slab(morsel_slab^)


def _clone_schema_builder(schema: Schema) -> SchemaBuilder:
    """Clone a Schema into a SchemaBuilder for building sub-batches.

    ★★ A `Field` IS NOT THREE FIELDS — `field_at_unchecked`, NEVER
    `Field(name, arrow_type, nullable)`.

    This used to read the source Field's NAME, ARROW TYPE and NULLABLE and
    construct a fresh `Field` from those three, which SILENTLY DROPPED every
    other slot: decimal precision/scale, timestamp unit and timezone, the
    dictionary index type, the flag bitfield, per-field kv metadata, and
    nested children. Splitting a `decimal128(12, 2)` batch therefore produced
    sub-batches whose field said `decimal128(0, 0)` while the unscaled int128
    bytes were copied intact — `Decimal('40.00')` becomes `Decimal('4000')`,
    every value 100x wrong, with no refusal anywhere.

    ⚠ THIS IS ONE STEP DOWNSTREAM OF `parquet_source.mojo`'s ten emit sites,
    which carried the identical defect and were fixed in the same campaign:
    `ColumnarMultiConsumerSource.next_morsel` calls
    `_split_and_stash_first` -> `split_record_batch` -> here whenever a decoded
    row group exceeds `morsel_rows`. Fixing only the ten would have produced an
    engine that returns the right decimal for a small scan and the wrong one
    for a large one. an internal Bazel target cannot see this half —
    its fixtures are SIX rows and `DEFAULT_MORSEL_ROWS` is three orders of
    magnitude larger — so the falsifier is
    an internal Bazel target, which splits a
    two-column batch and asserts the parameters, not the `arrow_type`.

    Args:
        schema: The schema to clone.

    Returns:
        A SchemaBuilder with the same fields, PARAMETERS INCLUDED.
    """
    var sb = SchemaBuilder()
    for i in range(schema.num_columns()):
        sb.add_field(schema.field_at_unchecked(i))
    return sb^


def _slice_column(
    col: Column[HeapRegion], start: Int, length: Int, arrow_type: ArrowType
) raises -> Column[HeapRegion]:
    """Create a new Column[HeapRegion] containing a slice of `col` from [start, start+length).

    Copies the relevant range of the underlying data buffer. This is used
    by split_record_batch to partition columns into morsel-sized chunks.

    Args:
        col: The source column (read-only reference).
        start: Starting row index.
        length: Number of rows to copy.
        arrow_type: The ArrowType of the column.

    Returns:
        A new Column owning copies of the sliced data.
    """
    if arrow_type == ArrowType.INT8 or arrow_type == ArrowType.UINT8:
        return _slice_fixed_width(col, start, length, 1, arrow_type)
    elif arrow_type == ArrowType.INT16 or arrow_type == ArrowType.UINT16 or arrow_type == ArrowType.FLOAT16:
        return _slice_fixed_width(col, start, length, 2, arrow_type)
    elif arrow_type == ArrowType.INT32 or arrow_type == ArrowType.UINT32 or arrow_type == ArrowType.FLOAT32:
        return _slice_fixed_width(col, start, length, 4, arrow_type)
    elif arrow_type == ArrowType.INT64 or arrow_type == ArrowType.UINT64 or arrow_type == ArrowType.FLOAT64:
        return _slice_fixed_width(col, start, length, 8, arrow_type)
    elif arrow_type == ArrowType.STRING or arrow_type == ArrowType.BINARY:
        # Phase 1f.4: variable-width slicing for STRING / BINARY. Rebases
        # the offsets so offsets[0] == 0 after slicing; copies only the
        # payload bytes in [offsets[start], offsets[start+length]).
        # Reached only when the payload-VIEW arm in `split_record_batch`
        # declined (kill switch, or a window `_payload_window_shareable`
        # refused), so this is the COPY arm by construction.
        return _slice_variable_width(col, start, length, arrow_type, False)
    elif arrow_type == ArrowType.DICTIONARY:
        # Phase 5d-A: dict-preserving slice. Without this branch the
        # DICTIONARY column hits the 8-byte fixed-width fallback, which
        # reads past the int32 index buffer and drops _dict_data /
        # _dict_size entirely. Consumers would see arrow_type ==
        # DICTIONARY but no dict payload -- the silent dict->flat
        # fallback flagged in project_unfuse_phase5d_review.md hazard #1.
        return _slice_dictionary(col, start, length)
    elif arrow_type == ArrowType.BOOL:
        # BIT-PACKED BOOL ARM (G4 site 7).
        #
        # ⛔ THIS SITE WAS IN THE *OVER-READ* REGIME, NOT THE RAISE REGIME,
        # AND IS THE ONLY ONE OF THE SEVEN THAT WAS. It never routed through
        # `compiler_helpers.element_size`, so `` making the width
        # oracle REFUSE bit-packed BOOL did not reach it: the `else` arm below
        # is a hardcoded `_slice_fixed_width(..., 8, ...)`, and
        # `check_fixed_width_dispatch` only refuses `carries_offsets(at) or
        # carries_children(at)` — BOOL is NEITHER. A bool column walked
        # through the guard into an 8-bytes-per-row slab copy of a buffer
        # holding `(n + 7) >> 3` bytes.
        #
        # It therefore did not fail loudly. It returned WRONG ROWS. MEASURED
        # before this arm, on a 40-row batch split into morsels of 16:
        # `morsel 1 row 2` (source row 18, `18 % 3 == 0` so True) came back
        # False — because `byte_start = (0 + 16) * 8 = 128` into a 5-byte
        # bitmap. Pinned by
        # `tests/engine/test_g4_bool_morsel_split_silent_overread.mojo`.
        #
        # ⚠ AT `start == 0` THE DEFECT HID: the over-read's first `(n+7)>>3`
        # bytes ARE the bitmap, so single-morsel splits returned correct
        # values and read the path as covered. That test is landed alongside
        # the falsifier so the asymmetry stays visible.
        #
        # Reachability is total, not incidental: `split_record_batch` takes
        # the zero-copy `Column.slice` path only for
        # `supports_zero_copy_slice() and not _validity`, and BOOL is
        # deliberately NOT on that whitelist (bit-packed — a non-byte-aligned
        # `_offset` needs bit-shift handling). So EVERY bool column in a
        # multi-morsel split lands here.
        #
        # `copy_bits_aligned_buffer` is the shared primitive, the same one
        # `arrow/copy_column_ref.mojo`, `compiler_helpers._copy_column`,
        # `scan_source.next_morsel`, `scheduler._build_morsel_for_filter` and
        # `arrow_helpers/batch_slice` use. `src_offset + start` is a BIT
        # index; the old arm multiplied it by 8 and called the product a byte
        # address. Validity follows `_slice_fixed_width`'s convention exactly:
        # rebased to a fresh 0-based window bitmap, `offset=0` on the output.
        var src_bit_offset = col._offset + start
        var bm_bytes = (length + 7) >> 3
        var bool_data = OwnedAlignedBuffer(max(bm_bytes, 1))
        bool_data.zero()
        if length > 0:
            copy_bits_aligned_buffer(
                bool_data, 0, col._data, src_bit_offset, length
            )
        bool_data.set_length(Int64(bm_bytes))

        var bool_validity = Optional[Bitmap[HeapRegion]](None)
        var bool_null_count = 0
        if col._validity:
            var vbm = Bitmap.create(length)
            Bitmap.copy_bits_into(
                vbm, 0, col._validity.value(), src_bit_offset, length
            )
            bool_null_count = length - vbm.popcount()
            bool_validity = vbm^

        return Column[HeapRegion](
            arrow_type=ArrowType.BOOL,
            data=bool_data^,
            offsets=None,
            validity=bool_validity^,
            length=length,
            null_count=bool_null_count,
            offset=0,
        )
    else:
        # For other types, fall back to the 8-byte fixed-width path.
        # BOOL used to land here and is handled by its own arm above.
        #
        # ⚠ GUARD (string_t S0): the DICTIONARY arm immediately
        # above was added because "without this branch the DICTIONARY column
        # hits the 8-byte fixed-width fallback, which reads past the int32
        # index buffer and drops _dict_data / _dict_size entirely". That is
        # EXACTLY what still happens here to LARGE_STRING / LARGE_BINARY
        # (Int64 offsets) and LIST / LARGE_LIST / MAP / STRUCT / UNION_* —
        # the STRING/BINARY arm above does not match them, `_slice_fixed_width`
        # reads length*8 bytes of UTF-8/child payload and returns
        # `offsets=None` while copying `arrow_type` through. The DICTIONARY
        # fix was never swept to its siblings; this is that sweep.
        #
        # ⛔ THE WIDTH IS ASKED OF THE ONE TABLE; IT IS NOT THE CONSTANT 8.
        #    (, 2026-09-20)
        #
        # This arm was `_slice_fixed_width(col, start, length, 8, arrow_type)`
        # — a NINTH copy of the width ladder, spelled as a constant, and the
        # one `arrow_types.arrow_fixed_byte_width`'s own header did not name
        # among the eight it unified. Every fixed-width type WIDER or NARROWER
        # than 8 bytes that reaches here was sliced at the wrong stride:
        #
        #   DECIMAL128 / INTERVAL_MONTH_DAY_NANO (16)  HALF of every value,
        #       and a data buffer sized `n * 8` under a Column claiming `n`
        #       rows — so every downstream 16-byte read of row >= n/2 runs
        #       PAST THE ALLOCATION. MEASURED on the corpus's
        #       `join_anti/decimal128_12_2/nulls` cell: six rows of
        #       decimal128(12,2), ANTI-joined, came back
        #       `[30.75, 0.00, NULL, <uninitialised>]` where the answer is
        #       `[30.75, 40.00, NULL, 60.99]` — and the fourth value DIFFERED
        #       BETWEEN PROCESSES (`0.00` / `92233720368547758.08` (2^63/100) /
        #       `1521418525514419703049951881235596045.26`), which is what an
        #       out-of-bounds read looks like when it is reported as a number.
        #   DECIMAL256 (32)                            THREE QUARTERS dropped.
        #   DATE32 / TIME32_S / TIME32_MS /
        #   INTERVAL_YEAR_MONTH (4)                    DOUBLE-width over-read.
        #
        # ⚠ IT ONLY FIRES ON A **NULLABLE** COLUMN, WHICH IS WHY IT SURVIVED.
        # `split_record_batch` takes the zero-copy `Column.slice` path for
        # `supports_zero_copy_slice() and not _validity`, and DECIMAL IS on
        # that whitelist — so a decimal column with NO nulls never reaches
        # here and reads correctly. The corpus's `full` / `single` variants
        # are exactly that column; its `nulls` variant is the one that reds.
        #
        # ⛔ DO NOT RESTORE A CONSTANT HERE. `arrow_fixed_byte_width` RAISES
        # for the layouts that have no per-element width (BOOL, FIXED_SIZE_*,
        # NULL, the *_VIEW family); every one of them was previously copied at
        # 8 bytes/row into a Column that claimed to be that type, which is a
        # malformed column, not a working path. See that function's header.
        check_fixed_width_dispatch("morsel._slice_column", arrow_type, length)
        return _slice_fixed_width(
            col, start, length, arrow_fixed_byte_width(arrow_type), arrow_type
        )


def _slice_fixed_width(
    col: Column[HeapRegion], start: Int, length: Int, elem_size: Int, arrow_type: ArrowType
) raises -> Column[HeapRegion]:
    """Slice a fixed-width column by copying the relevant byte range.

    Args:
        col: Source column.
        start: Starting row (relative to the column's own offset).
        length: Number of rows to copy.
        elem_size: Byte width per element.
        arrow_type: The ArrowType for the output column.

    Returns:
        A new Column with the sliced data.
    """
    var src_offset = col._offset
    var byte_start = (src_offset + start) * elem_size
    var byte_len = length * elem_size

    var data_buf = OwnedAlignedBuffer(max(byte_len, 1))
    if byte_len > 0:
        # Z.4c: bulk byte copy via origin-preserving view.
        data_buf.copy_from_view(
            col._data.view_range_ro(byte_start, byte_len)
        )
    else:
        data_buf.set_length(0)


    # Copy validity bitmap slice if present.
    #
    # SIMD sprint 1/2: replaced per-bit
    # `for i: validity.test(src_offset+start+i); bm.set/clear(i)` loop
    # with `Bitmap.copy_bits_into` (memcpy-backed bulk copy when offset
    # is byte-aligned) + SIMD `popcount` for null_count. Audit anchor:
    # T1-2 / cluster_c b5 profile (`_slice_fixed_width` 816 samples =
    # 3rd hottest non-agg site).
    var validity = Optional[Bitmap[HeapRegion]](None)
    var null_count = 0
    if col._validity:
        var bm = Bitmap.create(length)
        Bitmap.copy_bits_into(
            bm, 0, col._validity.value(), src_offset + start, length
        )
        null_count = length - bm.popcount()
        validity = bm^

    var out = Column[HeapRegion](
        arrow_type=arrow_type,
        data=data_buf^,
        offsets=None,
        validity=validity^,
        length=length,
        null_count=null_count,
        offset=0,
    )
    # DECIMAL (p, s) IS PER-COLUMN, NOT PART OF THE ArrowType — the same carry
    # `arrow_helpers/batch_slice._slice_batch_first_n` and
    # `arrow/concat._concat_columns_nway_fixed_width` make. The 7-arg ctor
    # leaves `_decimal_p`/`_decimal_s` at 0, and a Column that carries no
    # (p, s) is one `Column.as_decimal128` REFUSES outright.
    out._decimal_p = col._decimal_p
    out._decimal_s = col._decimal_s
    return out^


def _slice_dictionary(col: Column[HeapRegion], start: Int, length: Int) raises -> Column[HeapRegion]:
    """Slice a DICTIONARY column from [start, start+length).

    Phase 5d-A: dict preservation through BatchMorselSource. Ports the
    v0.3 DictLowCard invariant -- indices are cheap to slice (int32, 4B
    each) but the dictionary payload (values + offsets) must survive
    slicing so downstream dict-aware agg/filter can use the raw index
    as a group id.

    Layout (matches Column.from_dictionary / Column.as_dictionary):
        _data       : int32 indices, one per row
        _offsets    : int32 dict-offsets buffer, (dict_size + 1) entries
        _dict_data  : UTF-8 bytes for the dictionary strings
        _dict_size  : number of dict entries
        _validity   : optional bitmap over the indices

    Dict payload is replicated per slice (non-shared-buffer path). True
    ArcPointer buffer sharing is deferred to a Column refactor. The
    replication cost is bounded by dict cardinality, not row count --
    cheap on low-card columns (the only shape where dict preservation
    is a win in the first place).

    SAFETY: reads indices via pointer arithmetic on _data; validity
    mirrors _slice_fixed_width. Output Column owns all its buffers;
    no aliased storage escapes.
    """
    comptime int32_size = size_of[Int32]()

    # PERF-READ-4b: handle BOTH the string dict shape (int32 codes
    # + dict offsets + packed bytes) AND the NUMERIC dict shape (int32/int64
    # codes + flat numeric dict values, NO offsets, discriminated by
    # `is_numeric_dict()`). Before this, the slice hardcoded int32 codes and
    # RAISED on the numeric shape (missing _offsets) — breaking the sub-morsel
    # split of an in-scan-filter survivor batch carrying a numeric dict column.
    var is_num_dict = col.is_numeric_dict()
    var code_w = col._dict_index_byte_width

    # 1. Clone codes[col._offset + start : col._offset + start + length] at the
    #    column's own code byte width.
    var src_offset = col._offset
    var idx_byte_start = (src_offset + start) * code_w
    var idx_bytes = length * code_w
    var idx_buf = OwnedAlignedBuffer(max(idx_bytes, 1))
    if idx_bytes > 0:
        # Z.4c: bulk byte copy via origin-preserving view.
        idx_buf.copy_from_view(
            col._data.view_range_ro(idx_byte_start, idx_bytes)
        )
    else:
        idx_buf.set_length(0)


    # 2. Replicate dict offsets buffer (string dict only — numeric has none).
    var dict_offsets_opt = Optional[OwnedAlignedBuffer](None)
    if not is_num_dict:
        if not col._offsets:
            raise Error(
                "_slice_dictionary: string DICTIONARY column missing dict"
                " offsets"
            )
        ref src_offsets = col._offsets.value()
        var dict_offsets_bytes = (col._dict_size + 1) * int32_size
        var dict_offsets_buf = OwnedAlignedBuffer(
            max(dict_offsets_bytes, int32_size)
        )
        if dict_offsets_bytes > 0:
            # Z.4c: whole-buffer copy via origin-preserving view.
            dict_offsets_buf.copy_from_view(
                src_offsets.view_range_ro(0, dict_offsets_bytes)
            )
        else:
            dict_offsets_buf.set_length(0)
        dict_offsets_opt = dict_offsets_buf^


    # 3. Replicate dict_data payload.
    if not col._dict_data:
        raise Error("_slice_dictionary: DICTIONARY column missing dict data")
    ref src_dict_data = col._dict_data.value()
    var dict_data_len = src_dict_data.len()
    var dict_data_buf = OwnedAlignedBuffer(max(dict_data_len, 1))
    if dict_data_len > 0:
        # Z.4c: whole-buffer copy via origin-preserving view.
        dict_data_buf.copy_from_view(
            src_dict_data.view_range_ro(0, dict_data_len)
        )
    else:
        dict_data_buf.set_length(0)


    # 4. Validity slice over indices, bit-for-bit copy (absolute
    # coordinates include src_offset, per Arrow validity convention).
    var validity = Optional[Bitmap[HeapRegion]](None)
    var null_count = 0
    if col._validity:
        var bm = Bitmap.create(length)
        for i in range(length):
            if not col._validity.value().test(src_offset + start + i):
                bm.clear(i)
                null_count += 1
            else:
                bm.set(i)
        validity = bm^

    var out_col = Column[HeapRegion](
        arrow_type=ArrowType.DICTIONARY,
        data=idx_buf^,
        offsets=dict_offsets_opt^,
        validity=validity^,
        length=length,
        null_count=null_count,
        offset=0,
    )
    # _dict_data / _dict_size are not in the main Column ctor signature;
    # assign post-construction, matching Column.from_dictionary.
    # R3.3.D Batch 3: _dict_data field flipped to Optional[SAB]; bridge here.
    out_col._set_dict_data_from_oab(dict_data_buf^)
    out_col._dict_size = col._dict_size
    # PERF-READ-4b: carry the code-width + value-dtype discriminator so the
    # sliced column keeps its numeric-dict identity (string dicts keep width 4
    # / value-dtype invalid — unchanged).
    out_col._dict_index_byte_width = code_w
    out_col._dict_value_dtype = col._dict_value_dtype
    return out_col^
