# =============================================================================
# AccumulatorFactory — per-type vtable wiring + AccumulatorSet construction
# =============================================================================
#
# Phase 4: this file bridges the DynAccumulator vtable with the concrete
# accumulator types (SumI64Acc, CountI64Acc, MinI64Acc, MaxI64Acc, MinUtf8Acc,
# MaxUtf8Acc, PercentileAcc, CountDistinctAcc, SumF64KahanAcc).
#
# Why a separate file: dyn_accumulator.mojo defines the vtable struct and
# generic thunks. The concrete accumulator types live in columnar_acc_typed/
# utf8/agg.mojo and import accumulator_trait.mojo. This file imports BOTH
# sides to wire per-type thunks (per-gid finalize, merge_at, merge_aligned)
# without creating circular imports.
#
# The public surface is:
#   - make_acc_set(acc_tags: List[UInt8]) -> AccumulatorSet
#     Constructs an AccumulatorSet from a list of ACC_* tags, with all vtable
#     slots (including per-gid finalize + merge) fully wired.
#   - make_single_dyn_acc(tag: UInt8) -> DynAccumulator
#     Constructs a single DynAccumulator with full vtable wiring.
#
# All gid arguments use Int per the ADR (not UInt32). Callers widen at the
# call boundary.
# =============================================================================

from komira_core.arrow import Column

from .accumulator_set import AccumulatorSet
from .dyn_accumulator import (
    AccumulatorVTable,
    DynAccumulator,
    _cast_acc,
    _thunk_finalize,
    _thunk_flush_partial,
    _thunk_ensure_cap,
    _thunk_num_groups,
    _thunk_finalize_int64_default,
    _thunk_finalize_utf8_default,
    _thunk_finalize_f64_default,
    _thunk_finalize_f64_opt_default,
    _thunk_merge_at_default,
    _thunk_merge_aligned_default,
)
from .accumulator_set import _kernel_thunk
from .columnar_acc_typed import (
    SumI64Acc,
    CountI64Acc,
    MinI64Acc,
    MaxI64Acc,
    SumF64KahanAcc,
)
from .columnar_acc_typed_extra import (
    CountStarAcc,
    MinF64Acc,
    MaxF64Acc,
    AvgAcc,
)
from .columnar_acc_utf8 import MinUtf8Acc, MaxUtf8Acc
from .columnar_acc_agg import PercentileAcc, CountDistinctAcc
from .columnar_agg_accumulator import (
    ACC_MIN_UTF8,
    ACC_MAX_UTF8,
    ACC_SUM_INT64,
    ACC_COUNT_INT64,
    ACC_MIN_INT64,
    ACC_MAX_INT64,
    ACC_PERCENTILE_F64,
    ACC_SUM_F64,
    ACC_COUNT_STAR,
    ACC_MIN_F64,
    ACC_MAX_F64,
    ACC_AVG,
)


# =============================================================================
# Per-type finalize thunks (Phase 4)
# =============================================================================
# Each thunk is monomorphized per concrete accumulator type. Returns the
# per-gid value by direct field access on the concrete struct. Sentinel for
# out-of-range gids matches AccumulatorEnum behaviour (0 / None / 0.0).

# --- SumI64Acc ---
def _fin_int64_sum(raw_ptr: Int, gid: Int) -> Int64:
    # SAFETY: see _cast_acc — raw_ptr is DynValue storage holding SumI64Acc.
    var ptr = _cast_acc[SumI64Acc](raw_ptr)
    ref s = ptr[].state
    if gid >= len(s):
        return Int64(0)
    return s[gid]


# --- CountI64Acc ---
def _fin_int64_count(raw_ptr: Int, gid: Int) -> Int64:
    # SAFETY: see _cast_acc — raw_ptr is DynValue storage holding CountI64Acc.
    var ptr = _cast_acc[CountI64Acc](raw_ptr)
    ref s = ptr[].state
    if gid >= len(s):
        return Int64(0)
    return s[gid]


# --- MinI64Acc ---
def _fin_int64_min(raw_ptr: Int, gid: Int) -> Int64:
    # SAFETY: see _cast_acc — raw_ptr is DynValue storage holding MinI64Acc.
    var ptr = _cast_acc[MinI64Acc](raw_ptr)
    ref s = ptr[].state
    ref se = ptr[].seen
    if gid >= len(s) or not se[gid]:
        return Int64(0)
    return s[gid]


