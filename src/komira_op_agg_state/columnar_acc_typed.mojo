# =============================================================================
# Numeric Typed SoA Accumulators (Phase 0a + 0d SIMD merge)
# =============================================================================
#
# This file owns the FIXED-WIDTH numeric accumulator family:
#   - SumI64Acc / CountI64Acc / MinI64Acc / MaxI64Acc (Int64)
#   - SumF64KahanAcc (Float64, Kahan-compensated)
#
# Companion files (split out per PE Phase 0d concern #3 — combined file
# crossed the 1000-line Mojo JIT hang threshold):
#   - `columnar_acc_utf8.mojo`  : MinUtf8Acc, MaxUtf8Acc (variable-width)
#   - `columnar_acc_agg.mojo`   : PercentileAcc, CountDistinctAcc
#                                 (specialized buffer+finalize semantics)
#
# AccumulatorEnum dispatch (acc_enum.mojo) imports across all three files; the
# split does not change any external API surface beyond import paths.
#
# Reference sources (faithfully ported):
#   - `komira-engine/src/aggregate/columnar_accumulator.rs`
#       * SumI64ColumnarAcc (line ~537) / CountColumnarAcc / MinI64 / MaxI64
#       * SumF64ColumnarAcc with Kahan compensation (~line 535-540)
#   - `komira-engine/src/aggregate/accumulator.rs` lines 167-222
#       * Kahan update formula + cross-worker merge formula — verbatim port
#   - an internal doc §0, §2, §3
#
# Each struct below exposes a minimal surface area:
#   - new / ensure_capacity(monotonic) / update_batch / merge_at / finalize
#
# The `finalize` return type is a plain List at Phase 0a — callers currently
# use the tagged-union's finalize_int64 / finalize_utf8 accessors; adopting
# PrimitiveArray/StringArray happens when ColumnarAggMap flips to SoA
# storage (Phase 0b). Keeping finalize "plain" makes 0a unit-testable in
# isolation without pulling the whole arrow column layer into the blast
# radius.
#
# Mojo gotchas observed (see also feedback_mojo_*.md):
#   - `List[T]` requires T: CollectionElement (Movable + Copyable). For
#     variable-length per-gid slabs (PercentileAcc, CountDistinctAcc) we use
#     `List[List[Float64]]` / `List[List[Int64]]` which is fine because
#     List[Scalar] is Copyable.
#   - `UnsafePointer[Scalar[T]]` replaces the removed `DTypePointer`.
#   - `parallelize()` closures cannot raise — all allocation growth happens
#     in `ensure_capacity`, monotonic, never inside update_batch's inner
#     loop except via List.append under the non-parallel path.
#   - Movable-only (no Copyable) — every struct owns Lists / contains no
#     pointer aliases that could be dangling after copy.
# =============================================================================

# Phase 0d imports SIMD width helper from sys.info. Math utilities (isnan,
# abs) are still handled via inline tricks (v != v for NaN; conditional
# negate for abs).
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

from std.sys import simd_width_of

# Phase Accumulator-trait: Column extraction for trait-conforming update_batch.
from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_collections.slab import Slab
from komira_op_agg_state.accumulator_trait import Accumulator
from komira_buffer.heap_region import HeapRegion


# =============================================================================
# SIMD helpers — Phase 0d
# =============================================================================
# Per an internal doc:
#   - Reductions over typed pointers do NOT auto-vectorize (4.7x scalar penalty).
#   - Conditional reductions are even worse (9.2x penalty).
#   - FMA is never synthesized from scalar mul+add (3.5x penalty).
# So we write merge kernels with explicit SIMD[T, W].load/store + reduce.
# =============================================================================


@always_inline
def _simd_min_i64[width: Int](
    a: SIMD[DType.int64, width], b: SIMD[DType.int64, width]
) -> SIMD[DType.int64, width]:
    """Element-wise min for two int64 SIMD lanes (branchless select)."""
    return a.lt(b).select(a, b)


@always_inline
def _simd_max_i64[width: Int](
    a: SIMD[DType.int64, width], b: SIMD[DType.int64, width]
) -> SIMD[DType.int64, width]:
    """Element-wise max for two int64 SIMD lanes (branchless select)."""
    return a.gt(b).select(a, b)


