# =============================================================================
# emit_at_offset_target.mojo — the DType-erased column-plan + write-target types
# for the FUSED drain+emit-at-offset finalize (PERF-AGG-DRAIN-EMIT-AT-OFFSET).
# =============================================================================
#
# The parallel per-partition drain (`stage_partition_drain_parallel.mojo`) fans
# the N disjoint-key radix partition drains across the pool but each worker still
# materializes its partition's OWN RecordBatch, which the driver then N-way
# CONCATENATES into the final output — a redundant second bandwidth pass (~26ms
# on h10 6M rows, a ~768MB pure memcpy). This module is the substrate for
# ELIMINATING that concat: each partition's drain writes its finalized groups
# DIRECTLY into the shared FINAL output columns at prefix-sum offsets (disjoint
# row ranges by construction), so the drain and the concat fuse into ONE write
# pass.
#
# Because the per-column output DType is only concrete INSIDE the typed
# `HashAggTable[KB, *Aggs]` (the trait-erasure wall), the generic orchestrator
# cannot name it. These two RUNTIME-typed carriers cross that wall:
#
#   * `_EmitColDesc`  — one per output column: the Arrow `Field` (name + type +
#     nullability) + a `kind` discriminator (fixed-width / string / ineligible) +
#     the element `byte_width`. Produced once (from partition 0) so the
#     orchestrator can build the schema + size the buffers WITHOUT naming a DType.
#   * `_EmitColTarget` — one per output column: the pre-allocated (total-sized)
#     `OwnedAlignedBuffer`(s) the per-partition emit kernels scatter into at their
#     offset. Fixed-width columns own one `data` buffer; string/binary columns own
#     a `data` byte buffer + an Int32 `offsets` buffer.
#
# Both are DType-AGNOSTIC (`OwnedAlignedBuffer` is byte-addressed; `set_typed[T]`
# is the typed write the concrete kernel performs), so this module imports only
# leaf Arrow types — no `HashAggTable` / `Stage` dependency, no cycle. It is
# imported by `breaker_state_trait.mojo` (the trait surface), `distinct_state.mojo`
# + `hash_agg.mojo` (the per-DType kernels), and `stage_partition_emit_at_offset.mojo`
# (the orchestrator).
#
# Encapsulation invariants (the internal development notes hard bans):
#   - NO `UnsafePointer` in any public signature. The write kernels take
#     `mut _EmitColTarget` and use the buffer's typed public API (`set_typed` /
#     `copy_from_view_at`). Internal pointer arithmetic (the string byte copy's
#     `ByteView` over an owned `List[UInt8]`) stays inside the conformer with a
#     `# SAFETY:` comment.
#   - `OwnedAlignedBuffer` is `Movable`-only (single-owner heap); `_EmitColTarget`
#     is `Movable`-only too (owns its buffers). `_EmitColDesc` is POD-ish
#     (`Field` + two `Int`s) so it is `Copyable` for cheap plan passing.
# =============================================================================

from std.builtin.swap import swap

from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_arrow.schema import Field, ArrowType


# The output-column kind discriminator. INELIGIBLE marks a column whose Arrow
# layout the emit-at-offset write path does NOT handle (BOOL bit-packing,
# DICTIONARY, nested, COUNT(DISTINCT) deferred-radix, or any column that would
# carry a validity bitmap) — one ineligible column makes the WHOLE drain fall
# back to the (correct) parallel-drain + N-way concat path.
comptime EMIT_KIND_INELIGIBLE: Int = 0
comptime EMIT_KIND_FIXED: Int = 1  # fixed-width multi-byte primitive (memcpy-equiv)
comptime EMIT_KIND_STRING: Int = 2  # STRING/BINARY (offsets + byte data)
"""⚠ THE OFFSET ENTRY WIDTH IS THE PRODUCER'S, NOT THIS KIND'S (corrected
2026-09-19, MW-STRDRAIN). This line read "(Int32 offsets + byte data)" and the
two docstrings below said `Int32` outright, while
`drain_radix_hash_agg_untyped_parallel` was already building targets of this
kind with EIGHT-byte entries for a column whose byte total has no narrow
answer (ClickBench cbq33: 3,374,058,173 key bytes). Read the width off
`byte_width` (4 or 8); do not infer it from `kind`. This struct holds no
offset-reading helper, so the width is the constructing producer's to carry
to its own consumer — which is exactly why an assumption stated here would be
believed by a producer that never checked."""