# --- MaxI64Acc ---
def _fin_int64_max(raw_ptr: Int, gid: Int) -> Int64:
    # SAFETY: see _cast_acc — raw_ptr is DynValue storage holding MaxI64Acc.
    var ptr = _cast_acc[MaxI64Acc](raw_ptr)
    ref s = ptr[].state
    ref se = ptr[].seen
    if gid >= len(s) or not se[gid]:
        return Int64(0)
    return s[gid]


# --- MinUtf8Acc ---
def _fin_utf8_min(raw_ptr: Int, gid: Int) -> Optional[String]:
    # SAFETY: see _cast_acc — raw_ptr is DynValue storage holding MinUtf8Acc.
    var ptr = _cast_acc[MinUtf8Acc](raw_ptr)
    ref s = ptr[].state
    if gid >= len(s):
        return Optional[String](None)
    return s[gid]


# --- MaxUtf8Acc ---
def _fin_utf8_max(raw_ptr: Int, gid: Int) -> Optional[String]:
    # SAFETY: see _cast_acc — raw_ptr is DynValue storage holding MaxUtf8Acc.
    var ptr = _cast_acc[MaxUtf8Acc](raw_ptr)
    ref s = ptr[].state
    if gid >= len(s):
        return Optional[String](None)
    return s[gid]


# --- PercentileAcc ---
def _fin_f64_percentile(raw_ptr: Int, gid: Int) -> Float64:
    # SAFETY: see _cast_acc — raw_ptr is DynValue storage holding PercentileAcc.
    var ptr = _cast_acc[PercentileAcc](raw_ptr)
    var opt = ptr[]._finalize_one(gid)
    if opt:
        return opt.value()
    return Float64(0.0)


def _fin_f64_opt_percentile(raw_ptr: Int, gid: Int) -> Optional[Float64]:
    """Nullable readback for percentile: returns None for unseen/empty groups."""
    # SAFETY: see _cast_acc — raw_ptr is DynValue storage holding PercentileAcc.
    var ptr = _cast_acc[PercentileAcc](raw_ptr)
    return ptr[]._finalize_one(gid)


# --- SumF64KahanAcc ---
def _fin_f64_kahan(raw_ptr: Int, gid: Int) -> Float64:
    # SAFETY: see _cast_acc — raw_ptr is DynValue storage holding SumF64KahanAcc.
    var ptr = _cast_acc[SumF64KahanAcc](raw_ptr)
    ref s = ptr[].sum
    if gid >= len(s):
        return Float64(0.0)
    return s[gid]


# --- CountStarAcc ---
def _fin_int64_count_star(raw_ptr: Int, gid: Int) -> Int64:
    # SAFETY: see _cast_acc — raw_ptr is DynValue storage holding CountStarAcc.
    var ptr = _cast_acc[CountStarAcc](raw_ptr)
    ref s = ptr[].state
    if gid >= len(s):
        return Int64(0)
    return s[gid]


# --- MinF64Acc ---
def _fin_f64_min(raw_ptr: Int, gid: Int) -> Float64:
    # SAFETY: see _cast_acc — raw_ptr is DynValue storage holding MinF64Acc.
    var ptr = _cast_acc[MinF64Acc](raw_ptr)
    ref s = ptr[].state
    ref se = ptr[].seen
    if gid >= len(s) or not se[gid]:
        return Float64(0.0)
    return s[gid]


def _fin_f64_opt_min(raw_ptr: Int, gid: Int) -> Optional[Float64]:
    """Nullable readback for MIN(f64): None for unseen groups."""
    # SAFETY: see _cast_acc — raw_ptr is DynValue storage holding MinF64Acc.
    var ptr = _cast_acc[MinF64Acc](raw_ptr)
    ref s = ptr[].state
    ref se = ptr[].seen
    if gid >= len(s) or not se[gid]:
        return Optional[Float64](None)
    return Optional[Float64](s[gid])


# --- MaxF64Acc ---
def _fin_f64_max(raw_ptr: Int, gid: Int) -> Float64:
    # SAFETY: see _cast_acc — raw_ptr is DynValue storage holding MaxF64Acc.
    var ptr = _cast_acc[MaxF64Acc](raw_ptr)
    ref s = ptr[].state
    ref se = ptr[].seen
    if gid >= len(s) or not se[gid]:
        return Float64(0.0)
    return s[gid]


