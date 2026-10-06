# =============================================================================
# bloom_mask -- per-batch dynamic-filter mask helpers (Tier 1/2/3 pushdown)
# =============================================================================
#
# v0.3 spec source: komira-engine/src/bloom_filter.rs:429-481 (BloomRowFilter::
# evaluate_single_column, the Int64 / Int32 / Utf8 paths) plus the in-list /
# range eval bodies at bloom_filter.rs:241-273 / 759-782.
#
# Walks a probe-side `PrimitiveArray[INT64]` against build-side filter tiers
# and produces a `BooleanArray` of `might_contain` results, matching v0.3
# null semantics (null -> false).
#
# Three v0.3 tiers consumed here for Int64:
#   - Tier 1: in-list filter (zero false positives, scalar Dict lookup)
#   - Tier 2: range filter (single-comparison, SIMD-vectorized)
#   - Tier 3: bloom filter  (probabilistic, ~1% FPR)
#
# Phase 3.4 ported the Int64 bloom path. q11 REC 3
# adds the Int64 range + in-list paths so the parquet source can consume
# all three tiers (previously only Tier 3 was wired).
# =============================================================================

from komira_core.arrow.boolean_array import BooleanArray
from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.arrow.bitmap import Bitmap
from komira_core.collections.bloom_filter import BloomFilter
from komira_core.collections.in_list_filter import InListFilter
from komira_core.collections.range_filter import RangeFilter

from std.sys import simd_width_of


@always_inline
def bloom_mask_int64(
    keys: PrimitiveArray[DType.int64], bf: BloomFilter
) raises -> BooleanArray:
    """Produce a per-row bloom-membership mask over INT64 keys.

    v0.3 source: bloom_filter.rs:441-450 (Int64 evaluate path), plus the
    null handling at lines 443-449.

    Args:
        keys: Probe-side INT64 column to test.
        bf: Build-side bloom filter (read-only).

    Returns:
        A BooleanArray with the same length as `keys`. `true` at row `i`
        means `keys[i]` MIGHT be in the build's key set; `false` means
        `keys[i]` is DEFINITELY NOT.

    Null handling matches v0.3: every null row produces `false`. Callers
    chain this with their existing AND-mask (eval_and) which already
    treats nulls correctly for INNER / SEMI joins.

    PERF-CRITICAL: tight scalar loop. v0.3 uses `compute_hashes_single_i64`
    + `bf.might_contain(hash)`, but `BloomFilter.might_contain_int64`
    already inlines the hash + check, so the Mojo path is one call per
    row.
    """
    var n = keys.length
    var mask = BooleanArray.allocate(n)
    if n == 0:
        return mask^

    # SAFETY: PrimitiveArray._typed_ptr_ro returns an origin-tracked
    # pointer into the backing MmapAlignedBuffer that lives at least as long
    # as `keys`. The caller's `keys` parameter is a borrowed reference
    # held through the whole function body. No struct boundaries
    # crossed; this is the encapsulation rule's "internal use only"
    # carve-out. Z.B5: migrated from `_unsafe_data_ptr()` (wildcard
    # origin) to `_typed_ptr_ro()` (origin-tracked).
    var data_ptr = keys._typed_ptr_ro()
    var has_nulls = keys.null_count > 0

    if has_nulls:
        # Null-aware path. v0.3 lines 444-449.
        for i in range(n):
            if keys.is_null(i):
                # mask is all-False from allocate(); skip.
                continue
            var v = Int64(data_ptr[i])
            if bf.might_contain_int64(v):
                mask.set(i, True)
    else:
        # No-null fast path. Tight loop, no branch on validity.
        for i in range(n):
            var v = Int64(data_ptr[i])
            if bf.might_contain_int64(v):
                mask.set(i, True)
    return mask^


