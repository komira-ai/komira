# =============================================================================
# Per-op SoA accumulators (Phase 1B Stage 1B) -- 4 fixed-width variants
# =============================================================================
#
# Sibling to `columnar_acc_typed.mojo` (which holds Sum/Count/Min/Max int64 +
# Kahan f64). Adding here keeps both files under the 1000-LOC Mojo JIT
# threshold. The architectural split:
#
#   columnar_acc_typed.mojo        : Sum/Count/Min/Max int64 + SumF64Kahan
#   columnar_acc_typed_extra.mojo  : CountStar / MinF64 / MaxF64 / Avg
#   columnar_acc_utf8.mojo         : MinUtf8 / MaxUtf8
#   columnar_acc_agg.mojo          : Percentile / CountDistinct
#
# Phase 1B Stage 1B scope: PURE ADDITIONS. These structs add the dispatch
# handles Phase 1B Stage 2 will consume (variant ports on FlatHashAggregator
# / ColumnarAggMap fixed-width path). No call sites consume them today; the
# Accumulator trait conformance + dispatch wiring lands in Stage 2.
#
# Reference sources (faithfully ported):
#   - v0.3 komira-engine/src/aggregate/columnar_accumulator.rs
#       * CountStarColumnarAcc       (line 550)
#       * MinF64ColumnarAcc          (line 571)
#       * MaxF64ColumnarAcc          (line 579)
#       * AvgColumnarAcc             (line 597)
#
# Each struct exposes a minimal surface area (matching the existing
# columnar_acc_typed.mojo Phase 0a shape):
#   - new() / __init__
#   - ensure_capacity(num_groups)  monotonic
#   - update_batch[origin_g, origin_v](gids_ptr, [values_ptr], num_rows)
#   - merge_at(dst_gid, src, src_gid)
#   - finalize() -> List[T] or List[Optional[T]]
#   - num_groups() -> Int
# =============================================================================

# =============================================================================
# CLUSTER-Z TODO: scheduled migration per an internal doc
# =============================================================================
# This file follows the same pointer / origin discipline as its sibling
# columnar_acc_typed.mojo: typed `update_batch` takes parametric Origin,
# no MutExternalOrigin fields, no UnsafePointer arithmetic outside the
# tight inner loops. The trait-conforming `update_batch` overloads take
# borrowed `Span`s (a raw pointer never appears in a signature); each body
# forms its typed pointer from them locally.
# =============================================================================

from std.sys import simd_width_of

from komira_core.arrow import ArrowType, Column
from komira_core.arrow.primitive_array import PrimitiveArray

from komira_op_agg_state.accumulator_trait import Accumulator
from komira_core.io.heap_region import HeapRegion


# -----------------------------------------------------------------------------
# Float64 sentinels (mirror Int64 sentinels in columnar_acc_typed.mojo).
# Float64 has no integer-style MAX/MIN literal -- use the bit patterns:
#   _F64_POS_INF = exponent all-1s, mantissa zero, sign 0  -> +Inf
#   _F64_NEG_INF = exponent all-1s, mantissa zero, sign 1  -> -Inf
# These are correct sentinels for MIN/MAX: any real value compares < +Inf
# (so MIN gets overwritten) and any real value > -Inf (so MAX gets
# overwritten). NaN is the only value that breaks the comparison; v0.3's
# null_state tracks "any non-null value seen" via a separate bitmap, same
# shape as MinI64Acc/MaxI64Acc here.
# -----------------------------------------------------------------------------

comptime _F64_POS_INF: Float64 = Float64.MAX
comptime _F64_NEG_INF: Float64 = Float64.MIN


# =============================================================================
# SIMD helpers (Phase 1B Stage 2A) -- mirror columnar_acc_typed.mojo helpers
# for Float64. Branchless select per mojo_autovec_patterns.md exp2.
# =============================================================================


@always_inline
def _simd_min_f64[width: Int](
    a: SIMD[DType.float64, width], b: SIMD[DType.float64, width]
) -> SIMD[DType.float64, width]:
    """Element-wise min for two f64 SIMD lanes (branchless select)."""
    return a.lt(b).select(a, b)


@always_inline
def _simd_max_f64[width: Int](
    a: SIMD[DType.float64, width], b: SIMD[DType.float64, width]
) -> SIMD[DType.float64, width]:
    """Element-wise max for two f64 SIMD lanes (branchless select)."""
    return a.gt(b).select(a, b)