def _fin_f64_opt_max(raw_ptr: Int, gid: Int) -> Optional[Float64]:
    """Nullable readback for MAX(f64): None for unseen groups."""
    # SAFETY: see _cast_acc — raw_ptr is DynValue storage holding MaxF64Acc.
    var ptr = _cast_acc[MaxF64Acc](raw_ptr)
    ref s = ptr[].state
    ref se = ptr[].seen
    if gid >= len(s) or not se[gid]:
        return Optional[Float64](None)
    return Optional[Float64](s[gid])


# --- AvgAcc ---
def _fin_f64_avg(raw_ptr: Int, gid: Int) -> Float64:
    """AVG = sum / count. Sentinel 0.0 for unseen (count==0) groups."""
    # SAFETY: see _cast_acc — raw_ptr is DynValue storage holding AvgAcc.
    var ptr = _cast_acc[AvgAcc](raw_ptr)
    ref s = ptr[].sum
    ref c = ptr[].count
    if gid >= len(s):
        return Float64(0.0)
    var cv = c[gid]
    if cv <= Int64(0):
        return Float64(0.0)
    return s[gid] / Float64(cv)


def _fin_f64_opt_avg(raw_ptr: Int, gid: Int) -> Optional[Float64]:
    """Nullable readback for AVG: None for empty groups."""
    # SAFETY: see _cast_acc — raw_ptr is DynValue storage holding AvgAcc.
    var ptr = _cast_acc[AvgAcc](raw_ptr)
    ref s = ptr[].sum
    ref c = ptr[].count
    if gid >= len(s):
        return Optional[Float64](None)
    var cv = c[gid]
    if cv <= Int64(0):
        return Optional[Float64](None)
    return Optional[Float64](s[gid] / Float64(cv))


# --- CountDistinctAcc ---
# COUNT(DISTINCT) finalize returns the deduped count as Int64 for a single gid.
def _fin_int64_count_distinct(raw_ptr: Int, gid: Int) -> Int64:
    # SAFETY: see _cast_acc — raw_ptr is DynValue storage holding CountDistinctAcc.
    var ptr = _cast_acc[CountDistinctAcc](raw_ptr)
    ref bufs = ptr[].buffers
    if gid >= len(bufs):
        return Int64(0)
    # Dedup count without mutating the original buffer (copy + sort + count).
    ref src = bufs[gid]
    var n = len(src)
    if n == 0:
        return Int64(0)
    var copy = List[Int64]()
    for i in range(n):
        copy.append(src[i])
    # Insertion sort (same as CountDistinctAcc._sort_inplace).
    for i in range(1, len(copy)):
        var key = copy[i]
        var j = i - 1
        while j >= 0 and copy[j] > key:
            copy[j + 1] = copy[j]
            j = j - 1
        copy[j + 1] = key
    var distinct = Int64(1)
    for i in range(1, len(copy)):
        if copy[i] != copy[i - 1]:
            distinct = distinct + Int64(1)
    return distinct


# =============================================================================
# Per-type merge_at thunks (Phase 4)
# =============================================================================
# Each thunk casts both raw pointers to the same concrete type and calls
# the type's merge_at(dst_gid, src, src_gid). The plan compiler guarantees
# type alignment across worker accumulators.

def _merge_at_sum_i64(
    self_ptr: Int, dst_gid: Int, other_ptr: Int, src_gid: Int,
) raises -> None:
    # SAFETY: see _cast_acc — both ptrs are DynValue storage holding SumI64Acc.
    var s = _cast_acc[SumI64Acc](self_ptr)
    var o = _cast_acc[SumI64Acc](other_ptr)
    s[].merge_at(dst_gid, o[], src_gid)


def _merge_at_count_i64(
    self_ptr: Int, dst_gid: Int, other_ptr: Int, src_gid: Int,
) raises -> None:
    # SAFETY: see _cast_acc — both ptrs are DynValue storage holding CountI64Acc.
    var s = _cast_acc[CountI64Acc](self_ptr)
    var o = _cast_acc[CountI64Acc](other_ptr)
    s[].merge_at(dst_gid, o[], src_gid)


def _merge_at_min_i64(
    self_ptr: Int, dst_gid: Int, other_ptr: Int, src_gid: Int,
) raises -> None:
    # SAFETY: see _cast_acc — both ptrs are DynValue storage holding MinI64Acc.
    var s = _cast_acc[MinI64Acc](self_ptr)
    var o = _cast_acc[MinI64Acc](other_ptr)
    s[].merge_at(dst_gid, o[], src_gid)