struct _EmitColDesc(Copyable, Movable, Deinitable):
    """One output column's DType-erased plan: the Arrow `Field` (drives the
    output schema, byte-identically to the per-partition drain's schema), the
    `kind` discriminator, and the element `byte_width` (fixed-width element size;
    for a string column it is the OFFSET ENTRY width — 4 for Int32 offsets, 8
    for Int64/LARGE_STRING, decided by the producer from its measured byte
    total via `should_promote_offsets`).

    An empty plan (`len(descs) == 0`) OR any `kind == EMIT_KIND_INELIGIBLE` tells
    the orchestrator the shape is not emit-at-offset-eligible, so it returns None
    and the finalize arm falls back to the existing drain+concat path."""

    var field: Field
    var kind: Int
    var byte_width: Int

    def __init__(out self, var field: Field, kind: Int, byte_width: Int):
        # `Field` is Copyable but NOT ImplicitlyCopyable — take it by `var` +
        # MOVE (`^`) so the conformer construction sites do not need an implicit
        # copy of the freshly-built Field.
        self.field = field^
        self.kind = kind
        self.byte_width = byte_width


struct _EmitColTarget(Movable, Deinitable):
    """One output column's pre-allocated FINAL write target: the total-sized
    `data` buffer (all partitions scatter into it at disjoint row/byte offsets)
    plus, for string/binary columns, the `(total+1)`-entry `offsets` buffer
    whose entry width is `byte_width` (4 = Int32, 8 = Int64/LARGE_*). Assembled into a `Column` after the fan barrier (each partition wrote
    a disjoint range, so the assembled column is byte-identical to the concat)."""

    var kind: Int
    var byte_width: Int
    var data: OwnedAlignedBuffer
    var offsets: OwnedAlignedBuffer  # string/binary only; empty for fixed-width
    var has_offsets: Bool

    def __init__(
        out self,
        kind: Int,
        byte_width: Int,
        var data: OwnedAlignedBuffer,
        var offsets: OwnedAlignedBuffer,
        has_offsets: Bool,
    ):
        self.kind = kind
        self.byte_width = byte_width
        self.data = data^
        self.offsets = offsets^
        self.has_offsets = has_offsets

    @staticmethod
    def empty() -> Self:
        """A destructor-safe empty placeholder — the `swap`-out sentinel the
        orchestrator moves each real target out with when assembling the final
        Columns (mirrors the `swap(out[p], b)` move-out in the parallel drain)."""
        return Self(
            kind=EMIT_KIND_INELIGIBLE,
            byte_width=0,
            data=OwnedAlignedBuffer(0),
            offsets=OwnedAlignedBuffer(0),
            has_offsets=False,
        )

    def take_data(mut self) -> OwnedAlignedBuffer:
        """Move the `data` buffer out, leaving an empty buffer behind (the parent
        `_EmitColTarget` stays destructor-safe). The `swap`-with-empty move-out
        primitive (the internal development notes Hard Ban #11 replacement), NOT a partial-move via
        pointer."""
        var placeholder = OwnedAlignedBuffer(0)
        swap(self.data, placeholder)
        return placeholder^

    def take_offsets(mut self) -> OwnedAlignedBuffer:
        """Move the `offsets` buffer out, leaving an empty buffer behind."""
        var placeholder = OwnedAlignedBuffer(0)
        swap(self.offsets, placeholder)
        return placeholder^
