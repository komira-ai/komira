# =============================================================================
# distinct_state.mojo — DistinctState[*Keys], the stage DISTINCT breaker state
# =============================================================================
#
# Dedups rows by their key columns (`distinct_key_column`) through a
# salt-packed open-addressing directory (`_DistinctDirectory`) over a dense,
# insertion-ordered row index, and emits each distinct key combination once at
# drain. It is a `komira_operator_api` `BreakerState` (combinable across
# workers) and a `komira_engine_runtime` `SpillableOp`: under memory pressure
# its rows spill as THSPLC column chunks and are restored through the same
# dedup.
#
# Pointer rules: no `UnsafePointer` in any signature, no wildcard origin;
# storage is `List` of POD.
# =============================================================================


from std.collections import Optional
from std.memory import bitcast
from std.os import abort
from std.sys import size_of

from komira_counters.keyeq_census import keyeq_record, KEYEQ_DISTINCT_DICTARM, KEYEQ_DISTINCT_DENSEARM, KEYEQ_DISTINCT_ROWBYTES, KEYEQ_DISTINCT_COMBINE
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.string_array import StringArray
from komira_arrow.schema import (
    ArrowType,
    Field,
    RecordBatch,
    RecordBatchBuilder,
    Schema,
    SchemaBuilder,
)
from komira_arrow.batch_view import BatchView, scalar_arrow_type
from komira_arrow.band_view import BandView
from komira_udf.float_quotient_order import (
    canonical_bits_f32,
    canonical_bits_f64,
    float_quotient_eq_f32,
    float_quotient_eq_f64,
)

from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_buffer.byte_view import ByteView

from komira_operator_api.breaker_state_trait import (
    BreakerState,
    BreakerStateCombinable,
)
from komira_operator_api.emit_at_offset_target import (
    _EmitColDesc,
    _EmitColTarget,
    EMIT_KIND_INELIGIBLE,
    EMIT_KIND_FIXED,
    EMIT_KIND_STRING,
)
from komira_expr.stage_program import BREAKER_DISTINCT
from komira_engine_runtime.spill.spill_storage import ChunkId, SpillStorage
from komira_engine_runtime.spill.spillable_op import SpillableOp
from komira_engine_runtime.spill.thsplc import THSPLCDecoder, THSPLCEncoder
from komira_engine_runtime.spill.column_native_shims import (
    column_native_from_record_batch,
    record_batch_from_column_native,
)
from komira_arrow.column_native import ColumnNativeBatch


from komira_op_agg_distinct.distinct_key_column import (
    DISTINCT_DIR_INITIAL_CAPACITY,
    DISTINCT_FNV_OFFSET,
    DistinctKeyColumn,
    DistinctKeyColumn_Typed,
    _DISTINCT_EMPTY_SLOT,
    _DISTINCT_IDX_MASK,
    _DISTINCT_SALT_SHIFT,
    _distinct_salt_of,
    _distinct_salt_stride,
)