def _merge_at_max_i64(
    self_ptr: Int, dst_gid: Int, other_ptr: Int, src_gid: Int,
) raises -> None:
    # SAFETY: see _cast_acc — both ptrs are DynValue storage holding MaxI64Acc.
    var s = _cast_acc[MaxI64Acc](self_ptr)
    var o = _cast_acc[MaxI64Acc](other_ptr)
    s[].merge_at(dst_gid, o[], src_gid)


def _merge_at_min_utf8(
    self_ptr: Int, dst_gid: Int, other_ptr: Int, src_gid: Int,
) raises -> None:
    # SAFETY: see _cast_acc — both ptrs are DynValue storage holding MinUtf8Acc.
    var s = _cast_acc[MinUtf8Acc](self_ptr)
    var o = _cast_acc[MinUtf8Acc](other_ptr)
    s[].merge_at(dst_gid, o[], src_gid)


def _merge_at_max_utf8(
    self_ptr: Int, dst_gid: Int, other_ptr: Int, src_gid: Int,
) raises -> None:
    # SAFETY: see _cast_acc — both ptrs are DynValue storage holding MaxUtf8Acc.
    var s = _cast_acc[MaxUtf8Acc](self_ptr)
    var o = _cast_acc[MaxUtf8Acc](other_ptr)
    s[].merge_at(dst_gid, o[], src_gid)


def _merge_at_percentile(
    self_ptr: Int, dst_gid: Int, other_ptr: Int, src_gid: Int,
) raises -> None:
    # SAFETY: see _cast_acc — both ptrs are DynValue storage holding PercentileAcc.
    var s = _cast_acc[PercentileAcc](self_ptr)
    var o = _cast_acc[PercentileAcc](other_ptr)
    s[].merge_at(dst_gid, o[], src_gid)


def _merge_at_count_distinct(
    self_ptr: Int, dst_gid: Int, other_ptr: Int, src_gid: Int,
) raises -> None:
    # SAFETY: see _cast_acc — both ptrs are DynValue storage holding CountDistinctAcc.
    var s = _cast_acc[CountDistinctAcc](self_ptr)
    var o = _cast_acc[CountDistinctAcc](other_ptr)
    s[].merge_at(dst_gid, o[], src_gid)


def _merge_at_kahan(
    self_ptr: Int, dst_gid: Int, other_ptr: Int, src_gid: Int,
) raises -> None:
    # SAFETY: see _cast_acc — both ptrs are DynValue storage holding SumF64KahanAcc.
    var s = _cast_acc[SumF64KahanAcc](self_ptr)
    var o = _cast_acc[SumF64KahanAcc](other_ptr)
    s[].merge_at(dst_gid, o[], src_gid)


def _merge_at_count_star(
    self_ptr: Int, dst_gid: Int, other_ptr: Int, src_gid: Int,
) raises -> None:
    # SAFETY: see _cast_acc — both ptrs are DynValue storage holding CountStarAcc.
    var s = _cast_acc[CountStarAcc](self_ptr)
    var o = _cast_acc[CountStarAcc](other_ptr)
    s[].merge_at(dst_gid, o[], src_gid)


def _merge_at_min_f64(
    self_ptr: Int, dst_gid: Int, other_ptr: Int, src_gid: Int,
) raises -> None:
    # SAFETY: see _cast_acc — both ptrs are DynValue storage holding MinF64Acc.
    var s = _cast_acc[MinF64Acc](self_ptr)
    var o = _cast_acc[MinF64Acc](other_ptr)
    s[].merge_at(dst_gid, o[], src_gid)


def _merge_at_max_f64(
    self_ptr: Int, dst_gid: Int, other_ptr: Int, src_gid: Int,
) raises -> None:
    # SAFETY: see _cast_acc — both ptrs are DynValue storage holding MaxF64Acc.
    var s = _cast_acc[MaxF64Acc](self_ptr)
    var o = _cast_acc[MaxF64Acc](other_ptr)
    s[].merge_at(dst_gid, o[], src_gid)


