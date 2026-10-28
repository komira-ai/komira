# =============================================================================
# distinct_key_column.mojo — the key columns of the stage DISTINCT state
# =============================================================================
#
# `DistinctState[*Keys]` (`distinct_state`) dedups rows by their key columns
# and emits each distinct key combination once: the key side of a hash
# aggregation with no aggregate. It holds one `DistinctKeyColumn` per key, as
# SoA storage in a `Tuple[*Keys]` field (a `Tuple` over a trait-bounded pack
# does not synthesize `Copyable`, so it cannot be a `List` element). The
# per-key feed / dedup / emit work fans a comptime `for` over the key pack
# calling only `DistinctKeyColumn` trait methods (a body over `*Keys` cannot
# prove a slot's concrete type, so per-key logic lives on the trait).
#
# This module holds the constants, the per-position FNV-1a combinator, the
# trait, and the fixed-width conformer `DistinctKeyColumn_Typed[dt, col]`; the
# STRING conformer is `distinct_key_column_string`.
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


# =============================================================================
# §1 — Constants + per-position FNV-1a combinator
# =============================================================================

comptime DISTINCT_FNV_OFFSET: UInt64 = 14695981039346656037
"""FNV-1a 64-bit offset basis (RFC standard). Mirrors `hashset_parametric`."""

comptime DISTINCT_FNV_PRIME: UInt64 = 1099511628211
"""FNV-1a 64-bit prime (RFC standard). Mirrors `hashset_parametric`."""

comptime DISTINCT_DEFAULT_CAPACITY: Int = 16
"""Initial reserve for the SoA key Lists. The Lists grow via `append` on a
distinct-key miss (no fixed cap — unlike the InlineArray-backed HashAggTable's
MAX_GROUPS=16)."""

comptime DISTINCT_DIR_INITIAL_CAPACITY: Int = 2048
"""Initial directory slot count for the open-addressing dedup directory
(`_DistinctDirectory`). Power-of-2; 16 KB directory. Mirror of
`dense_hash_agg_table.DENSE_INITIAL_CAPACITY` — covers the small/medium-card
cases with no resize, grows geometrically past ~0.67 load.

The directory makes the per-row probe O(1) amortized (salt-stride open
addressing), matching the untyped column-format hash path."""

comptime _DISTINCT_EMPTY_SLOT: UInt64 = 0
"""Empty-slot sentinel: salt==0 AND dense_idx==0. A real dense_idx of 0 carries
a nonzero salt, so it is distinguishable from empty (mirror of
`dense_hash_agg_table._EMPTY_SLOT`)."""

comptime _DISTINCT_SALT_SHIFT: Int = 48
"""dense_idx occupies bits [47:0]; salt occupies bits [63:48]."""

comptime _DISTINCT_IDX_MASK: UInt64 = (UInt64(1) << 48) - 1
"""Low-48-bit mask to extract the dense stored-row index from a packed word."""


@always_inline
def _distinct_salt_of(h: UInt64) -> UInt64:
    """High-16-bit salt, forced nonzero so it never collides with the empty
    sentinel (mirror of `dense_hash_agg_table._salt_of`)."""
    var s = h >> UInt64(_DISTINCT_SALT_SHIFT)
    return s | (UInt64(1) << 15)


@always_inline
def _distinct_salt_stride(salt: UInt64, mask: UInt64) -> UInt64:
    """Odd probe stride derived from the salt (mirror of
    `dense_hash_agg_table._salt_stride`). Odd is coprime with the power-of-2
    capacity, so the probe visits every slot before repeating."""
    return (salt & mask) | 1