# =============================================================================
# §2b — _DistinctDirectory — the O(1)-probe open-addressing dedup directory
# =============================================================================
#
# A salt-packed open-addressing directory with an O(1)-amortized per-row
# probe — the same mechanism the untyped column-format hash path uses, and the
# same mechanism `dense_hash_agg_table._DenseAggDirectory` ships for the agg
# primitive.
#
# # Why a thin in-module directory, NOT a verbatim `_DenseAggDirectory` reuse
#
# `_DenseAggDirectory` bakes in single-Int64 key storage (`keys: List[Int64]`)
# and `_hash_key_int64` (single-key Knuth mix), so it can only dedup one Int64
# key. `DistinctState` already stores composite, multi-DType keys SoA in
# `key_cols: Tuple[*Keys]`, deduping on a COMBINED FNV-1a hash across the pack.
# So we reuse the value-type-AGNOSTIC HALF of `_DenseAggDirectory` — the
# salt-packed directory + cached_hash side array + grow/rehash — and delegate
# full-key EQUALITY back to `DistinctState`'s key columns (the probe loop lives
# in `DistinctState.feed_row`, where `Scalar[dt]` + per-key `equals_row` are in
# scope; this directory owns only the directory math). `GrowableHashSetI64`
# wraps `_DenseAggDirectory` but is likewise single-Int64-key only; the untyped
# `_CompositeHashTableF64` is the runtime-tagged `ColumnValue`/`List[String]`
# path, reusing which would discard the typed-DType advantage that is the whole
# point of the typed primitive.
#
# The directory stores a packed (salt | dense_idx) word per slot, where
# dense_idx is the insertion-order index into `DistinctState`'s SoA key columns
# (== the row's index in `key_cols[k].values`). cached_hash[dense_idx] is the
# full 64-bit combined hash, used to rehash directory-only on grow (the SoA key
# columns NEVER move on resize, so dense_idx is stable for the set's lifetime —
# the same index-stability invariant `_DenseAggDirectory` relies on).
#
# # Encapsulation invariants (the pointer rules)
#   - Storage = `List[UInt64]` POD (directory + cached_hash). by construction (mirror of `_DenseAggDirectory`'s POD storage).
#   - NO `UnsafePointer` in any method signature; no wildcard origins.
#   - `Movable`-able + `Copyable` (all-POD `List[UInt64]` fields auto-synth).
#   - No partial-move via take_pointee — whole-struct moves / by-value access.
# =============================================================================


@fieldwise_init
struct _DistinctDirectory(Copyable, Movable):
    """Salt-packed open-addressing directory mapping a combined key hash to a
    dense insertion-order stored-row index (into `DistinctState`'s SoA key
    columns). Value-type-agnostic: owns only the directory words + the per-row
    cached hash, never the key values themselves.

    Storage (all `List[POD]`):
      - directory:   List[UInt64]  packed (salt | dense_idx) word per slot.
      - cached_hash: List[UInt64]  full 64-bit combined hash per stored row
                                   (indexed by dense_idx; used on resize).
      - capacity:    Int           power-of-2 directory slot count.
      - n_used:      Int           number of stored distinct rows (== dense len).
    """

    var directory: List[UInt64]
    var cached_hash: List[UInt64]
    var capacity: Int
    var n_used: Int

    @staticmethod
    def new(
        initial_capacity: Int = DISTINCT_DIR_INITIAL_CAPACITY,
    ) -> _DistinctDirectory:
        """Construct an empty directory with at-least `initial_capacity` slots
        (rounded up to power-of-2). Sentinel-filled; cached_hash starts empty."""
        var cap = 1
        while cap < initial_capacity:
            cap = cap * 2
        var dir = List[UInt64](capacity=cap)
        for _ in range(cap):
            dir.append(_DISTINCT_EMPTY_SLOT)
        return _DistinctDirectory(
            directory=dir^,
            cached_hash=List[UInt64](),
            capacity=cap,
            n_used=0,
        )

    def __init__(out self):
        """Default-construct (DISTINCT_DIR_INITIAL_CAPACITY slots)."""
        self = _DistinctDirectory.new(DISTINCT_DIR_INITIAL_CAPACITY)

    @always_inline
    def clear(mut self):
        """Reset the directory + drop the cached hashes (after a spill empties
        the key columns). Re-uses the existing slot allocation."""
        for i in range(self.capacity):
            self.directory[i] = _DISTINCT_EMPTY_SLOT
        self.cached_hash.clear()
        self.n_used = 0

    @always_inline
    def _insert_word(mut self, slot_start: Int, salt: UInt64, dense_idx: Int):
        """Probe from `slot_start` with the salt-stride; write the packed word
        into the first empty slot. Used by insert + rehash (mirror of
        `_DenseAggDirectory._insert_into_directory`)."""
        var mask = UInt64(self.capacity - 1)
        var stride = _distinct_salt_stride(salt, mask)
        var slot = UInt64(slot_start) & mask
        var packed = (salt << UInt64(_DISTINCT_SALT_SHIFT)) | UInt64(dense_idx)
        while True:
            if self.directory[Int(slot)] == _DISTINCT_EMPTY_SLOT:
                self.directory[Int(slot)] = packed
                return
            slot = (slot + stride) & mask

    def _grow(mut self):
        """Double the directory capacity + rehash directory-only off the dense
        `cached_hash` side array (mirror of `_DenseAggDirectory._grow`). The SoA
        key columns are never moved, so every dense_idx stays stable."""
        var new_cap = self.capacity * 2
        var new_dir = List[UInt64](capacity=new_cap)
        for _ in range(new_cap):
            new_dir.append(_DISTINCT_EMPTY_SLOT)
        self.directory = new_dir^
        self.capacity = new_cap
        var mask = UInt64(new_cap - 1)
        for g in range(self.n_used):
            var h = self.cached_hash[g]
            var salt = _distinct_salt_of(h)
            self._insert_word(Int(h & mask), salt, g)

    @always_inline
    def maybe_grow(mut self):
        """Grow BEFORE an insert if at the ~0.67 load threshold, so the new row
        lands in the larger directory (mirror of `_DenseAggDirectory`)."""
        if self.n_used >= (self.capacity * 2) // 3:
            self._grow()

    @always_inline
    def commit_insert(mut self, slot: UInt64, salt: UInt64, h: UInt64):
        """Record a NEW distinct row: assign the next dense_idx, stash its
        combined hash, write the packed directory word at the (already-probed)
        empty `slot`. The caller (`DistinctState`) has already appended the row's
        key values to the SoA columns at this same dense_idx."""
        var dense_idx = self.n_used
        self.cached_hash.append(h)
        self.directory[Int(slot)] = (
            salt << UInt64(_DISTINCT_SALT_SHIFT)
        ) | UInt64(dense_idx)
        self.n_used = self.n_used + 1