def _merge_at_avg(
    self_ptr: Int, dst_gid: Int, other_ptr: Int, src_gid: Int,
) raises -> None:
    # SAFETY: see _cast_acc — both ptrs are DynValue storage holding AvgAcc.
    var s = _cast_acc[AvgAcc](self_ptr)
    var o = _cast_acc[AvgAcc](other_ptr)
    s[].merge_at(dst_gid, o[], src_gid)


# =============================================================================
# Per-type merge_aligned thunks (Phase 4)
# =============================================================================

def _merge_aligned_sum_i64(self_ptr: Int, other_ptr: Int) raises -> None:
    # SAFETY: see _cast_acc — both ptrs are DynValue storage holding SumI64Acc.
    var s = _cast_acc[SumI64Acc](self_ptr)
    var o = _cast_acc[SumI64Acc](other_ptr)
    s[].merge_aligned(o[])


def _merge_aligned_count_i64(self_ptr: Int, other_ptr: Int) raises -> None:
    # SAFETY: see _cast_acc — both ptrs are DynValue storage holding CountI64Acc.
    var s = _cast_acc[CountI64Acc](self_ptr)
    var o = _cast_acc[CountI64Acc](other_ptr)
    s[].merge_aligned(o[])


def _merge_aligned_min_i64(self_ptr: Int, other_ptr: Int) raises -> None:
    # SAFETY: see _cast_acc — both ptrs are DynValue storage holding MinI64Acc.
    var s = _cast_acc[MinI64Acc](self_ptr)
    var o = _cast_acc[MinI64Acc](other_ptr)
    s[].merge_aligned(o[])


def _merge_aligned_max_i64(self_ptr: Int, other_ptr: Int) raises -> None:
    # SAFETY: see _cast_acc — both ptrs are DynValue storage holding MaxI64Acc.
    var s = _cast_acc[MaxI64Acc](self_ptr)
    var o = _cast_acc[MaxI64Acc](other_ptr)
    s[].merge_aligned(o[])


def _merge_aligned_min_utf8(self_ptr: Int, other_ptr: Int) raises -> None:
    # SAFETY: see _cast_acc — both ptrs are DynValue storage holding MinUtf8Acc.
    var s = _cast_acc[MinUtf8Acc](self_ptr)
    var o = _cast_acc[MinUtf8Acc](other_ptr)
    s[].merge_aligned(o[])


def _merge_aligned_max_utf8(self_ptr: Int, other_ptr: Int) raises -> None:
    # SAFETY: see _cast_acc — both ptrs are DynValue storage holding MaxUtf8Acc.
    var s = _cast_acc[MaxUtf8Acc](self_ptr)
    var o = _cast_acc[MaxUtf8Acc](other_ptr)
    s[].merge_aligned(o[])


# PercentileAcc has NO merge_aligned — its merge is an append (concat per-gid
# Float64 buffers), inherently serial. Falls back to per-gid merge_at.
def _merge_aligned_percentile(self_ptr: Int, other_ptr: Int) raises -> None:
    # SAFETY: see _cast_acc — both ptrs are DynValue storage holding PercentileAcc.
    # Fall back to per-gid loop.
    var s = _cast_acc[PercentileAcc](self_ptr)
    var o = _cast_acc[PercentileAcc](other_ptr)
    var n = o[].num_groups()
    for i in range(n):
        s[].merge_at(i, o[], i)


# CountDistinctAcc has no SIMD merge — extend buffers.
def _merge_aligned_count_distinct(self_ptr: Int, other_ptr: Int) raises -> None:
    # SAFETY: see _cast_acc — both ptrs are DynValue storage holding CountDistinctAcc.
    var s = _cast_acc[CountDistinctAcc](self_ptr)
    var o = _cast_acc[CountDistinctAcc](other_ptr)
    var n = o[].num_groups()
    for i in range(n):
        s[].merge_at(i, o[], i)


# SumF64KahanAcc uses scalar merge for bit-identity with v0.3.
def _merge_aligned_kahan(self_ptr: Int, other_ptr: Int) raises -> None:
    # SAFETY: see _cast_acc — both ptrs are DynValue storage holding SumF64KahanAcc.
    var s = _cast_acc[SumF64KahanAcc](self_ptr)
    var o = _cast_acc[SumF64KahanAcc](other_ptr)
    s[].merge_aligned(o[])