@always_inline
def _distinct_fnv1a_step[K: DType](state: UInt64, k: Scalar[K]) -> UInt64:
    """One FNV-1a fold of a typed key cell into the running hash state.

    Bit-cast the typed cell to the matching unsigned width and fold -- the
    integer / bool arms mirror `hashset_parametric._fnv1a_combine`; the FLOAT
    arms DO NOT (they fold the quotient-canonical bits, below), monomorphized
    one inlined arm per key DType."""
    # A FLOAT key hashes its QUOTIENT-CANONICAL bits (`-0.0 -> +0.0`, every
    # NaN -> the one canonical NaN; `komira_eval.float_quotient_order`), the
    # partner of `_distinct_key_eq`. Raw bits under IEEE `==` put every NaN row
    # in a NEW group
    # (GROUP BY v over three NaNs answered
    # three groups at @mojo_typed; DuckDB 1.5.3 / polars / pandas answer one).
    comptime if K == DType.float64:
        return (
            state ^ canonical_bits_f64(rebind[Float64](k))
        ) * DISTINCT_FNV_PRIME
    elif K == DType.float32:
        return (
            state ^ UInt64(canonical_bits_f32(rebind[Float32](k)))
        ) * DISTINCT_FNV_PRIME
    elif K == DType.int64 or K == DType.uint64:
        var bits = bitcast[DType.uint64, 1](SIMD[K, 1](k))
        return (state ^ bits[0]) * DISTINCT_FNV_PRIME
    elif K == DType.int32 or K == DType.uint32:
        var bits = bitcast[DType.uint32, 1](SIMD[K, 1](k))
        return (state ^ UInt64(bits[0])) * DISTINCT_FNV_PRIME
    elif K == DType.int16 or K == DType.uint16:
        var bits = bitcast[DType.uint16, 1](SIMD[K, 1](k))
        return (state ^ UInt64(bits[0])) * DISTINCT_FNV_PRIME
    elif K == DType.int8 or K == DType.uint8 or K == DType.bool:
        var bits = bitcast[DType.uint8, 1](SIMD[K, 1](k))
        return (state ^ UInt64(bits[0])) * DISTINCT_FNV_PRIME
    else:
        var bits = bitcast[DType.uint64, 1](SIMD[K, 1](k))
        return (state ^ bits[0]) * DISTINCT_FNV_PRIME


@always_inline
def _distinct_key_eq[K: DType](a: Scalar[K], b: Scalar[K]) -> Bool:
    """Key EQUALITY in the quotient order -- the partner of
    `_distinct_fnv1a_step`'s canonical float hash: NaN == NaN, -0.0 == +0.0,
    else `==`. A comptime no-op for every non-float key."""
    comptime if K == DType.float64:
        return float_quotient_eq_f64(rebind[Float64](a), rebind[Float64](b))
    elif K == DType.float32:
        return float_quotient_eq_f32(rebind[Float32](a), rebind[Float32](b))
    else:
        return a == b


@always_inline
def _distinct_read_key_scalar[
    K: DType, bo: Origin[mut=False]
](batch: BatchView[bo], col: Int, row: Int) -> Scalar[K]:
    """Read the key value of DType `K` at `row` from input column `col`.

    Delegates to the single generic
    `BatchView.col_scalar_nonraising[K]` primitive — bit-exact over the FULL
    fixed-width numeric matrix (i8/16/32/64, u8/16/32/64, f32/f64), with NO
    silent `col_i64` else-fallthrough (an unhandled DType is a COMPILE ERROR,
    routed to the untyped P2 oracle by the SDK gate). The all-handled-today
    DTypes (I64/I32/F64/F32) codegen byte-identical to the prior ladder."""
    return batch.col_scalar_nonraising[K](col, row)


@always_inline
def _distinct_key_arrow_type[K: DType]() -> ArrowType:
    """Map a key DType to its `ArrowType` for the drain output schema.

    Delegates to the generic
    `scalar_arrow_type[K]` — correct ArrowType over the full fixed-width matrix,
    NO silent `INT64` else-fallthrough."""
    return scalar_arrow_type[K]()


# =============================================================================
# §2 — DistinctKeyColumn — the per-key column trait + conformer
# =============================================================================