# =============================================================================
# PERF-CRITICAL: SumI64Acc — column of per-gid i64 running totals
# =============================================================================
# Regression if removed: SUM(int64) falls back to the tagged-union
#     ColumnarAccumulator with (utf8_values, int64_values) dual-List overhead
#     and per-row tag-branch dispatch. Per v0.4 design §0 this blocks SIMD
#     reduce across a batch.
# Measured impact:        Expected 1.5-3x on B-5 SUM hot loop post Phase 0c;
# v0.3 parity is the floor. (pre-port)
# DuckDB equivalent:      column-by-column group sum (sum_aggregate.cpp)
# Do NOT delete without:  tests/test_columnar_acc_typed.mojo passing AND
#     B-5 bench within +/- 5% of the last Step 3d.3 baseline.
# =============================================================================
struct SumI64Acc(Accumulator):
    """SoA SUM(Int64) column: one Int64 per gid."""

    var state: List[Int64]

    def __init__(out self):
        self.state = List[Int64]()

    @staticmethod
    def new() -> Self:
        return Self()

    def ensure_capacity(mut self, num_groups: Int):
        # PERF-CRITICAL: monotonic grow — caller MUST ensure num_groups >=
        # current len. Matches v0.3 invariant (ArenaGroupStore only grows).
        while len(self.state) < num_groups:
            self.state.append(Int64(0))

    def update_batch[
        origin_g: Origin, origin_v: Origin
    ](
        mut self,
        gids: Span[UInt32, origin_g],
        values: Span[Int64, origin_v],
        num_rows: Int,
    ) raises:
        # NOT-VECTORIZABLE: Scatter-add to random group IDs. gids[i] are
        # arbitrary, so state[gid] += val has write conflicts between lanes.
        # v0.3 equivalent: SumI64ColumnarAcc::update_batch (scatter loop).
        for i in range(num_rows):
            var g = Int(gids[i])
            if g >= len(self.state):
                raise Error("SumI64Acc.update_batch: gid out of range — caller must ensure_capacity first")
            self.state[g] = self.state[g] + values[i]

    def merge_at(mut self, dst_gid: Int, imm src: Self, src_gid: Int) raises:
        if dst_gid >= len(self.state):
            raise Error("SumI64Acc.merge_at: dst_gid out of range")
        if src_gid >= len(src.state):
            raise Error("SumI64Acc.merge_at: src_gid out of range")
        self.state[dst_gid] = self.state[dst_gid] + src.state[src_gid]

    # PERF-CRITICAL: aligned-gid full-column merge for the combine fast path.
    # =========================================================================
    # When both SoA columns share the same gid space (e.g. cross-worker S3
    # aggregators that were built against an identical presorted key-stream),
    # merge reduces to `dst.state[i] += src.state[i]` for every gid. This is
    # the archetypal SIMD-reduce shape from mojo_autovec_patterns.md exp1 —
    # scalar compiles to pure `fadd d0,d1,d0`; explicit SIMD is 4.7x faster.
    #
    # Contract: caller guarantees self.num_groups() == src.num_groups() AND
    # the gid at index i in `self` refers to the same logical group as the
    # gid at index i in `src`. merge_from / merge_from_partition DO NOT meet
    # this contract (they probe and produce arbitrary dst gids); only aligned
    # combines (same-schema cross-worker S3) do.
    #
    # Correctness: bit-identical to the scalar `merge_at` loop for int64
    # (int addition is associative + commutative at the bit level).
    # =========================================================================
    def merge_aligned(mut self, imm src: Self) raises:
        var n = len(src.state)
        if len(self.state) != n:
            raise Error(
                "SumI64Acc.merge_aligned: length mismatch (self=" +
                String(len(self.state)) + ", src=" + String(n) + ")"
            )
        if n == 0:
            return
        # SAFETY: List[Int64].unsafe_ptr() returns a pointer valid for `len`
        # int64 elements. We don't grow either list during the loop. The
        # typed ptr escape is scoped to this function.
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
        # Scalar tail.
        while i < n:
            dst_ptr.store[width=1](i, dst_ptr.load[width=1](i) + src_ptr.load[width=1](i))
            i += 1

    def finalize(self) -> List[Int64]:
        # Phase 0a: returns the raw state list. Phase 0b will wrap in
        # PrimitiveArray[DType.int64] for Arrow output.
        var out = List[Int64]()
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
        """Trait-conforming update_batch: extract Int64 ptr from Column."""
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
        var data_ptr = col_data_ptr.bitcast[Int64]()
        var off = col_offset
        for i in range(n):
            var g = gids_ptr[i]
            if g >= len(self.state):
                raise Error("SumI64Acc.update_batch: gid out of range")
            self.state[g] = self.state[g] + (data_ptr + off + i)[]

    def finalize_to_column(mut self) raises -> Column[HeapRegion]:
        """Trait-conforming finalize: wrap state as Arrow Column."""
        var arr = PrimitiveArray[DType.int64].allocate(len(self.state))
        for i in range(len(self.state)):
            arr.set(i, self.state[i])
        return Column.from_primitive[DType.int64](arr)

    def flush_partial_to_column(mut self) raises -> Column[HeapRegion]:
        """For SUM, flush_partial == finalize (no pending computation)."""
        return self.finalize_to_column()