def _merge_aligned_count_star(self_ptr: Int, other_ptr: Int) raises -> None:
    # SAFETY: see _cast_acc — both ptrs are DynValue storage holding CountStarAcc.
    var s = _cast_acc[CountStarAcc](self_ptr)
    var o = _cast_acc[CountStarAcc](other_ptr)
    s[].merge_aligned(o[])


def _merge_aligned_min_f64(self_ptr: Int, other_ptr: Int) raises -> None:
    # SAFETY: see _cast_acc — both ptrs are DynValue storage holding MinF64Acc.
    var s = _cast_acc[MinF64Acc](self_ptr)
    var o = _cast_acc[MinF64Acc](other_ptr)
    s[].merge_aligned(o[])


def _merge_aligned_max_f64(self_ptr: Int, other_ptr: Int) raises -> None:
    # SAFETY: see _cast_acc — both ptrs are DynValue storage holding MaxF64Acc.
    var s = _cast_acc[MaxF64Acc](self_ptr)
    var o = _cast_acc[MaxF64Acc](other_ptr)
    s[].merge_aligned(o[])


def _merge_aligned_avg(self_ptr: Int, other_ptr: Int) raises -> None:
    # SAFETY: see _cast_acc — both ptrs are DynValue storage holding AvgAcc.
    var s = _cast_acc[AvgAcc](self_ptr)
    var o = _cast_acc[AvgAcc](other_ptr)
    s[].merge_aligned(o[])


# =============================================================================
# Vtable factories — one per concrete accumulator type
# =============================================================================

def _vtable_sum_i64() -> AccumulatorVTable:
    return AccumulatorVTable(
        finalize=_thunk_finalize[SumI64Acc],
        flush_partial=_thunk_flush_partial[SumI64Acc],
        merge_at=_merge_at_sum_i64,
        merge_aligned=_merge_aligned_sum_i64,
        ensure_cap=_thunk_ensure_cap[SumI64Acc],
        num_groups=_thunk_num_groups[SumI64Acc],
        finalize_int64=_fin_int64_sum,
        finalize_utf8=_thunk_finalize_utf8_default,
        finalize_f64=_thunk_finalize_f64_default,
        finalize_f64_opt=_thunk_finalize_f64_opt_default,
    )

def _vtable_count_i64() -> AccumulatorVTable:
    return AccumulatorVTable(
        finalize=_thunk_finalize[CountI64Acc],
        flush_partial=_thunk_flush_partial[CountI64Acc],
        merge_at=_merge_at_count_i64,
        merge_aligned=_merge_aligned_count_i64,
        ensure_cap=_thunk_ensure_cap[CountI64Acc],
        num_groups=_thunk_num_groups[CountI64Acc],
        finalize_int64=_fin_int64_count,
        finalize_utf8=_thunk_finalize_utf8_default,
        finalize_f64=_thunk_finalize_f64_default,
        finalize_f64_opt=_thunk_finalize_f64_opt_default,
    )

def _vtable_min_i64() -> AccumulatorVTable:
    return AccumulatorVTable(
        finalize=_thunk_finalize[MinI64Acc],
        flush_partial=_thunk_flush_partial[MinI64Acc],
        merge_at=_merge_at_min_i64,
        merge_aligned=_merge_aligned_min_i64,
        ensure_cap=_thunk_ensure_cap[MinI64Acc],
        num_groups=_thunk_num_groups[MinI64Acc],
        finalize_int64=_fin_int64_min,
        finalize_utf8=_thunk_finalize_utf8_default,
        finalize_f64=_thunk_finalize_f64_default,
        finalize_f64_opt=_thunk_finalize_f64_opt_default,
    )

def _vtable_max_i64() -> AccumulatorVTable:
    return AccumulatorVTable(
        finalize=_thunk_finalize[MaxI64Acc],
        flush_partial=_thunk_flush_partial[MaxI64Acc],
        merge_at=_merge_at_max_i64,
        merge_aligned=_merge_aligned_max_i64,
        ensure_cap=_thunk_ensure_cap[MaxI64Acc],
        num_groups=_thunk_num_groups[MaxI64Acc],
        finalize_int64=_fin_int64_max,
        finalize_utf8=_thunk_finalize_utf8_default,
        finalize_f64=_thunk_finalize_f64_default,
        finalize_f64_opt=_thunk_finalize_f64_opt_default,
    )