trait DistinctKeyColumn(Defaultable, Movable, Deinitable):
    """One DISTINCT key column — the per-slot element type of a `DistinctState`
    key pack. Owns the `List[Scalar[DT]]` of that key's DISTINCT values (one per
    distinct row, in insertion order).

    Conformers carry their key DType via the comptime `DT` member. The single
    in-tree conformer is `DistinctKeyColumn_Typed[dt, col]` (below).

    `Defaultable`: each
    conformer publishes a no-arg `fn __init__(out self)` that builds an empty
    column. This is the load-bearing requirement that lets the pack-aware
    `Tuple[*Keys]()` default ctor resolve, so `DistinctState[*Keys]` gets a
    nullary `__init__(out self)` — which the field-less
    `VariadicDistinctFactory[*Keys].make_state` needs.

    The methods are the executable surface — they keep the per-key DType /
    input-column reads (and the native-DType drain emit) INSIDE the concrete
    conformer (where `Scalar[dt]` + `col` are in scope), so the owning
    `DistinctState.feed_row` / `.drain_to_record_batch` can drive any arity
    uniformly without naming a concrete key type (the trait-erasure wall — a
    generic over `*Keys` cannot prove a slot is `DistinctKeyColumn_Typed`, so
    per-arity logic MUST live on the trait).
    """

    comptime DT: DType

    def hash_step[bo: Origin[mut=False]](
        self, state: UInt64, batch: BatchView[bo], row: Int
    ) -> UInt64:
        """Read this column's bound input column at `row` off `batch` and fold
        the value into the running FNV-1a hash `state`. The dedup hash path —
        called BEFORE the row is known distinct (so it reads off the batch, not
        from stored values)."""
        ...

    def row_is_null[bo: Origin[mut=False]](
        self, batch: BatchView[bo], row: Int
    ) -> Bool:
        """True iff this column's bound input column is NULL at `row`. A
        `DistinctState` rejects such a row: it stores no validity, so it could
        not tell a NULL from the raw value in the null slot."""
        ...

    def equals_row[bo: Origin[mut=False]](
        self, stored_idx: Int, batch: BatchView[bo], row: Int
    ) -> Bool:
        """True iff this column's value at stored distinct-row index `stored_idx`
        equals the input batch's value at `row` (off the bound column). The
        per-key equality compare of the dedup full-key check."""
        ...

    def append_row[bo: Origin[mut=False]](
        mut self, batch: BatchView[bo], row: Int
    ):
        """Append the input batch's value at `row` (off the bound column) as a
        new distinct value. Called once per NEW distinct row."""
        ...

    # --- BAND reads:
    #     BAND-read siblings of hash_step / equals_row / append_row. The BAND fold
    #     (`AggKeyBlock.feed_lookup_band`) fans these over the key pack; each key
    #     column reads its OWN bound column from the band (the trait-erasure wall).
    #     DEFAULT = DECLINE (abort): only `DistinctKeyColumn_String` (q1's group
    #     keys) overrides them; `DistinctKeyColumn_Typed` inherits the loud decline
    #     (a caller routes only string band-keys here, so a mis-routed shape
    #     faults loudly, never silent-wrong).

    def hash_step_band[o: Origin[mut=False]](
        self, state: UInt64, band: BandView[o], row: Int
    ) -> UInt64:
        """Read this column's bound value at `row` off the BAND and fold it into
        the running FNV-1a `state`. DEFAULT DECLINE."""
        abort(
            "DistinctKeyColumn.hash_step_band: this key column type does not"
            " support the band-view fold; only"
            " DistinctKeyColumn_String is band-eligible."
        )

    def equals_row_band[o: Origin[mut=False]](
        self, stored_idx: Int, band: BandView[o], row: Int
    ) -> Bool:
        """True iff this column's stored value at `stored_idx` equals the BAND's
        value at `row` (off the bound column). DEFAULT DECLINE."""
        abort(
            "DistinctKeyColumn.equals_row_band: this key column type does not"
            " support the band-view fold."
        )

    def append_row_band[o: Origin[mut=False]](
        mut self, band: BandView[o], row: Int
    ):
        """Append the BAND's value at `row` (off the bound column) as a new
        distinct value. DEFAULT DECLINE."""
        abort(
            "DistinctKeyColumn.append_row_band: this key column type does not"
            " support the band-view fold."
        )

    def restore_append[bo: Origin[mut=False]](
        mut self, batch: BatchView[bo], spill_col: Int, row: Int
    ):
        """SPILL restore path. Read this key's value at `row` off
        `batch` column `spill_col` (the key's OUTPUT-slot position `k` in the
        `[k0..kN-1]` spill image — NOT the breaker's input-bound `col`) and
        append it as one stored distinct value. Mirror of `append_row` but keyed
        on the spill-image column index, since the spilled RecordBatch is laid
        out by drain-slot, not by the original input column index."""
        ...

    def restore_hash_step[bo: Origin[mut=False]](
        self, state: UInt64, batch: BatchView[bo], spill_col: Int, row: Int
    ) -> UInt64:
        """SPILL restore path. Read this key's value at `row` off
        `batch` column `spill_col` (the spill-image OUTPUT-slot position) and
        fold it into the running FNV-1a hash `state`. Mirror of `hash_step` but
        keyed on the spill-image column index, so restore rebuilds the dedup
        filter off the drain-slot layout (NOT the input-bound column)."""
        ...

    def restore_equals_row[bo: Origin[mut=False]](
        self, stored_idx: Int, batch: BatchView[bo], spill_col: Int, row: Int
    ) -> Bool:
        """SPILL restore path. True iff this column's value at
        stored index `stored_idx` equals the spill-image value at `row` (off
        spill column `spill_col`). Mirror of `equals_row` on the spill-image
        column index — used by the defensive restore-side dedup compare."""
        ...

    def clear_values(mut self):
        """Drop all stored distinct values (after the column's
        bytes are serialized to a spill chunk). Leaves the column empty +
        reusable."""
        ...

    def append_stored_from(mut self, other: Self, other_idx: Int):
        """Append `other`'s stored value at dense index `other_idx` as a new
        stored value of THIS column.
        The cross-instance value-copy primitive the grouped-agg `combine` uses to
        re-key a partial table's group into the global table BY VALUE — `other`'s
        group at `other_idx` is appended at this column's next dense index. Mirror
        of `append_row` but sourcing from another column instance's stored value
        rather than a `BatchView` row."""
        ...

    def equals_stored(
        self, stored_idx: Int, other: Self, other_idx: Int
    ) -> Bool:
        """True iff THIS column's stored value at dense index `stored_idx` equals
        `other`'s stored value at dense index `other_idx`
       . The cross-instance full-key
        compare the grouped-agg `combine` uses on a salt-hit (a hash collision is
        NOT a match). Mirror of `equals_row` but comparing two stored values
        rather than a stored value vs a `BatchView` row."""
        ...

    def length(self) -> Int:
        """Number of stored distinct values."""
        ...

    def emit_distinct_column(self, mut rb: RecordBatchBuilder):
        """Append this key column — in native DType, ALL stored distinct values
        in insertion order — to `rb`. The drain path."""
        ...

    def add_distinct_schema_field(self, mut sb: SchemaBuilder, k: Int):
        """Append this key's output schema field (`k<k>`, native DType)."""
        ...

    # --- Fused drain-into-final-offset surface --
    #
    # The default bodies DECLINE (mirror `feed_chunk_global` / the radix combine
    # surface): a key column whose Arrow layout the emit-at-offset write path does
    # NOT handle (BOOL bit-packing, dictionary, nested) reports
    # `EMIT_KIND_INELIGIBLE`, which makes the whole drain fall back to the
    # (correct) parallel-drain + N-way concat. Only `DistinctKeyColumn_Typed`
    # (fixed-width, non-bool) and `DistinctKeyColumn_String` override with real
    # bodies. `k` is the output column index (for the `k<k>` field name); `col_idx`
    # is the flat output-column position in the shared target list.

    def emit_at_offset_desc(self, k: Int) -> _EmitColDesc:
        """DECLINE default: this key column is not emit-at-offset-eligible."""
        return _EmitColDesc(
            Field(String("k") + String(k), ArrowType.NULL, True),
            EMIT_KIND_INELIGIBLE,
            0,
        )

    def emit_at_offset_data_bytes(self) -> Int:
        """Variable-width data bytes THIS partition contributes for this key
        column (string/binary). DEFAULT 0 (fixed-width columns have no variable
        data buffer)."""
        return 0

    def emit_distinct_at_offset(
        self,
        slots: List[Int],
        mut targets: List[_EmitColTarget],
        col_idx: Int,
        row_offset: Int,
        data_offset: Int,
    ) raises:
        """Scatter this partition's stored distinct key values DIRECTLY into the
        shared FINAL column `targets[col_idx]` at `row_offset` (fixed-width) /
        `data_offset` (string byte data). DECLINE default: raise (never reached —
        the orchestrator gates on `emit_at_offset_desc().kind != INELIGIBLE`)."""
        raise Error(
            "DistinctKeyColumn.emit_distinct_at_offset: this key column is not"
            " emit-at-offset-eligible (EMIT_KIND_INELIGIBLE)"
        )