# =============================================================================
# §3 — DistinctState[*Keys] — the variadic dedup set
# =============================================================================


struct DistinctState[*Keys: DistinctKeyColumn](
    Defaultable, Movable, BreakerStateCombinable, SpillableOp
):
    """Variadic-arity DISTINCT set over `*Keys` key columns.

    SoA storage: `key_cols: Tuple[*Self.Keys]` (one `DistinctKeyColumn` per key,
    each owning its `List[Scalar[dt]]` of distinct values) + an open-addressing
    `_dir: _DistinctDirectory` dedup directory + `n_used: Int`. Per-row dedup: compute the combined FNV-1a
    hash, probe the salt-packed directory (O(1) amortized, salt-stride open
    addressing — the SAME mechanism `_DenseAggDirectory` ships for the agg
    primitive and the untyped column-format hash uses for distinct); on a
    salt-match candidate compare ALL key positions for equality (a hash collision
    is NOT a match — full-key equality is required), on an empty-slot miss append
    the row's keys to every column + insert into the directory.

    Key domain: fixed-width numeric and STRING keys with no NULLs. The state
    stores values only, no validity, so `feed_row` raises on a NULL key rather
    than merge it with the raw value in the null slot. A NULL-aware DISTINCT
    must be routed to another implementation.

    `Movable`-only, NOT `Copyable` — the `Tuple[*Self.Keys]` field is not
    `Copyable` (Mojo 1.0.0b1 does not synthesize `Copyable` for a `Tuple` over a
    trait-bounded pack). Same as `HashAggTable` / `SortBuffer`; the `Stage` owns
    the state and moves it, never copies.

    Single-key Int64 = `DistinctState[DistinctKeyColumn_Typed[int64, 0]]`;
    composite = `DistinctState[DistinctKeyColumn_Typed[int64, 0],
    DistinctKeyColumn_Typed[int64, 1]]`.

    DISTINCT semantics permit UNORDERED output; this emits in INSERTION
    order (the SoA Lists are sequential — mirrors the LIVE
    `runtime_breaker_state.finalize_distinct_composite_i64i64`). Downstream sinks
    that need ordering compose Sort over DISTINCT.

    Parameters:
        Keys: Variadic pack of `DistinctKeyColumn_Typed[dt, col]` conformers —
            one per DISTINCT key column.
    """

    var key_cols: Tuple[*Self.Keys]
    # The open-addressing dedup directory maps a combined key hash -> dense
    # insertion-order row index, so per-row dedup is O(1) amortized.
    var _dir: _DistinctDirectory
    var n_used: Int
    # --- SPILL metadata (SpillableOp conformance) ---
    # ChunkId is POD (single UInt64), so `List[ChunkId]` is a
    # POD-element list; `_age_ticks`
    # and `_restoring` are POD scalars. No heap-owning Movable struct element,
    # no wildcard-origin pointer field.
    var _spill_chunks: List[ChunkId]
    var _age_ticks: UInt64
    var _restoring: Bool

    def __init__(out self, var key_cols: Tuple[*Self.Keys]):
        """Construct from the (moved) per-key column tuple."""
        self.key_cols = key_cols^
        self._dir = _DistinctDirectory.new()
        self.n_used = 0
        self._spill_chunks = List[ChunkId]()
        self._age_ticks = UInt64(0)
        self._restoring = False

    def __init__(out self):
        """Nullary (`Defaultable`) ctor. Builds the per-key column pack via the pack-aware
        `Tuple[*Self.Keys]()` default ctor — each slot's `DistinctKeyColumn`
        `Defaultable` no-arg ctor produces an empty column. This is the seam the
        field-less `VariadicDistinctFactory[*Keys].make_state` drives (mirrors
        `HashAggTable[KB, *Aggs]`'s nullary ctor).

        Byte-identical to `DistinctState(Tuple(K0.new(16), ...))` modulo the
        initial List reserve: an empty dedup set with no accumulated rows."""
        self.key_cols = Tuple[*Self.Keys]()
        self._dir = _DistinctDirectory.new()
        self.n_used = 0
        self._spill_chunks = List[ChunkId]()
        self._age_ticks = UInt64(0)
        self._restoring = False

    @staticmethod
    @always_inline
    def arity() -> Int:
        """Number of DISTINCT keys (the `*Keys` pack length)."""
        return Self.Keys.__len__()

    @staticmethod
    def state_tag() -> Int:
        """`BreakerState` discriminator — DistinctState backs the DISTINCT arm.
        Lets `Stage.__init__` comptime-assert `(Breaker, BState)` consistency."""
        return BREAKER_DISTINCT

    @always_inline
    def size(self) -> Int:
        """Number of distinct rows accumulated so far."""
        return self.n_used

    @always_inline
    def _hash_row[bo: Origin[mut=False]](
        self, batch: BatchView[bo], row: Int
    ) -> UInt64:
        """Combined FNV-1a hash of `row`'s full key tuple (fans `@parameter for`
        over the key pack — each slot folds its own bound column's value)."""
        var h = DISTINCT_FNV_OFFSET

        comptime for k in range(Self.Keys.__len__()):
            h = self.key_cols[k].hash_step[bo](h, batch, row)
        return h

    @always_inline
    def _row_equals_stored[bo: Origin[mut=False]](
        self, stored_idx: Int, batch: BatchView[bo], row: Int
    ) -> Bool:
        """True iff EVERY key column's value at `stored_idx` equals `row`'s value
        off the matching bound column. The full-key dedup compare (a hash hit is
        a candidate; this confirms a true match — not a collision)."""

        comptime for k in range(Self.Keys.__len__()):
            if not self.key_cols[k].equals_row[bo](stored_idx, batch, row):
                return False
        return True

    @always_inline
    def feed_row[bo: Origin[mut=False]](
        mut self, batch: BatchView[bo], row: Int
    ) raises:
        """`BreakerState` executable surface. Dedup one input row: hash
        the full key tuple, probe the open-addressing directory (O(1) amortized,
        salt-stride); on a salt-match candidate confirm full-key equality; if the
        row is NEW (probe lands on an empty slot) append its keys to every column
        and insert into the directory. Duplicates are skipped (no per-row emit —
        DISTINCT is a pipeline breaker).

        The directory probe is the salt-packed open-addressing mechanism that
        `_DenseAggDirectory` (agg) + the untyped column-format hash (distinct)
        use; the per-key equality check delegates to the SoA key columns.

        Raises on a NULL key (see the key domain in the class docstring)."""
        comptime for k in range(Self.Keys.__len__()):
            if self.key_cols[k].row_is_null[bo](batch, row):
                raise Error(
                    "DistinctState.feed_row: key column "
                    + String(k)
                    + " is NULL at row "
                    + String(row)
                    + "; NULL keys are not supported"
                )
        var h = self._hash_row[bo](batch, row)
        # Grow before insert if at the load threshold (so a new row lands in the
        # larger directory). Harmless when the probe finds an existing row.
        self._dir.maybe_grow()
        var salt = _distinct_salt_of(h)
        var mask = UInt64(self._dir.capacity - 1)
        var stride = _distinct_salt_stride(salt, mask)
        var slot = h & mask
        while True:
            var word = self._dir.directory[Int(slot)]
            if word == _DISTINCT_EMPTY_SLOT:
                # New distinct row — append keys to every column at the next
                # dense index, then commit the directory word at this slot.
                comptime for k in range(Self.Keys.__len__()):
                    self.key_cols[k].append_row[bo](batch, row)
                self._dir.commit_insert(slot, salt, h)
                self.n_used = self.n_used + 1
                # Bump the age counter once per accumulated distinct
                # row, so OLDEST_FIRST prefers a long-idle set for spill.
                self._age_ticks += UInt64(1)
                return
            # Salt-compare gate before the full-key fetch (the bulk of the win).
            if (word >> UInt64(_DISTINCT_SALT_SHIFT)) == salt:
                var stored_idx = Int(word & _DISTINCT_IDX_MASK)
                if self._row_equals_stored[bo](stored_idx, batch, row):
                    return  # duplicate — already seen
            slot = (slot + stride) & mask

    def probe_batch[bo: Origin[mut=False], join_t: Int](
        mut self, batch: BatchView[bo]
    ) raises -> Optional[RecordBatch]:
        """Raise-stub — DISTINCT is an accumulate arm, never the JOIN_PROBE state
        (the `comptime if` JOIN_PROBE arm is the only caller)."""
        raise Error("DistinctState.probe_batch: not a JOIN_PROBE state")

    def probe_asof_batch[bo: Origin[mut=False]](
        mut self, batch: BatchView[bo]
    ) raises -> Optional[RecordBatch]:
        """Raise-stub — DISTINCT is an accumulate arm, never the ASOF_JOIN state
        (the `comptime if` ASOF_JOIN arm is the only caller)."""
        raise Error("DistinctState.probe_asof_batch: not an ASOF_JOIN state")

    def drain_to_record_batch(self) raises -> Optional[RecordBatch]:
        """`BreakerState` executable surface. Emit one (k0..kN-1) row per
        distinct key combination, in insertion order. BORROWS `self` (consuming
        `self.state^` out of `var self` is rejected) — the
        owning `Stage.finalize(var self)` drops the state afterward. Each key
        column's native-DType emit is delegated to
        `DistinctKeyColumn.emit_distinct_column` (the trait-erasure wall — drain
        over `*Keys` cannot name `DistinctKeyColumn_Typed`)."""
        if len(self._spill_chunks) > 0:
            raise Error(
                "DistinctState.drain_to_record_batch: spilled rows are not"
                " restored; call restore_from_storage first"
            )
        # Output schema: k0..kN-1 (native DType).
        var sb = SchemaBuilder()

        comptime for k in range(Self.Keys.__len__()):
            self.key_cols[k].add_distinct_schema_field(sb, k)
        var schema = sb.build()

        var rb = RecordBatchBuilder()

        comptime for k in range(Self.Keys.__len__()):
            self.key_cols[k].emit_distinct_column(rb)
        var built = rb.build(schema^)

        # The byte-exact distinct
        # result is assembled by the RecordBatchBuilder above (the single
        # byte-correct column-emit kernel), then
        # lifted into a ColumnNativeBatch (the breaker's native column-batch
        # product) and bridged back to RecordBatch at the breaker output
        # boundary. The body of the ColumnNativeBatch IS a THSPLC chunk, so the
        # lift+lower is byte-identical to a spill/restore round-trip (foundation
        # round-trip test). The driver still carries the concrete RecordBatch.
        var native: ColumnNativeBatch = column_native_from_record_batch(built^)
        return Optional[RecordBatch](record_batch_from_column_native(native^))

    def combine(mut self, var other: Self) raises:
        """Cross-instance merge (S1 `BreakerStateCombinable`) — re-dedup every
        distinct row of `other` into `self`'s set. The multi-worker `StageMorselSinkAdapter`
        folds every worker's per-worker `DistinctState` into ONE global state
        via `global.combine(worker_local^)` before the final `drain`.

        Byte-identical-to-single-worker: a `DistinctState` is a dedup SET, so the
        merged set is the union of `self`'s and `other`'s distinct key tuples.
        `other`'s already-deduped rows are materialized to a `[k0..kN-1]`
        columnar image (`_distinct_record_batch`, in `other`'s insertion order)
        and re-fed through the SAME dedup path the spill-restore uses
        (`_append_from_record_batch` -> `_restore_feed_row`, which reads each key
        off spill-image slot `k` == key `k` and appends only on a true full-key
        miss). A single-worker feed of (self-rows ++ other-rows) produces the
        EXACT same multiset of distinct rows: every `self` row already present,
        every `other` row appended iff not already in `self` — full-key equality,
        not hash-collision. Output order is self-rows first, then `other`'s
        novel rows in `other`'s insertion order (DISTINCT permits unordered
        output; downstream sinks needing order compose Sort over DISTINCT).

        Reuses the tested spill-restore re-feed exactly (DISTINCT carries no
        payload — the drain image IS the resident state), so this combine is the
        same logical operation the spill-restore path already validates.

        Raises if `other` still holds spilled rows (its resident image would
        miss them); restore it first."""
        if len(other._spill_chunks) > 0:
            raise Error(
                "DistinctState.combine: the other state has spilled rows;"
                " restore it before combining"
            )
        var n_other = other.n_used
        if n_other == 0:
            return
        var other_rb = other._distinct_record_batch()
        self._append_from_record_batch(other_rb^)

    # =========================================================================
    # SpillableOp conformance (the DISTINCT set spills via THSPLC)
    # =========================================================================
    #
    # The DistinctState is a dedup SET: it stores keys SoA as native-DType
    # `List[Scalar[dt]]` columns, one stored value per DISTINCT row, in
    # INSERTION order. Spill serializes that ALREADY-DEDUPED image — a
    # `[k0..kN-1]` columnar RecordBatch in insertion order — straight through
    # THSPLC (column grain; ZERO AoS<->SoA transpose, since the set already
    # stores columnar). This is byte-identical to `drain_to_record_batch`'s
    # output (DISTINCT has no payload; the drain IS the resident image).
    #
    # Restore re-feeds those rows through the SAME dedup `feed_row` path (off
    # the spill-image column layout), so the dedup directory + `n_used` are
    # rebuilt exactly. Re-feeding an already-distinct image is a no-op-dedup
    # (every row is new — no two stored rows are equal), so the restored set is
    # the SAME multiset of distinct rows in the SAME insertion order, and a
    # subsequent drain is logically identical to the un-spilled reference.
    #
    # WHAT IS / IS NOT IN THE SPILL IMAGE:
    #   * IN:  the distinct key columns (the resident bytes).
    #   * NOT: the dedup directory (DERIVED — rebuilt on restore from the keys)
    #     nor any op-config (DISTINCT carries none beyond the comptime key
    #     shape). Spill serializes the distinct ROWS, not the derived filter.

    def _spill_schema(self) raises -> Schema:
        """The `[k0..kN-1]` output schema of the distinct-set spill image —
        built identically to `drain_to_record_batch`'s schema (native per-key
        DType). Used both to fingerprint the THSPLC chunk and as the expected
        schema for `THSPLCDecoder.decode_copy` on restore."""
        var sb = SchemaBuilder()

        comptime for k in range(Self.Keys.__len__()):
            self.key_cols[k].add_distinct_schema_field(sb, k)
        return sb.build()

    def _distinct_record_batch(self) raises -> RecordBatch:
        """Materialize the distinct-set (insertion-order) state as a `[k0..kN-1]`
        RecordBatch. Reuses each key column's `emit_distinct_column` (all stored
        distinct values in insertion order). This is the columnar image THSPLC
        serializes — no transpose, columns stay columnar."""
        var schema = self._spill_schema()
        var rb = RecordBatchBuilder()

        comptime for k in range(Self.Keys.__len__()):
            self.key_cols[k].emit_distinct_column(rb)
        return rb.build(schema^)

    def memory_usage_bytes(self) -> Int64:
        """Resident bytes attributable to this set (O(1)). Counts the SoA key
        columns (one `Scalar[dt]` per distinct row per key) + the directory's
        per-row cached hash (one UInt64 per distinct row). After
        `spill_to_storage` empties the set this returns ~0.

        (The directory's slot array is excluded — it is a fixed-overhead probe
        structure, not per-row payload; same accounting choice
        `_DenseAggDirectory`-backed tables make for the agg primitive.)"""
        var n = self.n_used
        var per_row_bytes = 0

        comptime for k in range(Self.Keys.__len__()):
            per_row_bytes += size_of[Scalar[Self.Keys[k].DT]]()
        # the directory's per-row cached hash (UInt64 per distinct row).
        per_row_bytes += size_of[UInt64]()
        return Int64(n * per_row_bytes)

    def age_ticks(self) -> UInt64:
        """Monotonic counter bumped once per accumulated distinct row (in
        `feed_row`). OLDEST_FIRST picks the smallest value."""
        return self._age_ticks

    def can_spill(self) -> Bool:
        """True unless mid-restore. The DistinctState is an accumulate-then-drain
        breaker, so it is spillable at any point during accumulation; the only
        unsafe window is while a restore is rebuilding the in-memory state."""
        return not self._restoring

    def spill_to_storage[
        S: SpillStorage
    ](mut self, mut storage: S) raises -> Int64:
        """Serialize the distinct-set state to `storage` via THSPLC and free the
        in-memory buffers. Returns BYTES FREED.

        Gathers the insertion-order `[k0..kN-1]` RecordBatch ->
        `THSPLCEncoder.encode` -> `storage.write_chunk`, stashes the minted
        `ChunkId` on `self._spill_chunks`, then clears the key columns + the
        directory + resets `n_used` so `memory_usage_bytes()` drops to ~0. The
        stashed ChunkId(s) + the op's comptime key shape are all
        `restore_from_storage` needs to rebuild the state."""
        var freed = self.memory_usage_bytes()

        var batch = self._distinct_record_batch()
        var bytes = THSPLCEncoder.encode(batch^)
        var chunk = storage.write_chunk(bytes^)
        self._spill_chunks.append(chunk)

        # Drop the resident buffers (state now lives in the spilled chunk).
        comptime for k in range(Self.Keys.__len__()):
            self.key_cols[k].clear_values()
        self._dir.clear()
        self.n_used = 0
        return freed

    def restore_from_storage[
        S: SpillStorage
    ](mut self, mut storage: S) raises:
        """Rebuild the distinct-set state from every stashed spill chunk. Reads
        each ChunkId -> `THSPLCDecoder.decode_copy` (expected schema =
        `_spill_schema`) -> re-feeds every row through the dedup path (off the
        spill-image column layout) via `_restore_feed_row`, rebuilding the
        dedup directory + `n_used`. After restore, the set holds the same
        multiset of distinct rows in the same insertion order, so a subsequent
        drain is logically identical to the un-spilled reference.

        Multiple chunks (from repeated spill passes) restore in stash order —
        each chunk's rows append after the prior, preserving global insertion
        order. Each chunk is released after a successful decode so a re-spill
        does not double-count storage."""
        self._restoring = True
        try:
            var schema = self._spill_schema()
            while len(self._spill_chunks) > 0:
                var chunk = self._spill_chunks[0]
                var bytes = storage.read_chunk(chunk)
                var restored = THSPLCDecoder.decode_copy(bytes^, schema.copy())
                self._append_from_record_batch(restored^)
                storage.release_chunk(chunk)
                _ = self._spill_chunks.pop(0)
        except e:
            # Chunks not yet restored stay stashed; the state is spillable
            # and restorable again.
            self._restoring = False
            raise e^
        self._restoring = False

    def _restore_feed_row[bo: Origin[mut=False]](
        mut self, batch: BatchView[bo], row: Int
    ):
        """Re-dedup one row of a decoded `[k0..kN-1]` spill image, reading each
        key off its spill-image slot (key `k` at spill column `k`, the drain-slot
        layout — NOT the original input-bound column). Mirror of `feed_row`'s
        dedup loop but on the spill-image column index. Since the image is
        already distinct, every row is new (no two stored rows are equal) — this
        rebuilds the dedup directory while preserving insertion order."""
        # Combined FNV-1a hash off the spill-image slots (slot k == key k).
        var h = DISTINCT_FNV_OFFSET

        comptime for k in range(Self.Keys.__len__()):
            h = self.key_cols[k].restore_hash_step[bo](h, batch, k, row)
        # Probe the open-addressing directory (mirror of `feed_row` on the
        # spill-image column layout). Since the image is already distinct every
        # row is new; the probe lands on an empty slot and inserts.
        self._dir.maybe_grow()
        var salt = _distinct_salt_of(h)
        var mask = UInt64(self._dir.capacity - 1)
        var stride = _distinct_salt_stride(salt, mask)
        var slot = h & mask
        while True:
            var word = self._dir.directory[Int(slot)]
            if word == _DISTINCT_EMPTY_SLOT:
                comptime for k in range(Self.Keys.__len__()):
                    self.key_cols[k].restore_append[bo](batch, k, row)
                self._dir.commit_insert(slot, salt, h)
                self.n_used = self.n_used + 1
                self._age_ticks += UInt64(1)
                return
            if (word >> UInt64(_DISTINCT_SALT_SHIFT)) == salt:
                var stored_idx = Int(word & _DISTINCT_IDX_MASK)
                if self._restore_row_equals_stored[bo](stored_idx, batch, row):
                    return  # already present (defensive — image is distinct)
            slot = (slot + stride) & mask

    @always_inline
    def _restore_row_equals_stored[bo: Origin[mut=False]](
        self, stored_idx: Int, batch: BatchView[bo], row: Int
    ) -> Bool:
        """True iff EVERY key column's value at `stored_idx` equals the spill-
        image row's value off the matching SLOT column (slot k == key k). The
        restore-side full-key dedup compare (mirror of `_row_equals_stored` on
        the spill-image column layout)."""

        comptime for k in range(Self.Keys.__len__()):
            if not self.key_cols[k].restore_equals_row[bo](
                stored_idx, batch, k, row
            ):
                return False
        return True

    def _append_from_record_batch(mut self, var batch: RecordBatch) raises:
        """Re-feed every row of a decoded `[k0..kN-1]` spill image into the set,
        in batch (insertion) order, through the dedup `_restore_feed_row` path.
        Reads typed values off a `BatchView` over the restored batch."""
        var n = batch.num_rows()
        var bv = BatchView(batch)
        for row in range(n):
            self._restore_feed_row(bv, row)
        _ = batch^