def _vtable_min_utf8() -> AccumulatorVTable:
    return AccumulatorVTable(
        finalize=_thunk_finalize[MinUtf8Acc],
        flush_partial=_thunk_flush_partial[MinUtf8Acc],
        merge_at=_merge_at_min_utf8,
        merge_aligned=_merge_aligned_min_utf8,
        ensure_cap=_thunk_ensure_cap[MinUtf8Acc],
        num_groups=_thunk_num_groups[MinUtf8Acc],
        finalize_int64=_thunk_finalize_int64_default,
        finalize_utf8=_fin_utf8_min,
        finalize_f64=_thunk_finalize_f64_default,
        finalize_f64_opt=_thunk_finalize_f64_opt_default,
    )

def _vtable_max_utf8() -> AccumulatorVTable:
    return AccumulatorVTable(
        finalize=_thunk_finalize[MaxUtf8Acc],
        flush_partial=_thunk_flush_partial[MaxUtf8Acc],
        merge_at=_merge_at_max_utf8,
        merge_aligned=_merge_aligned_max_utf8,
        ensure_cap=_thunk_ensure_cap[MaxUtf8Acc],
        num_groups=_thunk_num_groups[MaxUtf8Acc],
        finalize_int64=_thunk_finalize_int64_default,
        finalize_utf8=_fin_utf8_max,
        finalize_f64=_thunk_finalize_f64_default,
        finalize_f64_opt=_thunk_finalize_f64_opt_default,
    )

def _vtable_percentile() -> AccumulatorVTable:
    return AccumulatorVTable(
        finalize=_thunk_finalize[PercentileAcc],
        flush_partial=_thunk_flush_partial[PercentileAcc],
        merge_at=_merge_at_percentile,
        merge_aligned=_merge_aligned_percentile,
        ensure_cap=_thunk_ensure_cap[PercentileAcc],
        num_groups=_thunk_num_groups[PercentileAcc],
        finalize_int64=_thunk_finalize_int64_default,
        finalize_utf8=_thunk_finalize_utf8_default,
        finalize_f64=_fin_f64_percentile,
        finalize_f64_opt=_fin_f64_opt_percentile,
    )


# --- Stage 2B factories: 5 new variants ---

def _vtable_sum_f64() -> AccumulatorVTable:
    return AccumulatorVTable(
        finalize=_thunk_finalize[SumF64KahanAcc],
        flush_partial=_thunk_flush_partial[SumF64KahanAcc],
        merge_at=_merge_at_kahan,
        merge_aligned=_merge_aligned_kahan,
        ensure_cap=_thunk_ensure_cap[SumF64KahanAcc],
        num_groups=_thunk_num_groups[SumF64KahanAcc],
        finalize_int64=_thunk_finalize_int64_default,
        finalize_utf8=_thunk_finalize_utf8_default,
        finalize_f64=_fin_f64_kahan,
        finalize_f64_opt=_thunk_finalize_f64_opt_default,
    )


def _vtable_count_star() -> AccumulatorVTable:
    return AccumulatorVTable(
        finalize=_thunk_finalize[CountStarAcc],
        flush_partial=_thunk_flush_partial[CountStarAcc],
        merge_at=_merge_at_count_star,
        merge_aligned=_merge_aligned_count_star,
        ensure_cap=_thunk_ensure_cap[CountStarAcc],
        num_groups=_thunk_num_groups[CountStarAcc],
        finalize_int64=_fin_int64_count_star,
        finalize_utf8=_thunk_finalize_utf8_default,
        finalize_f64=_thunk_finalize_f64_default,
        finalize_f64_opt=_thunk_finalize_f64_opt_default,
    )


def _vtable_min_f64() -> AccumulatorVTable:
    return AccumulatorVTable(
        finalize=_thunk_finalize[MinF64Acc],
        flush_partial=_thunk_flush_partial[MinF64Acc],
        merge_at=_merge_at_min_f64,
        merge_aligned=_merge_aligned_min_f64,
        ensure_cap=_thunk_ensure_cap[MinF64Acc],
        num_groups=_thunk_num_groups[MinF64Acc],
        finalize_int64=_thunk_finalize_int64_default,
        finalize_utf8=_thunk_finalize_utf8_default,
        finalize_f64=_fin_f64_min,
        finalize_f64_opt=_fin_f64_opt_min,
    )