# =============================================================================
# CountStarAcc -- COUNT(*) per gid, counts every row unconditionally
# =============================================================================
# v0.3 reference: CountStarColumnarAcc (columnar_accumulator.rs:550).
# No NullState: COUNT(*) is never NULL. update_batch increments by 1 per row,
# regardless of input column nullability (the input column may be absent).
# =============================================================================

struct CountStarAcc(Accumulator):
    """SoA COUNT(*) column: one Int64 per gid.

    Counts every row regardless of nulls. Distinct from CountI64Acc only
    by tag identity -- the two have identical update semantics today
    because v0.4's CountI64Acc does not yet honor null masks (caller
    pre-masks). Stage 2 may differentiate when null-aware COUNT(col)
    lands.
    """

    var state: List[Int64]

    def __init__(out self):
        self.state = List[Int64]()

    @staticmethod
    def new() -> Self:
        return Self()

    def ensure_capacity(mut self, num_groups: Int):
        # Monotonic grow -- caller MUST guarantee num_groups >= current len.
        while len(self.state) < num_groups:
            self.state.append(Int64(0))

    def update_batch[
        origin_g: Origin
    ](
        mut self,
        gids: Span[UInt32, origin_g],
        num_rows: Int,
    ) raises:
        for i in range(num_rows):
            var g = Int(gids[i])
            if g >= len(self.state):
                raise Error("CountStarAcc.update_batch: gid out of range")
            self.state[g] = self.state[g] + Int64(1)

    def merge_at(mut self, dst_gid: Int, imm src: Self, src_gid: Int) raises:
        if dst_gid >= len(self.state):
            raise Error("CountStarAcc.merge_at: dst_gid out of range")
        if src_gid >= len(src.state):
            raise Error("CountStarAcc.merge_at: src_gid out of range")
        self.state[dst_gid] = self.state[dst_gid] + src.state[src_gid]

    # PERF-CRITICAL: aligned-gid full-column merge (Phase 1B Stage 2A).
    # Same shape as CountI64Acc.merge_aligned -- counts sum additively.
    def merge_aligned(mut self, imm src: Self) raises:
        var n = len(src.state)
        if len(self.state) != n:
            raise Error(
                "CountStarAcc.merge_aligned: length mismatch (self="
                + String(len(self.state)) + ", src=" + String(n) + ")"
            )
        if n == 0:
            return
        var dst_ptr = self.state.unsafe_ptr()
        var src_ptr = src.state.unsafe_ptr()
        comptime W: Int = simd_width_of[DType.int64]()
        var simd_end = (n // W) * W
        var i = 0
        while i < simd_end:
            var da = dst_ptr.load[width=W](i)
            var sa = src_ptr.load[width=W](i)
            dst_ptr.store[width=W](i, da + sa)
            i += W
        while i < n:
            dst_ptr.store[width=1](
                i, dst_ptr.load[width=1](i) + src_ptr.load[width=1](i)
            )
            i += 1

    def finalize(self) -> List[Int64]:
        var out = List[Int64]()
        for i in range(len(self.state)):
            out.append(self.state[i])
        return out^

    def num_groups(self) -> Int:
        return len(self.state)

    # --- Accumulator trait conformance (Phase 1B Stage 2A) -------------------

    def update_batch[og: Origin, oc: Origin](
        mut self,
        gids: Span[Int, og],
        col_data: Span[UInt8, oc],
        col_offset: Int,
        n: Int,
    ) raises:
        """Trait-conforming update_batch: COUNT(*) ignores col, +1 per row.

        v0.3 reference: CountStarColumnarAcc::update_batch unconditionally
        increments per row regardless of column data or nullability.
        """
        # SAFETY: the pointers are formed from the borrowed spans and live only for
        # this call; the untracked origin and the nominal mutable cast keep the body's
        # pointer type unchanged (the kernels only read both buffers).
        var gids_ptr = (
            gids.unsafe_ptr()
            .unsafe_mut_cast[True]()
            .unsafe_origin_cast[MutUntrackedOrigin]()
        )
        for i in range(n):
            var g = gids_ptr[i]
            if g >= len(self.state):
                raise Error("CountStarAcc.update_batch: gid out of range")
            self.state[g] = self.state[g] + Int64(1)

    def finalize_to_column(mut self) raises -> Column[HeapRegion]:
        """Emit per-gid counts as an Int64 Arrow Column."""
        var arr = PrimitiveArray[DType.int64].allocate(len(self.state))
        for i in range(len(self.state)):
            arr.set(i, self.state[i])
        return Column.from_primitive[DType.int64](arr)

    def flush_partial_to_column(mut self) raises -> Column[HeapRegion]:
        """For COUNT, flush_partial == finalize (no pending state)."""
        return self.finalize_to_column()


# =============================================================================
# MinF64Acc -- per-gid Float64 minimum
# =============================================================================
# v0.3 reference: MinF64ColumnarAcc (columnar_accumulator.rs:571).
# Sentinel + seen bitmap mirror MinI64Acc; +Inf is the natural identity for
# Float64 MIN under SIMD branchless select.
# =============================================================================

struct MinF64Acc(Accumulator):
    """SoA MIN(Float64) column with sentinel + seen bitmap per gid."""

    var state: List[Float64]
    var seen: List[Bool]

    def __init__(out self):
        self.state = List[Float64]()
        self.seen = List[Bool]()

    @staticmethod
    def new() -> Self:
        return Self()

    def ensure_capacity(mut self, num_groups: Int):
        while len(self.state) < num_groups:
            self.state.append(_F64_POS_INF)
            self.seen.append(False)

    def update_batch[
        origin_g: Origin, origin_v: Origin
    ](
        mut self,
        gids: Span[UInt32, origin_g],
        values: Span[Float64, origin_v],
        num_rows: Int,
    ) raises:
        for i in range(num_rows):
            var g = Int(gids[i])
            if g >= len(self.state):
                raise Error("MinF64Acc.update_batch: gid out of range")
            var v = values[i]
            if v < self.state[g]:
                self.state[g] = v
            self.seen[g] = True

    def merge_at(mut self, dst_gid: Int, imm src: Self, src_gid: Int) raises:
        if dst_gid >= len(self.state):
            raise Error("MinF64Acc.merge_at: dst_gid out of range")
        if src_gid >= len(src.state):
            raise Error("MinF64Acc.merge_at: src_gid out of range")
        if not src.seen[src_gid]:
            return  # src unseen = no-op
        if not self.seen[dst_gid] or src.state[src_gid] < self.state[dst_gid]:
            self.state[dst_gid] = src.state[src_gid]
        self.seen[dst_gid] = True

    # PERF-CRITICAL: aligned-gid full-column merge (Phase 1B Stage 2A).
    # Same trick as MinI64Acc: unseen slots hold +Inf so unconditional SIMD
    # min against src.state is a no-op where src.seen is False. The seen
    # bitmap is folded separately with a scalar OR (one bool per group).
    def merge_aligned(mut self, imm src: Self) raises:
        var n = len(src.state)
        if (
            len(self.state) != n
            or len(self.seen) != n
            or len(src.seen) != n
        ):
            raise Error(
                "MinF64Acc.merge_aligned: length mismatch (self="
                + String(len(self.state)) + ", src=" + String(n) + ")"
            )
        if n == 0:
            return
        var dst_ptr = self.state.unsafe_ptr()
        var src_ptr = src.state.unsafe_ptr()
        comptime W: Int = simd_width_of[DType.float64]()
        var simd_end = (n // W) * W
        var i = 0
        while i < simd_end:
            var da = dst_ptr.load[width=W](i)
            var sa = src_ptr.load[width=W](i)
            dst_ptr.store[width=W](i, _simd_min_f64[W](da, sa))
            i += W
        while i < n:
            var a = dst_ptr.load[width=1](i)
            var b = src_ptr.load[width=1](i)
            if b < a:
                dst_ptr.store[width=1](i, b)
            i += 1
        # Fold seen bitmap.
        for j in range(n):
            if src.seen[j]:
                self.seen[j] = True

    def finalize(self) -> List[Optional[Float64]]:
        var out = List[Optional[Float64]]()
        for i in range(len(self.state)):
            if self.seen[i]:
                out.append(Optional[Float64](self.state[i]))
            else:
                out.append(Optional[Float64](None))
        return out^

    def num_groups(self) -> Int:
        return len(self.state)

    # --- Accumulator trait conformance (Phase 1B Stage 2A) -------------------

    def update_batch[og: Origin, oc: Origin](
        mut self,
        gids: Span[Int, og],
        col_data: Span[UInt8, oc],
        col_offset: Int,
        n: Int,
    ) raises:
        """Trait-conforming update_batch: bitcast col bytes to Float64."""
        # SAFETY: the pointers are formed from the borrowed spans and live only for
        # this call; the untracked origin and the nominal mutable cast keep the body's
        # pointer type unchanged (the kernels only read both buffers).
        var gids_ptr = (
            gids.unsafe_ptr()
            .unsafe_mut_cast[True]()
            .unsafe_origin_cast[MutUntrackedOrigin]()
        )
        var col_data_ptr = (
            col_data.unsafe_ptr()
            .unsafe_mut_cast[True]()
            .unsafe_origin_cast[MutUntrackedOrigin]()
        )
        var data_ptr = col_data_ptr.bitcast[Float64]()
        var off = col_offset
        for i in range(n):
            var g = gids_ptr[i]
            if g >= len(self.state):
                raise Error("MinF64Acc.update_batch: gid out of range")
            var v = (data_ptr + off + i)[]
            if v < self.state[g]:
                self.state[g] = v
            self.seen[g] = True

    def finalize_to_column(mut self) raises -> Column[HeapRegion]:
        """Emit per-gid min as a Float64 Arrow Column.

        Sentinel for unseen groups: 0.0 (matches MinI64Acc finalize_to_column
        which preserves the bit pattern of unseen state). Callers needing
        SQL-NULL semantics use the Optional finalize path.
        """
        var arr = PrimitiveArray[DType.float64].allocate(len(self.state))
        for i in range(len(self.state)):
            if self.seen[i]:
                arr.set(i, self.state[i])
            # else: stays 0.0 (zero-initialized by allocate)
        return Column.from_primitive[DType.float64](arr)

    def flush_partial_to_column(mut self) raises -> Column[HeapRegion]:
        return self.finalize_to_column()


# =============================================================================
# MaxF64Acc -- per-gid Float64 maximum
# =============================================================================
# v0.3 reference: MaxF64ColumnarAcc (columnar_accumulator.rs:579).
# Mirror of MinF64Acc with sentinel inverted (-Inf).
# =============================================================================

struct MaxF64Acc(Accumulator):
    """SoA MAX(Float64) column with sentinel + seen bitmap per gid."""

    var state: List[Float64]
    var seen: List[Bool]

    def __init__(out self):
        self.state = List[Float64]()
        self.seen = List[Bool]()

    @staticmethod
    def new() -> Self:
        return Self()

    def ensure_capacity(mut self, num_groups: Int):
        while len(self.state) < num_groups:
            self.state.append(_F64_NEG_INF)
            self.seen.append(False)

    def update_batch[
        origin_g: Origin, origin_v: Origin
    ](
        mut self,
        gids: Span[UInt32, origin_g],
        values: Span[Float64, origin_v],
        num_rows: Int,
    ) raises:
        for i in range(num_rows):
            var g = Int(gids[i])
            if g >= len(self.state):
                raise Error("MaxF64Acc.update_batch: gid out of range")
            var v = values[i]
            if v > self.state[g]:
                self.state[g] = v
            self.seen[g] = True

    def merge_at(mut self, dst_gid: Int, imm src: Self, src_gid: Int) raises:
        if dst_gid >= len(self.state):
            raise Error("MaxF64Acc.merge_at: dst_gid out of range")
        if src_gid >= len(src.state):
            raise Error("MaxF64Acc.merge_at: src_gid out of range")
        if not src.seen[src_gid]:
            return
        if not self.seen[dst_gid] or src.state[src_gid] > self.state[dst_gid]:
            self.state[dst_gid] = src.state[src_gid]
        self.seen[dst_gid] = True

    # PERF-CRITICAL: aligned-gid full-column merge (Phase 1B Stage 2A).
    # Mirror of MinF64Acc.merge_aligned with sentinel inverted (-Inf).
    def merge_aligned(mut self, imm src: Self) raises:
        var n = len(src.state)
        if (
            len(self.state) != n
            or len(self.seen) != n
            or len(src.seen) != n
        ):
            raise Error(
                "MaxF64Acc.merge_aligned: length mismatch (self="
                + String(len(self.state)) + ", src=" + String(n) + ")"
            )
        if n == 0:
            return
        var dst_ptr = self.state.unsafe_ptr()
        var src_ptr = src.state.unsafe_ptr()
        comptime W: Int = simd_width_of[DType.float64]()
        var simd_end = (n // W) * W
        var i = 0
        while i < simd_end:
            var da = dst_ptr.load[width=W](i)
            var sa = src_ptr.load[width=W](i)
            dst_ptr.store[width=W](i, _simd_max_f64[W](da, sa))
            i += W
        while i < n:
            var a = dst_ptr.load[width=1](i)
            var b = src_ptr.load[width=1](i)
            if b > a:
                dst_ptr.store[width=1](i, b)
            i += 1
        for j in range(n):
            if src.seen[j]:
                self.seen[j] = True

    def finalize(self) -> List[Optional[Float64]]:
        var out = List[Optional[Float64]]()
        for i in range(len(self.state)):
            if self.seen[i]:
                out.append(Optional[Float64](self.state[i]))
            else:
                out.append(Optional[Float64](None))
        return out^

    def num_groups(self) -> Int:
        return len(self.state)

    # --- Accumulator trait conformance (Phase 1B Stage 2A) -------------------

    def update_batch[og: Origin, oc: Origin](
        mut self,
        gids: Span[Int, og],
        col_data: Span[UInt8, oc],
        col_offset: Int,
        n: Int,
    ) raises:
        """Trait-conforming update_batch: bitcast col bytes to Float64."""
        # SAFETY: the pointers are formed from the borrowed spans and live only for
        # this call; the untracked origin and the nominal mutable cast keep the body's
        # pointer type unchanged (the kernels only read both buffers).
        var gids_ptr = (
            gids.unsafe_ptr()
            .unsafe_mut_cast[True]()
            .unsafe_origin_cast[MutUntrackedOrigin]()
        )
        var col_data_ptr = (
            col_data.unsafe_ptr()
            .unsafe_mut_cast[True]()
            .unsafe_origin_cast[MutUntrackedOrigin]()
        )
        var data_ptr = col_data_ptr.bitcast[Float64]()
        var off = col_offset
        for i in range(n):
            var g = gids_ptr[i]
            if g >= len(self.state):
                raise Error("MaxF64Acc.update_batch: gid out of range")
            var v = (data_ptr + off + i)[]
            if v > self.state[g]:
                self.state[g] = v
            self.seen[g] = True

    def finalize_to_column(mut self) raises -> Column[HeapRegion]:
        """Emit per-gid max as a Float64 Arrow Column. Sentinel: 0.0."""
        var arr = PrimitiveArray[DType.float64].allocate(len(self.state))
        for i in range(len(self.state)):
            if self.seen[i]:
                arr.set(i, self.state[i])
        return Column.from_primitive[DType.float64](arr)

    def flush_partial_to_column(mut self) raises -> Column[HeapRegion]:
        return self.finalize_to_column()


# =============================================================================
# AvgAcc -- per-gid AVG(Float64) via Kahan-compensated sum + count
# =============================================================================
# v0.3 reference: AvgColumnarAcc (columnar_accumulator.rs:597).
#
# State per gid: sum (Float64), comp (Kahan compensation, Float64), count
# (Int64). finalize() returns Optional[Float64] = sum/count (None when
# count==0). The Kahan compensation matches SumF64KahanAcc's accumulator.rs
# update formula.
# =============================================================================

struct AvgAcc(Accumulator):
    """SoA AVG(Float64) column: per-gid Kahan sum + count."""

    var sum: List[Float64]
    var comp: List[Float64]
    var count: List[Int64]

    def __init__(out self):
        self.sum = List[Float64]()
        self.comp = List[Float64]()
        self.count = List[Int64]()

    @staticmethod
    def new() -> Self:
        return Self()

    def ensure_capacity(mut self, num_groups: Int):
        while len(self.sum) < num_groups:
            self.sum.append(Float64(0.0))
            self.comp.append(Float64(0.0))
            self.count.append(Int64(0))

    def update_batch[
        origin_g: Origin, origin_v: Origin
    ](
        mut self,
        gids: Span[UInt32, origin_g],
        values: Span[Float64, origin_v],
        num_rows: Int,
    ) raises:
        # Scalar Kahan per accumulator.rs:179-195 -- bit-identical to
        # SumF64KahanAcc.update_batch. Count increments by 1 per row.
        for i in range(num_rows):
            var g = Int(gids[i])
            if g >= len(self.sum):
                raise Error("AvgAcc.update_batch: gid out of range")
            var v = values[i]
            var s = self.sum[g]
            var c = self.comp[g]
            var y = v - c
            var t = s + y
            self.comp[g] = (t - s) - y
            self.sum[g] = t
            self.count[g] = self.count[g] + Int64(1)

    def merge_at(mut self, dst_gid: Int, imm src: Self, src_gid: Int) raises:
        # Verbatim port of accumulator.rs:198-211 Kahan cross-worker merge.
        if dst_gid >= len(self.sum):
            raise Error("AvgAcc.merge_at: dst_gid out of range")
        if src_gid >= len(src.sum):
            raise Error("AvgAcc.merge_at: src_gid out of range")
        var dst_sum = self.sum[dst_gid]
        var dst_comp = self.comp[dst_gid]
        var src_sum = src.sum[src_gid]
        var src_comp = src.comp[src_gid]
        var total_comp = dst_comp + src_comp
        var y = src_sum - total_comp
        var t = dst_sum + y
        self.comp[dst_gid] = (t - dst_sum) - y
        self.sum[dst_gid] = t
        self.count[dst_gid] = self.count[dst_gid] + src.count[src_gid]

    # PERF-CRITICAL: aligned-gid full-column merge (Phase 1B Stage 2A).
    # Matches SumF64KahanAcc.merge_aligned shape: scalar Kahan loop for
    # bit-identity with v0.3, plus additive count merge. Used by the
    # cross-worker S3 aggregator path through AvgAcc's vtable
    # `_merge_aligned_avg` thunk.
    def merge_aligned(mut self, imm src: Self) raises:
        var n = len(src.sum)
        if (
            len(self.sum) != n
            or len(self.comp) != n
            or len(src.comp) != n
            or len(self.count) != n
            or len(src.count) != n
        ):
            raise Error(
                "AvgAcc.merge_aligned: length mismatch (self="
                + String(len(self.sum)) + ", src=" + String(n) + ")"
            )
        for i in range(n):
            var dst_sum = self.sum[i]
            var dst_comp = self.comp[i]
            var src_sum = src.sum[i]
            var src_comp = src.comp[i]
            var total_comp = dst_comp + src_comp
            var y = src_sum - total_comp
            var t = dst_sum + y
            self.comp[i] = (t - dst_sum) - y
            self.sum[i] = t
            self.count[i] = self.count[i] + src.count[i]

    def finalize(self) -> List[Optional[Float64]]:
        var out = List[Optional[Float64]]()
        for i in range(len(self.sum)):
            var c = self.count[i]
            if c > Int64(0):
                out.append(Optional[Float64](self.sum[i] / Float64(c)))
            else:
                out.append(Optional[Float64](None))
        return out^

    def num_groups(self) -> Int:
        return len(self.sum)

    # --- Accumulator trait conformance (Phase 1B Stage 2A) -------------------

    def update_batch[og: Origin, oc: Origin](
        mut self,
        gids: Span[Int, og],
        col_data: Span[UInt8, oc],
        col_offset: Int,
        n: Int,
    ) raises:
        """Trait-conforming update_batch: per-row Kahan sum + count++."""
        # SAFETY: the pointers are formed from the borrowed spans and live only for
        # this call; the untracked origin and the nominal mutable cast keep the body's
        # pointer type unchanged (the kernels only read both buffers).
        var gids_ptr = (
            gids.unsafe_ptr()
            .unsafe_mut_cast[True]()
            .unsafe_origin_cast[MutUntrackedOrigin]()
        )
        var col_data_ptr = (
            col_data.unsafe_ptr()
            .unsafe_mut_cast[True]()
            .unsafe_origin_cast[MutUntrackedOrigin]()
        )
        var data_ptr = col_data_ptr.bitcast[Float64]()
        var off = col_offset
        for i in range(n):
            var g = gids_ptr[i]
            if g >= len(self.sum):
                raise Error("AvgAcc.update_batch: gid out of range")
            var v = (data_ptr + off + i)[]
            var s = self.sum[g]
            var c = self.comp[g]
            var y = v - c
            var t = s + y
            self.comp[g] = (t - s) - y
            self.sum[g] = t
            self.count[g] = self.count[g] + Int64(1)

    def finalize_to_column(mut self) raises -> Column[HeapRegion]:
        """Emit per-gid avg = sum/count as a Float64 Column. Sentinel: 0.0
        for unseen groups (count==0)."""
        var arr = PrimitiveArray[DType.float64].allocate(len(self.sum))
        for i in range(len(self.sum)):
            var c = self.count[i]
            if c > Int64(0):
                arr.set(i, self.sum[i] / Float64(c))
            # else: stays 0.0
        return Column.from_primitive[DType.float64](arr)

    def flush_partial_to_column(mut self) raises -> Column[HeapRegion]:
        return self.finalize_to_column()
