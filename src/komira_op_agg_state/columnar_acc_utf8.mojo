# =============================================================================
# Variable-width Typed SoA Accumulators — MinUtf8Acc / MaxUtf8Acc
# =============================================================================
#
# Split out of `columnar_acc_typed.mojo` (PE Phase 0d concern #3: the combined
# file passed the 1000-line Mojo JIT hang threshold). The numeric accumulators
# (Sum/Count/Min/Max for Int64, Kahan for Float64) stay in
# `columnar_acc_typed.mojo`; advanced semantics (Percentile, CountDistinct)
# live in `columnar_acc_agg.mojo`.
#
# These two structs share their key trait: the per-gid state is variable-width
# (Optional[String]). They CANNOT participate in SIMD `merge_aligned` paths
# (strings don't compare with fixed lanes); the kernels here are scalar.
#
# Reference sources (faithfully ported):
#   - `komira-engine/src/aggregate/columnar_accumulator.rs`
#       * MinUtf8ColumnarAcc / MaxUtf8ColumnarAcc (~line 586-594)
#   - an internal doc §0
#
# Movable-only (owns List[Optional[String]]). Do NOT add Copyable — would
# alias inner string buffers and break merge semantics.
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

from std.memory import alloc, unsafe_memcpy

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.string_array import StringArray
from komira_collections.slab import Slab
from komira_op_agg_state.accumulator_trait import Accumulator
from komira_buffer.heap_region import HeapRegion


# =============================================================================
# PERF-CRITICAL: MinUtf8Acc — per-gid min of utf8 strings
# =============================================================================
# Null semantics: None = group has never seen a non-null value. Matches v0.3
# MinUtf8ColumnarAcc (no NullState — the Option itself is the null marker).
# =============================================================================
struct MinUtf8Acc(Accumulator):
    """SoA MIN(Utf8) column: Optional[String] per gid (None = unseen)."""

    var state: List[Optional[String]]

    def __init__(out self):
        self.state = List[Optional[String]]()

    @staticmethod
    def new() -> Self:
        return Self()

    def ensure_capacity(mut self, num_groups: Int):
        while len(self.state) < num_groups:
            self.state.append(Optional[String](None))

    def update_batch(
        mut self,
        imm gids: List[UInt32],
        imm values: List[String],
        num_rows: Int,
    ) raises:
        # UTF-8 update takes List refs rather than UnsafePointer because
        # Mojo String is not trivially addressable via Scalar[T] —
        # pointer-based access would require String's buffer ptr plus
        # length, and at Phase 0a we prioritize readability over SIMD.
        for i in range(num_rows):
            var g = Int(gids[i])
            if g >= len(self.state):
                raise Error("MinUtf8Acc.update_batch: gid out of range")
            var v = values[i]
            ref slot = self.state[g]
            if not slot:
                slot = Optional[String](v)
            else:
                if v < slot.value():
                    slot = Optional[String](v)

    def merge_at(mut self, dst_gid: Int, imm src: Self, src_gid: Int) raises:
        if dst_gid >= len(self.state):
            raise Error("MinUtf8Acc.merge_at: dst_gid out of range")
        if src_gid >= len(src.state):
            raise Error("MinUtf8Acc.merge_at: src_gid out of range")
        ref src_slot = src.state[src_gid]
        if not src_slot:
            return
        var v = src_slot.value()
        ref dst_slot = self.state[dst_gid]
        if not dst_slot:
            dst_slot = Optional[String](v)
        else:
            if v < dst_slot.value():
                dst_slot = Optional[String](v)

    # PERF-CRITICAL: aligned-gid full-column merge (Phase 0d).
    # Scalar (variable-width — strings don't SIMD-compare with fixed lanes).
    def merge_aligned(mut self, imm src: Self) raises:
        var n = len(src.state)
        if len(self.state) != n:
            raise Error(
                "MinUtf8Acc.merge_aligned: length mismatch (self=" +
                String(len(self.state)) + ", src=" + String(n) + ")"
            )
        for i in range(n):
            ref src_slot = src.state[i]
            if not src_slot:
                continue
            var v = src_slot.value()
            ref dst_slot = self.state[i]
            if not dst_slot:
                dst_slot = Optional[String](v)
            else:
                if v < dst_slot.value():
                    dst_slot = Optional[String](v)

    def finalize(self) -> List[Optional[String]]:
        var out = List[Optional[String]]()
        for i in range(len(self.state)):
            out.append(self.state[i])
        return out^

    def num_groups(self) -> Int:
        return len(self.state)

    # --- Accumulator trait conformance (Phase Acc-trait) ----------------------

    def update_batch[og: Origin, oc: Origin](
        mut self,
        gids: Span[Int, og],
        col_data: Span[UInt8, oc],
        col_offset: Int,
        n: Int,
    ) raises:
        """Trait-conforming stub. UTF8 accumulators need offsets buffer which
        the raw-pointer kernel path does not carry. Use the typed
        update_batch(List[UInt32], List[String], Int) via the consumer."""
        raise Error("MinUtf8Acc: raw-pointer update_batch not supported for UTF8; use typed path")

    def finalize_to_column(mut self) raises -> Column[HeapRegion]:
        """Wrap state as STRING Column[HeapRegion] via StringArray."""
        var strs = List[String]()
        for i in range(len(self.state)):
            ref slot = self.state[i]
            if slot:
                strs.append(slot.value())
            else:
                strs.append(String(""))
        var arr = StringArray.from_strings(strs)
        return Column.from_string(arr)

    def flush_partial_to_column(mut self) raises -> Column[HeapRegion]:
        return self.finalize_to_column()