def _vtable_max_f64() -> AccumulatorVTable:
    return AccumulatorVTable(
        finalize=_thunk_finalize[MaxF64Acc],
        flush_partial=_thunk_flush_partial[MaxF64Acc],
        merge_at=_merge_at_max_f64,
        merge_aligned=_merge_aligned_max_f64,
        ensure_cap=_thunk_ensure_cap[MaxF64Acc],
        num_groups=_thunk_num_groups[MaxF64Acc],
        finalize_int64=_thunk_finalize_int64_default,
        finalize_utf8=_thunk_finalize_utf8_default,
        finalize_f64=_fin_f64_max,
        finalize_f64_opt=_fin_f64_opt_max,
    )


def _vtable_avg() -> AccumulatorVTable:
    return AccumulatorVTable(
        finalize=_thunk_finalize[AvgAcc],
        flush_partial=_thunk_flush_partial[AvgAcc],
        merge_at=_merge_at_avg,
        merge_aligned=_merge_aligned_avg,
        ensure_cap=_thunk_ensure_cap[AvgAcc],
        num_groups=_thunk_num_groups[AvgAcc],
        finalize_int64=_thunk_finalize_int64_default,
        finalize_utf8=_thunk_finalize_utf8_default,
        finalize_f64=_fin_f64_avg,
        finalize_f64_opt=_fin_f64_opt_avg,
    )


# =============================================================================
# Public factory: make_single_dyn_acc
# =============================================================================

def make_single_dyn_acc(tag: UInt8, quantile: Float64 = 0.5) -> DynAccumulator:
    """Construct a single DynAccumulator with full vtable wiring for `tag`.

    Replaces the AccumulatorEnum.new_* factory surface. The returned
    DynAccumulator has per-gid finalize, merge_at, and merge_aligned
    all wired to the correct concrete type.

    Args:
        tag: ACC_* tag from columnar_agg_accumulator.mojo
        quantile: Only used for ACC_PERCENTILE_F64 (default 0.5 = median).
    """
    if tag == ACC_SUM_INT64:
        return DynAccumulator.create_with_vtable[SumI64Acc](
            SumI64Acc.new(), _vtable_sum_i64(), tag
        )
    elif tag == ACC_COUNT_INT64:
        return DynAccumulator.create_with_vtable[CountI64Acc](
            CountI64Acc.new(), _vtable_count_i64(), tag
        )
    elif tag == ACC_MIN_INT64:
        return DynAccumulator.create_with_vtable[MinI64Acc](
            MinI64Acc.new(), _vtable_min_i64(), tag
        )
    elif tag == ACC_MAX_INT64:
        return DynAccumulator.create_with_vtable[MaxI64Acc](
            MaxI64Acc.new(), _vtable_max_i64(), tag
        )
    elif tag == ACC_MIN_UTF8:
        return DynAccumulator.create_with_vtable[MinUtf8Acc](
            MinUtf8Acc.new(), _vtable_min_utf8(), tag
        )
    elif tag == ACC_MAX_UTF8:
        return DynAccumulator.create_with_vtable[MaxUtf8Acc](
            MaxUtf8Acc.new(), _vtable_max_utf8(), tag
        )
    elif tag == ACC_PERCENTILE_F64:
        return DynAccumulator.create_with_vtable[PercentileAcc](
            PercentileAcc.new(quantile), _vtable_percentile(), tag
        )
    elif tag == ACC_SUM_F64:
        return DynAccumulator.create_with_vtable[SumF64KahanAcc](
            SumF64KahanAcc.new(), _vtable_sum_f64(), tag
        )
    elif tag == ACC_COUNT_STAR:
        return DynAccumulator.create_with_vtable[CountStarAcc](
            CountStarAcc.new(), _vtable_count_star(), tag
        )
    elif tag == ACC_MIN_F64:
        return DynAccumulator.create_with_vtable[MinF64Acc](
            MinF64Acc.new(), _vtable_min_f64(), tag
        )
    elif tag == ACC_MAX_F64:
        return DynAccumulator.create_with_vtable[MaxF64Acc](
            MaxF64Acc.new(), _vtable_max_f64(), tag
        )
    elif tag == ACC_AVG:
        return DynAccumulator.create_with_vtable[AvgAcc](
            AvgAcc.new(), _vtable_avg(), tag
        )
    # Fallback: SumI64 (matches AccumulatorEnum._make_acc behaviour).
    return DynAccumulator.create_with_vtable[SumI64Acc](
        SumI64Acc.new(), _vtable_sum_i64(), ACC_SUM_INT64
    )