# =============================================================================
# PERF-CRITICAL: CountI64Acc — column of per-gid non-null counts
# =============================================================================
# Regression if removed: same path as SumI64Acc falls back to tagged-union.
# DuckDB equivalent:      count_aggregate.cpp
# Do NOT delete without:  tests/test_columnar_acc_typed.mojo passing.
# =============================================================================
struct CountI64Acc(Accumulator):
    """SoA COUNT(col) column: one Int64 per gid.

    SQL semantics: null values do NOT contribute. The caller pre-masks nulls
    so `update_batch` always adds 1. COUNT(*) uses the same struct with a
    non-null synthetic column.
    """

    var state: List[Int64]

    def __init__(out self):
        self.state = List[Int64]()

    @staticmethod
    def new() -> Self:
        return Self()

    def ensure_capacity(mut self, num_groups: Int):
        while len(self.state) < num_groups:
            self.state.append(Int64(0))

    def update_batch[
        origin_g: Origin
    ](
        mut self,
        gids: Span[UInt32, origin_g],
        num_rows: Int,
    ) raises:
        # Note: no `values` arg — counting is increment-by-1. Caller pre-masks.
        for i in range(num_rows):
            var g = Int(gids[i])
            if g >= len(self.state):
                raise Error("CountI64Acc.update_batch: gid out of range")
            self.state[g] = self.state[g] + Int64(1)

    def merge_at(mut self, dst_gid: Int, imm src: Self, src_gid: Int) raises:
        if dst_gid >= len(self.state):
            raise Error("CountI64Acc.merge_at: dst_gid out of range")
        if src_gid >= len(src.state):
            raise Error("CountI64Acc.merge_at: src_gid out of range")
        self.state[dst_gid] = self.state[dst_gid] + src.state[src_gid]

    # PERF-CRITICAL: aligned-gid full-column merge (Phase 0d).
    # Same shape as SumI64Acc.merge_aligned — counts sum additively.
    def merge_aligned(mut self, imm src: Self) raises:
        var n = len(src.state)
        if len(self.state) != n:
            raise Error(
                "CountI64Acc.merge_aligned: length mismatch (self=" +
                String(len(self.state)) + ", src=" + String(n) + ")"
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
            dst_ptr.store[width=1](i, dst_ptr.load[width=1](i) + src_ptr.load[width=1](i))
            i += 1

    def finalize(self) -> List[Int64]:
        var out = List[Int64]()
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
        """Trait-conforming update_batch: COUNT ignores col, +1 per row."""
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
                raise Error("CountI64Acc.update_batch: gid out of range")
            self.state[g] = self.state[g] + Int64(1)

    def finalize_to_column(mut self) raises -> Column[HeapRegion]:
        var arr = PrimitiveArray[DType.int64].allocate(len(self.state))
        for i in range(len(self.state)):
            arr.set(i, self.state[i])
        return Column.from_primitive[DType.int64](arr)

    def flush_partial_to_column(mut self) raises -> Column[HeapRegion]:
        return self.finalize_to_column()


# -----------------------------------------------------------------------------
# MIN / MAX sentinels
# -----------------------------------------------------------------------------
# v0.3 uses an external NullState bitmap to track "group has seen a non-null
# value yet"; sentinels are NOT used there. The v0.4 design doc §0 specifies
# sentinel initialization (Int64.MAX for MIN, Int64.MIN for MAX) PLUS a
# parallel `seen: List[Bool]` to disambiguate "group had only nulls" from
# "group saw INT64_MIN as a real value" — we carry both to keep parity with
# v0.3 null semantics without allocating a NullState/Bitmap in Phase 0a.
#
# Sentinel values reserved:
comptime _INT64_MAX: Int64 = Int64(9223372036854775807)      # 2^63 - 1
comptime _INT64_MIN: Int64 = Int64(-9223372036854775808)     # -2^63


# =============================================================================
# PERF-CRITICAL: MinI64Acc — per-gid i64 minimum
# =============================================================================
# Regression if removed: MIN(int64) falls back to tagged-union dispatch.
# DuckDB equivalent:      min_max_aggregate.cpp
# Do NOT delete without:  tests/test_columnar_acc_typed.mojo passing.
# =============================================================================
struct MinI64Acc(Accumulator):
    """SoA MIN(Int64) column with sentinel + seen bitmap per gid."""

    var state: List[Int64]
    var seen: List[Bool]

    def __init__(out self):
        self.state = List[Int64]()
        self.seen = List[Bool]()

    @staticmethod
    def new() -> Self:
        return Self()

    def ensure_capacity(mut self, num_groups: Int):
        while len(self.state) < num_groups:
            self.state.append(_INT64_MAX)
            self.seen.append(False)

    def update_batch[
        origin_g: Origin, origin_v: Origin
    ](
        mut self,
        gids: Span[UInt32, origin_g],
        values: Span[Int64, origin_v],
        num_rows: Int,
    ) raises:
        for i in range(num_rows):
            var g = Int(gids[i])
            if g >= len(self.state):
                raise Error("MinI64Acc.update_batch: gid out of range")
            var v = values[i]
            if v < self.state[g]:
                self.state[g] = v
            self.seen[g] = True

    def merge_at(mut self, dst_gid: Int, imm src: Self, src_gid: Int) raises:
        if dst_gid >= len(self.state):
            raise Error("MinI64Acc.merge_at: dst_gid out of range")
        if src_gid >= len(src.state):
            raise Error("MinI64Acc.merge_at: src_gid out of range")
        if not src.seen[src_gid]:
            return  # src unseen = no-op
        if not self.seen[dst_gid] or src.state[src_gid] < self.state[dst_gid]:
            self.state[dst_gid] = src.state[src_gid]
        self.seen[dst_gid] = True

    # PERF-CRITICAL: aligned-gid full-column merge (Phase 0d).
    # =========================================================================
    # Exploits the sentinel design: unseen slots hold `_INT64_MAX`, so an
    # unconditional SIMD min against `src.state` is a no-op where src.seen is
    # False. The `seen` bitmap is folded separately with a scalar OR loop
    # (List[Bool] doesn't trivially SIMD without a bitmap representation;
    # n is small here — one bool per group, not per row).
    #
    # Per mojo_autovec_patterns.md exp2: branchy `if v < t: sum += v` stays
    # scalar (9.2x slow). We use SIMD.lt().select() pattern from stats.mojo.
    # =========================================================================
    def merge_aligned(mut self, imm src: Self) raises:
        var n = len(src.state)
        if len(self.state) != n or len(self.seen) != n or len(src.seen) != n:
            raise Error(
                "MinI64Acc.merge_aligned: length mismatch (self=" +
                String(len(self.state)) + ", src=" + String(n) + ")"
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
            dst_ptr.store[width=W](i, _simd_min_i64[W](da, sa))
            i += W
        while i < n:
            var a = dst_ptr.load[width=1](i)
            var b = src_ptr.load[width=1](i)
            if b < a:
                dst_ptr.store[width=1](i, b)
            i += 1

        # Fold seen bitmap. Not SIMD (List[Bool] lacks typed ptr semantics
        # worth vectorizing here; n = num_groups, usually <= million, and
        # this is one byte per group not per row — see §6.4 design doc).
        for j in range(n):
            if src.seen[j]:
                self.seen[j] = True

    def finalize(self) -> List[Optional[Int64]]:
        # Phase 0a: List[Optional[Int64]] encodes SQL nulls cleanly.
        var out = List[Optional[Int64]]()
        for i in range(len(self.state)):
            if self.seen[i]:
                out.append(Optional[Int64](self.state[i]))
            else:
                out.append(Optional[Int64](None))
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
        var data_ptr = col_data_ptr.bitcast[Int64]()
        var off = col_offset
        for i in range(n):
            var g = gids_ptr[i]
            if g >= len(self.state):
                raise Error("MinI64Acc.update_batch: gid out of range")
            var v = (data_ptr + off + i)[]
            if v < self.state[g]:
                self.state[g] = v
            self.seen[g] = True

    def finalize_to_column(mut self) raises -> Column[HeapRegion]:
        var arr = PrimitiveArray[DType.int64].allocate(len(self.state))
        for i in range(len(self.state)):
            arr.set(i, self.state[i])
        return Column.from_primitive[DType.int64](arr)

    def flush_partial_to_column(mut self) raises -> Column[HeapRegion]:
        return self.finalize_to_column()


# =============================================================================
# PERF-CRITICAL: MaxI64Acc — per-gid i64 maximum
# =============================================================================
struct MaxI64Acc(Accumulator):
    """SoA MAX(Int64) column with sentinel + seen bitmap per gid."""

    var state: List[Int64]
    var seen: List[Bool]

    def __init__(out self):
        self.state = List[Int64]()
        self.seen = List[Bool]()

    @staticmethod
    def new() -> Self:
        return Self()

    def ensure_capacity(mut self, num_groups: Int):
        while len(self.state) < num_groups:
            self.state.append(_INT64_MIN)
            self.seen.append(False)

    def update_batch[
        origin_g: Origin, origin_v: Origin
    ](
        mut self,
        gids: Span[UInt32, origin_g],
        values: Span[Int64, origin_v],
        num_rows: Int,
    ) raises:
        for i in range(num_rows):
            var g = Int(gids[i])
            if g >= len(self.state):
                raise Error("MaxI64Acc.update_batch: gid out of range")
            var v = values[i]
            if v > self.state[g]:
                self.state[g] = v
            self.seen[g] = True

    def merge_at(mut self, dst_gid: Int, imm src: Self, src_gid: Int) raises:
        if dst_gid >= len(self.state):
            raise Error("MaxI64Acc.merge_at: dst_gid out of range")
        if src_gid >= len(src.state):
            raise Error("MaxI64Acc.merge_at: src_gid out of range")
        if not src.seen[src_gid]:
            return
        if not self.seen[dst_gid] or src.state[src_gid] > self.state[dst_gid]:
            self.state[dst_gid] = src.state[src_gid]
        self.seen[dst_gid] = True

    # PERF-CRITICAL: aligned-gid full-column merge (Phase 0d).
    # Mirror of MinI64Acc.merge_aligned with sentinel inverted (_INT64_MIN).
    def merge_aligned(mut self, imm src: Self) raises:
        var n = len(src.state)
        if len(self.state) != n or len(self.seen) != n or len(src.seen) != n:
            raise Error(
                "MaxI64Acc.merge_aligned: length mismatch (self=" +
                String(len(self.state)) + ", src=" + String(n) + ")"
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
            dst_ptr.store[width=W](i, _simd_max_i64[W](da, sa))
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

    def finalize(self) -> List[Optional[Int64]]:
        var out = List[Optional[Int64]]()
        for i in range(len(self.state)):
            if self.seen[i]:
                out.append(Optional[Int64](self.state[i]))
            else:
                out.append(Optional[Int64](None))
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
        var data_ptr = col_data_ptr.bitcast[Int64]()
        var off = col_offset
        for i in range(n):
            var g = gids_ptr[i]
            if g >= len(self.state):
                raise Error("MaxI64Acc.update_batch: gid out of range")
            var v = (data_ptr + off + i)[]
            if v > self.state[g]:
                self.state[g] = v
            self.seen[g] = True

    def finalize_to_column(mut self) raises -> Column[HeapRegion]:
        var arr = PrimitiveArray[DType.int64].allocate(len(self.state))
        for i in range(len(self.state)):
            arr.set(i, self.state[i])
        return Column.from_primitive[DType.int64](arr)

    def flush_partial_to_column(mut self) raises -> Column[HeapRegion]:
        return self.finalize_to_column()


# =============================================================================
# PERF-CRITICAL: SumF64KahanAcc — per-gid Float64 sum, Kahan compensated
# =============================================================================
# Default-on Kahan summation per v0.4 design §3. The STRICT_PRECISION flag
# from the previous revision is removed — Kahan is the spec, not an option.
# Cross-worker merge formula is a VERBATIM port of accumulator.rs:198-211;
# never do `sum += other.sum; comp += other.comp` which loses the coupling.
#
# Regression if removed: Float64 SUM drifts to O(n*eps) error at scale; v0.3
# TPC-H Q1 (6M rows * f64) exposes ~0.01% drift without Kahan.
# DuckDB equivalent:      sum_aggregate.cpp kahan path.
# Do NOT delete without:  Kahan precision test in
#     tests/test_columnar_acc_typed.mojo passing (1M * 0.1 naive vs Kahan).
# =============================================================================
struct SumF64KahanAcc(Accumulator):
    """SoA SUM(Float64) column with per-gid Kahan compensation term.

    Fields:
        sum:   running total per gid.
        comp:  compensation term per gid. Represents the low-order bits
               accumulated during the classic Kahan cancellation.
    """

    var sum: List[Float64]
    var comp: List[Float64]

    def __init__(out self):
        self.sum = List[Float64]()
        self.comp = List[Float64]()

    @staticmethod
    def new() -> Self:
        return Self()

    def ensure_capacity(mut self, num_groups: Int):
        while len(self.sum) < num_groups:
            self.sum.append(Float64(0.0))
            self.comp.append(Float64(0.0))

    def update_batch[
        origin_g: Origin, origin_v: Origin
    ](
        mut self,
        gids: Span[UInt32, origin_g],
        values: Span[Float64, origin_v],
        num_rows: Int,
    ) raises:
        # Scalar Kahan per accumulator.rs:179-195. The SIMD Neumaier path
        # lands in Phase 0c once call-site unrolling is wired (design §6.3).
        # Keeping scalar Kahan here gives bit-for-bit parity with v0.3 on
        # existing test vectors.
        for i in range(num_rows):
            var g = Int(gids[i])
            if g >= len(self.sum):
                raise Error("SumF64KahanAcc.update_batch: gid out of range")
            var v = values[i]
            var s = self.sum[g]
            var c = self.comp[g]
            var y = v - c
            var t = s + y
            self.comp[g] = (t - s) - y
            self.sum[g] = t

    def merge_at(mut self, dst_gid: Int, imm src: Self, src_gid: Int) raises:
        # VERBATIM port of accumulator.rs:198-211 — do not "simplify".
        if dst_gid >= len(self.sum):
            raise Error("SumF64KahanAcc.merge_at: dst_gid out of range")
        if src_gid >= len(src.sum):
            raise Error("SumF64KahanAcc.merge_at: src_gid out of range")
        var dst_sum = self.sum[dst_gid]
        var dst_comp = self.comp[dst_gid]
        var src_sum = src.sum[src_gid]
        var src_comp = src.comp[src_gid]
        var total_comp = dst_comp + src_comp
        var y = src_sum - total_comp
        var t = dst_sum + y
        self.comp[dst_gid] = (t - dst_sum) - y
        self.sum[dst_gid] = t

    # PERF-CRITICAL: aligned-gid full-column merge (Phase 0d).
    # =========================================================================
    # Stays SCALAR per Phase 0d contract: Kahan cross-worker merge formula is
    # a tight 7-flop dependency chain per gid (see accumulator.rs:198-211); a
    # SIMD Neumaier rewrite could close roughly 2-3x but would NOT be bit-
    # identical with the scalar v0.3 reference output (FP non-associativity).
    # The task explicitly requires bit-identical output vs Phase 0c for floats
    # within ULP; scalar Kahan is the safest option. A Neumaier SIMD variant
    # can land as an opt-in follow-up once we have a cross-worker f64 bench.
    #
    # Loop-level scalar speedups (LLVM unrolls) still apply; just no SIMD.
    # =========================================================================
    def merge_aligned(mut self, imm src: Self) raises:
        var n = len(src.sum)
        if len(self.sum) != n or len(self.comp) != n or len(src.comp) != n:
            raise Error(
                "SumF64KahanAcc.merge_aligned: length mismatch (self=" +
                String(len(self.sum)) + ", src=" + String(n) + ")"
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

    def finalize(self) -> List[Float64]:
        # Phase 0a: returns sum only (discards compensation, matches v0.3's
        # Finalize which does NOT fold the comp term — comp is only used
        # during accumulation and merge).
        var out = List[Float64]()
        for i in range(len(self.sum)):
            out.append(self.sum[i])
        return out^

    def num_groups(self) -> Int:
        return len(self.sum)

    # --- Accumulator trait conformance (Phase Acc-trait) ----------------------

    def update_batch[og: Origin, oc: Origin](
        mut self,
        gids: Span[Int, og],
        col_data: Span[UInt8, oc],
        col_offset: Int,
        n: Int,
    ) raises:
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
                raise Error("SumF64KahanAcc.update_batch: gid out of range")
            var v = (data_ptr + off + i)[]
            var s = self.sum[g]
            var c = self.comp[g]
            var y = v - c
            var t = s + y
            self.comp[g] = (t - s) - y
            self.sum[g] = t

    def finalize_to_column(mut self) raises -> Column[HeapRegion]:
        var arr = PrimitiveArray[DType.float64].allocate(len(self.sum))
        for i in range(len(self.sum)):
            arr.set(i, self.sum[i])
        return Column.from_primitive[DType.float64](arr)

    def flush_partial_to_column(mut self) raises -> Column[HeapRegion]:
        return self.finalize_to_column()


# =============================================================================
# === PE Review ==
# =============================================================================
# Verdict: APPROVE for Phase 0a landing (declarations + correctness scaffold).
# Kahan merge formula verbatim-matches accumulator.rs:198-211. Hoare partition
# + upper-slice linear-min scan is correct (NOT values[k+1]). NaN self-inequality
# trick is sound. Sentinel+seen null tracking is clean.
#
# Concerns (defer to Phase 0c, NOT blockers for 0a):
#
# 1. SCALAR SCATTER LOOPS WILL NOT AUTOVEC (autovec_findings:
#    reductions/branchy-sums do NOT auto-vec in Mojo; 4.7-9.2x gap).
#    update_batch on Sum/Count/Min/Max is scalar-per-row. Phase 0c MUST rewrite
#    with explicit `SIMD[DType.int64, N]` gather/scatter via `@parameter` for
#    N=8/16 and a tail scalar epilogue — otherwise B-5 SUM will not clear
#    v0.3 parity. The TODO comments acknowledge this; just tracking.
#
# 2. `ensure_capacity` `while append` loop is O(growth) scalar — when
#    num_groups jumps by 64K it's 64K bounds-checked appends. v0.3's
#    ArenaGroupStore uses bulk `resize`. Phase 0b should switch to
#    `List.resize(n, default)` once a Mojo equivalent is available, or reserve
#    + memset via UnsafePointer. Not a hot path at Phase 0a.
#
# 3. PercentileAcc.finalize COPIES each per-gid buffer before quickselect
#    (lines 692-694 "don't destroy raw values for idempotence"). This is an
#    unnecessary O(N) alloc+copy per group — v0.3's compute_percentile_f64
#    partitions in place on a &mut slice. Since finalize is a terminal op,
#    drop the copy: `self._select_nth(self.values[gid], k)` in Phase 0c.
#    At 1M values * 100 groups this is ~800MB of avoidable allocation.
#
# Kahan: correct. Hoare+upper-min: correct. CountDistinct insertion sort
# acceptable for 0a (explicit follow-up, PERF-CRITICAL note already flags the
# >10k regression case). @parameter specialization opportunity: Sum/Count/Min/
# Max all share the scatter shape — in Phase 0c consider a single
# `@parameter fn scatter_reduce[op: Reducer, T: DType]` to avoid 4x code dup
# and give the compiler one SIMD template to specialize.
# =============================================================================

# === PE Review Phase 0d ==
# VERDICT: APPROVE WITH CONCERNS. SIMD kernels are correctly shaped and
# bit-identical regression tests carry the contract. Land with follow-ups
# tracked.
#
# Kernel shape check (per mojo_autovec_patterns.md exp1/exp2):
#   - dst_ptr.load[width=W] + arith + dst_ptr.store[width=W] in tight while
#     loop with scalar tail = canonical NEON-compatible pattern. Matches
#     parquet/stats.mojo:203-218 reference. `alias W = simd_width_of[..]()`
#     resolves at AOT (2 lanes on M-series, 4/8 on x86 AVX2/AVX-512). Good.
#   - Min/Max use _simd_min_i64/_max_i64 = `a.lt(b).select(a,b)` — exactly
#     the branchless select the exp2 9.2x finding said we needed.
#
# CONCERNS (top 3):
#
# 1. DISPATCH GAP — `AccumulatorEnum.merge` only routes 4 tags
#    (Sum/Count/MinUtf8/MaxUtf8). `MinI64Acc.merge_aligned` and
#    `MaxI64Acc.merge_aligned` are tested but UNREACHABLE through the enum
#    surface today (no ACC_MIN_INT64 / ACC_MAX_INT64 tags in acc_enum.mojo).
#    Either (a) add the missing variants to AccumulatorEnum so the kernels
#    are exercisable from the agg pipeline, or (b) drop the kernels until
#    the variants land. As-is they're dead code masquerading as a fast path
#    — the exact failure mode `feedback_perf_critical_comments.md` warns
#    about.
#
# 2. SENTINEL CORRECTNESS — Min/Max sentinel (_INT64_MAX/_MIN) + scalar
#    `seen` OR-fold IS correct for the unseen-src no-op. BUT: if a user-
#    supplied value equals the sentinel itself (legitimate INT64_MAX in a
#    column), seen=True and value=_INT64_MAX are indistinguishable from the
#    sentinel state. Min merge against a real INT64_MAX is still a no-op
#    (correct), but downstream finalize wraps in Optional via the seen bit,
#    so the result stays correct. Worth a regression test with INT64_MIN /
#    MAX literal inputs to lock this in. The seen-fold scalar loop is fine
#    at num_groups scale.
#
# 3. KAHAN SCALAR IS THE RIGHT CALL TODAY. Bit-identity vs v0.3 outranks the
#    estimated 2-3x SIMD Neumaier win, and merge_aligned is cold relative to
#    update_batch on the agg hot path. Phase 0e Neumaier remains feasible:
#    `((dst_sum+y)-dst_sum)-y` is data-parallel across gids with no
#    cross-lane dependency, so a width-W rewrite is straightforward IF we
#    accept ULP-level drift OR add a runtime feature flag toggling
#    bit-identical vs fast-Neumaier modes. Recommend: keep scalar until a
#    cross-worker f64 microbenchmark proves merge_aligned matters.
#
# Deferral note (merge_from / merge_from_partition / merge_from_flush still
# per-slot probe): ACCEPTABLE — agreed scope. Phase 1+ (FlatHashAggregator
# SoA flip per audit SHAPE #1) is the right place to rebuild those into
# (dst,src) pair-batched dispatches that can call these same kernels. The
# kernels lining up first means the restructure has a known target shape.
# Track in backlog so it isn't lost.
#
# FILE-SIZE NIT: RESOLVED. Split into
# `columnar_acc_typed.mojo`  (numeric: Sum/Count/Min/Max int64 + Kahan f64)
# `columnar_acc_utf8.mojo`   (MinUtf8 / MaxUtf8)
# `columnar_acc_agg.mojo`    (PercentileAcc / CountDistinctAcc)
# All three files now well under the 1000-line ceiling.
# === END PE Review Phase 0d ===