# =============================================================================
# PERF-CRITICAL: MaxUtf8Acc — per-gid max of utf8 strings
# =============================================================================
struct MaxUtf8Acc(Accumulator):
    """SoA MAX(Utf8) column: Optional[String] per gid (None = unseen)."""

    var state: List[Optional[String]]

    def __init__(out self):
        self.state = List[Optional[String]]()

    @staticmethod
    def new() -> Self:
        return Self()

    def ensure_capacity(mut self, num_groups: Int):
        while len(self.state) < num_groups:
            self.state.append(Optional[String](None))

    def update_batch(
        mut self,
        imm gids: List[UInt32],
        imm values: List[String],
        num_rows: Int,
    ) raises:
        for i in range(num_rows):
            var g = Int(gids[i])
            if g >= len(self.state):
                raise Error("MaxUtf8Acc.update_batch: gid out of range")
            var v = values[i]
            ref slot = self.state[g]
            if not slot:
                slot = Optional[String](v)
            else:
                if v > slot.value():
                    slot = Optional[String](v)

    def merge_at(mut self, dst_gid: Int, imm src: Self, src_gid: Int) raises:
        if dst_gid >= len(self.state):
            raise Error("MaxUtf8Acc.merge_at: dst_gid out of range")
        if src_gid >= len(src.state):
            raise Error("MaxUtf8Acc.merge_at: src_gid out of range")
        ref src_slot = src.state[src_gid]
        if not src_slot:
            return
        var v = src_slot.value()
        ref dst_slot = self.state[dst_gid]
        if not dst_slot:
            dst_slot = Optional[String](v)
        else:
            if v > dst_slot.value():
                dst_slot = Optional[String](v)

    # PERF-CRITICAL: aligned-gid full-column merge (Phase 0d). Scalar.
    def merge_aligned(mut self, imm src: Self) raises:
        var n = len(src.state)
        if len(self.state) != n:
            raise Error(
                "MaxUtf8Acc.merge_aligned: length mismatch (self=" +
                String(len(self.state)) + ", src=" + String(n) + ")"
            )
        for i in range(n):
            ref src_slot = src.state[i]
            if not src_slot:
                continue
            var v = src_slot.value()
            ref dst_slot = self.state[i]
            if not dst_slot:
                dst_slot = Optional[String](v)
            else:
                if v > dst_slot.value():
                    dst_slot = Optional[String](v)

    def finalize(self) -> List[Optional[String]]:
        var out = List[Optional[String]]()
        for i in range(len(self.state)):
            out.append(self.state[i])
        return out^

    def num_groups(self) -> Int:
        return len(self.state)

    # --- Accumulator trait conformance (Phase Acc-trait) ----------------------

    def update_batch[og: Origin, oc: Origin](
        mut self,
        gids: Span[Int, og],
        col_data: Span[UInt8, oc],
        col_offset: Int,
        n: Int,
    ) raises:
        """Trait-conforming stub. UTF8 accumulators need offsets buffer."""
        raise Error("MaxUtf8Acc: raw-pointer update_batch not supported for UTF8; use typed path")

    def finalize_to_column(mut self) raises -> Column[HeapRegion]:
        var strs = List[String]()
        for i in range(len(self.state)):
            ref slot = self.state[i]
            if slot:
                strs.append(slot.value())
            else:
                strs.append(String(""))
        var arr = StringArray.from_strings(strs)
        return Column.from_string(arr)

    def flush_partial_to_column(mut self) raises -> Column[HeapRegion]:
        return self.finalize_to_column()