@always_inline
def range_mask_int64(
    keys: PrimitiveArray[DType.int64], rf: RangeFilter
) raises -> BooleanArray:
    """Produce a per-row range-membership mask over INT64 keys (Tier 2).

    v0.3 source: bloom_filter.rs:759-770 (Int64 RangeRowFilter evaluate
    path). Single comparison cost when SIMD-vectorized (`>= min` AND
    `<= max`).

    Args:
        keys: Probe-side INT64 column to test.
        rf: Build-side range filter (read-only).

    Returns:
        A BooleanArray with the same length as `keys`. `true` at row `i`
        means `min <= keys[i] <= max`; `false` otherwise.

    Null handling matches v0.3: every null row produces `false`. Callers
    chain this with `eval_and` for INNER / SEMI null treatment.

    PERF-CRITICAL: SIMD-vectorized over `simd_width_of[DType.int64]` lanes
    (NEON: W=2; AVX-2: W=4; AVX-512: W=8). Bitmap-packing follows the
    `_eval_cmp_gt` shape in `komira_core/eval/comparison.mojo` — direct
    bit-packed Bitmap construction so the inner loop is purely
    NEON `cmge.2d` / `cmle.2d` plus an `and.16b` per pair of lanes.
    """
    var n = keys.length
    var mask = BooleanArray.allocate(n)
    if n == 0:
        return mask^

    var lo = rf.min_int64()
    var hi = rf.max_int64()
    # Degenerate single-value range: no rows can pass when lo > hi.
    # (Producer ensures lo <= hi for non-empty builds, but guard.)
    if lo > hi:
        return mask^

    # SAFETY: same as bloom_mask_int64 — origin-tracked pointer into the
    # caller's keys buffer; no boundaries crossed.
    var data_ptr = keys._typed_ptr_ro()
    var has_nulls = keys.null_count > 0

    if has_nulls:
        # Null-aware path: scalar to honour the validity bitmap.
        for i in range(n):
            if keys.is_null(i):
                continue
            var v = Int64(data_ptr[i])
            if v >= lo and v <= hi:
                mask.set(i, True)
    else:
        # No-null fast path. SIMD-vectorized.
        comptime W: Int = simd_width_of[DType.int64]()
        var lo_vec = SIMD[DType.int64, W](lo)
        var hi_vec = SIMD[DType.int64, W](hi)

        # Process W lanes at a time. The SIMD ge/le results are
        # `SIMD[bool, W]`; cast to UInt8 to extract per-lane integer
        # values, then write surviving rows into the already-allocated
        # mask via `mask.set` (BooleanArray.allocate initialises the
        # data bitmap to all-False and the validity bitmap to
        # all-valid).
        var full = (n // W) * W
        var i = 0
        while i < full:
            var v = keys.load[W](i)
            var ge = v.ge(lo_vec)
            var le = v.le(hi_vec)
            var both = ge & le
            var b = both.cast[DType.uint8]()
            comptime for lane in range(W):
                if Int(b[lane]) != 0:
                    mask.set(i + lane, True)
            i += W
        # Tail.
        while i < n:
            var v = Int64(data_ptr[i])
            if v >= lo and v <= hi:
                mask.set(i, True)
            i += 1
    return mask^


@always_inline
def in_list_mask_int64(
    keys: PrimitiveArray[DType.int64], il: InListFilter
) raises -> BooleanArray:
    """Produce a per-row in-list-membership mask over INT64 keys (Tier 1).

    v0.3 source: bloom_filter.rs:241-246 (InListFilter::contains_i64).
    InListFilter is capped at IN_LIST_THRESHOLD=128 distinct keys so the
    scalar Dict probe is cheap relative to bloom or range — the hash
    table is small enough to live in L1 throughout the per-batch scan.

    Args:
        keys: Probe-side INT64 column to test.
        il: Build-side in-list filter (read-only). Caller must verify
            non-empty / capped via `il.size() > 0`.

    Returns:
        A BooleanArray with the same length as `keys`. `true` at row `i`
        means `keys[i]` IS in the build's key set; `false` means it is
        DEFINITELY NOT (zero false positives).

    Null handling matches v0.3: every null row produces `false`. Callers
    chain this with `eval_and` for INNER / SEMI null treatment.

    PERF-CRITICAL: scalar Dict-lookup loop; not SIMD. The InList table
    is at most 128 entries (`IN_LIST_THRESHOLD`), so the hash probe is
    O(1) and L1-resident.
    """
    var n = keys.length
    var mask = BooleanArray.allocate(n)
    if n == 0:
        return mask^

    # SAFETY: same as bloom_mask_int64.
    var data_ptr = keys._typed_ptr_ro()
    var has_nulls = keys.null_count > 0

    if has_nulls:
        for i in range(n):
            if keys.is_null(i):
                continue
            var v = Int64(data_ptr[i])
            if il.contains_int64(v):
                mask.set(i, True)
    else:
        for i in range(n):
            var v = Int64(data_ptr[i])
            if il.contains_int64(v):
                mask.set(i, True)
    return mask^