@fieldwise_init
struct DistinctKeyColumn_Typed[dt: DType, col: Int](DistinctKeyColumn):
    """Concrete per-key DISTINCT column wrapping a `List[Scalar[dt]]` of distinct
    key values, bound to input batch column `col`.

    The DType-parametric type family (one type per key DType) is the production
    shape in Mojo 1.0.0b1 — a single value-parametric surface over DType is not
    witness-resolvable. `col` is the comptime
    input-batch column index this key is read from. Carrying it
    here makes `DistinctState[*Keys]` fully self-describing so the typed `Stage`
    DISTINCT arm reads keys with zero runtime dispatch.
    """

    comptime DT: DType = Self.dt
    var values: List[Scalar[Self.dt]]

    def __init__(out self):
        """`Defaultable` no-arg ctor.
        Builds an empty column with the default reserve. This is what lets the
        pack-aware `Tuple[*Keys]()` default ctor resolve inside
        `DistinctState[*Keys]`'s nullary ctor (the `VariadicDistinctFactory`
        seam)."""
        self.values = List[Scalar[Self.dt]](capacity=DISTINCT_DEFAULT_CAPACITY)

    @staticmethod
    def new(initial_capacity: Int) -> DistinctKeyColumn_Typed[Self.dt, Self.col]:
        """Construct empty column with reserved capacity."""
        return DistinctKeyColumn_Typed[Self.dt, Self.col](
            values=List[Scalar[Self.dt]](capacity=initial_capacity)
        )

    @always_inline
    def hash_step[bo: Origin[mut=False]](
        self, state: UInt64, batch: BatchView[bo], row: Int
    ) -> UInt64:
        var v = _distinct_read_key_scalar[Self.dt, bo](batch, Self.col, row)
        return _distinct_fnv1a_step[Self.dt](state, v)

    @always_inline
    def row_is_null[bo: Origin[mut=False]](
        self, batch: BatchView[bo], row: Int
    ) -> Bool:
        return batch.col_is_null(Self.col, row)

    @always_inline
    def equals_row[bo: Origin[mut=False]](
        self, stored_idx: Int, batch: BatchView[bo], row: Int
    ) -> Bool:
        var v = _distinct_read_key_scalar[Self.dt, bo](batch, Self.col, row)
        return _distinct_key_eq[Self.dt](self.values[stored_idx], v)

    @always_inline
    def append_row[bo: Origin[mut=False]](
        mut self, batch: BatchView[bo], row: Int
    ):
        self.values.append(
            _distinct_read_key_scalar[Self.dt, bo](batch, Self.col, row)
        )

    # --- ENGINE-V2 W2 BAND-read siblings — the NUMERIC-key band fold. Reads this
    #     column's bound value at `row` off the band via the generic
    #     `col_scalar[dt]` accessor (byte-identical to `hash_step`/`equals_row`/
    #     `append_row` over the same scalar), so a numeric GROUP-BY key folds
    #     through `consume_band` exactly as a dict-string key does — the control
    #     shape the byte-oracle exercises alongside q1's 2-string-key case.
    @always_inline
    def hash_step_band[o: Origin[mut=False]](
        self, state: UInt64, band: BandView[o], row: Int
    ) -> UInt64:
        var v = band.col_scalar[Self.dt](Self.col, row)
        return _distinct_fnv1a_step[Self.dt](state, v)

    @always_inline
    def equals_row_band[o: Origin[mut=False]](
        self, stored_idx: Int, band: BandView[o], row: Int
    ) -> Bool:
        return _distinct_key_eq[Self.dt](
            self.values[stored_idx], band.col_scalar[Self.dt](Self.col, row)
        )

    @always_inline
    def append_row_band[o: Origin[mut=False]](
        mut self, band: BandView[o], row: Int
    ):
        self.values.append(band.col_scalar[Self.dt](Self.col, row))

    @always_inline
    def restore_append[bo: Origin[mut=False]](
        mut self, batch: BatchView[bo], spill_col: Int, row: Int
    ):
        self.values.append(
            _distinct_read_key_scalar[Self.dt, bo](batch, spill_col, row)
        )

    @always_inline
    def restore_hash_step[bo: Origin[mut=False]](
        self, state: UInt64, batch: BatchView[bo], spill_col: Int, row: Int
    ) -> UInt64:
        var v = _distinct_read_key_scalar[Self.dt, bo](batch, spill_col, row)
        return _distinct_fnv1a_step[Self.dt](state, v)

    @always_inline
    def restore_equals_row[bo: Origin[mut=False]](
        self, stored_idx: Int, batch: BatchView[bo], spill_col: Int, row: Int
    ) -> Bool:
        var v = _distinct_read_key_scalar[Self.dt, bo](batch, spill_col, row)
        return _distinct_key_eq[Self.dt](self.values[stored_idx], v)

    @always_inline
    def clear_values(mut self):
        self.values.clear()

    @always_inline
    def append_stored_from(mut self, other: Self, other_idx: Int):
        self.values.append(other.values[other_idx])

    @always_inline
    def equals_stored(
        self, stored_idx: Int, other: Self, other_idx: Int
    ) -> Bool:
        return _distinct_key_eq[Self.dt](
            self.values[stored_idx], other.values[other_idx]
        )

    @always_inline
    def length(self) -> Int:
        return len(self.values)

    def emit_distinct_column(self, mut rb: RecordBatchBuilder):
        var vals = List[Scalar[Self.dt]](capacity=len(self.values))
        for i in range(len(self.values)):
            vals.append(self.values[i])
        var arr = PrimitiveArray[Self.dt].from_list(vals)
        rb.add_column(Column.from_primitive[Self.dt](arr^))

    def add_distinct_schema_field(self, mut sb: SchemaBuilder, k: Int):
        sb.add_field(
            Field(
                String("k") + String(k),
                _distinct_key_arrow_type[Self.dt](),
                True,
            )
        )

    def emit_at_offset_desc(self, k: Int) -> _EmitColDesc:
        """Fixed-width numeric key: kind=FIXED, element width = `size_of[Scalar
        [dt]]`. A BOOL key is bit-packed in Arrow (not byte-per-element), so it is
        INELIGIBLE — the drain falls back to concat for it."""
        comptime if Self.dt == DType.bool:
            return _EmitColDesc(
                Field(
                    String("k") + String(k),
                    _distinct_key_arrow_type[Self.dt](),
                    True,
                ),
                EMIT_KIND_INELIGIBLE,
                0,
            )
        else:
            return _EmitColDesc(
                Field(
                    String("k") + String(k),
                    _distinct_key_arrow_type[Self.dt](),
                    True,
                ),
                EMIT_KIND_FIXED,
                size_of[Scalar[Self.dt]](),
            )

    def emit_distinct_at_offset(
        self,
        slots: List[Int],
        mut targets: List[_EmitColTarget],
        col_idx: Int,
        row_offset: Int,
        data_offset: Int,
    ) raises:
        """Write each stored distinct value at its FINAL row index
        `row_offset + si` into the shared fixed-width buffer. Byte-identical to
        `emit_distinct_column` -> `from_list` -> concat: same values, same
        insertion order (`slots` is the identity 0..n-1 dense range), placed at
        this partition's prefix-sum offset."""
        ref data = targets[col_idx].data
        for si in range(len(slots)):
            data.set_typed[Scalar[Self.dt]](
                row_offset + si, self.values[slots[si]]
            )


@always_inline
def distinct_key_column_i64(
    initial_capacity: Int,
) -> DistinctKeyColumn_Typed[DType.int64, 0]:
    """Factory for an Int64 DISTINCT-key column bound to input column 0 (the
    canonical single-key shape)."""
    return DistinctKeyColumn_Typed[DType.int64, 0].new(initial_capacity)

