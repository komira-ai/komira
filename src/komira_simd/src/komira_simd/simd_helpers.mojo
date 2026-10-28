# =============================================================================
# SIMD Helper Abstractions — Reusable vectorize[]-based primitives
# =============================================================================
#
# Each function uses manual SIMD loops or vectorize[] internally to handle
# SIMD width selection and tail-loop cleanup automatically. These are the
# building blocks for replacing scalar loops across the engine.
#
# PERF-CRITICAL: These are called from hot paths (agg merge, sort init,
# window fills, parquet stats). Do not add branches or allocations.
# =============================================================================

# =============================================================================
# ORIGINS
# =============================================================================
# Every helper is origin-generic via a callsite-inferred origin parameter
# (`o: Origin[mut=True]` for writers, `o: Origin` / `_` for readers). No
# wildcard origins remain. Callers bind the origin implicitly by passing
# a typed pointer (e.g. a field pointer from Slab / MmapAlignedBuffer).
# =============================================================================

from std.algorithm import vectorize
from std.sys import simd_width_of


# =============================================================================
# Reductions (read-only pointers — accept any origin via `_`)
# =============================================================================


def _simd_sum[dtype: DType](ptr: UnsafePointer[Scalar[dtype], _], n: Int) -> Scalar[dtype]:
    """Sum n elements using SIMD vectorization.

    SAFETY: Caller must ensure ptr points to at least n valid elements.
    """
    if n == 0:
        return Scalar[dtype](0)

    comptime width = simd_width_of[dtype]()
    var simd_acc = SIMD[dtype, width](0)

    var simd_end = (n // width) * width
    var i = 0
    while i < simd_end:
        simd_acc += ptr.load[width=width](i)
        i += width
    var acc = simd_acc.reduce_add()
    # Scalar tail
    while i < n:
        acc += ptr.load[width=1](i)
        i += 1
    return acc


def _simd_min[dtype: DType](ptr: UnsafePointer[Scalar[dtype], _], n: Int) -> Scalar[dtype]:
    """Find minimum of n elements.

    SAFETY: Caller must ensure ptr points to at least n valid elements.
    Undefined behavior if n == 0.
    """
    comptime width = simd_width_of[dtype]()
    var first_val = ptr.load[width=1](0)
    if n == 1:
        return first_val

    var simd_acc = SIMD[dtype, width](first_val)
    var simd_end = (n // width) * width
    var i = 0
    if simd_end > 0:
        simd_acc = ptr.load[width=width](0)
        i = width
        while i < simd_end:
            var chunk = ptr.load[width=width](i)
            simd_acc = (simd_acc.lt(chunk)).select(simd_acc, chunk)
            i += width
    var result = simd_acc.reduce_min()
    while i < n:
        var v = ptr.load[width=1](i)
        if v < result:
            result = v
        i += 1
    return result


def _simd_max[dtype: DType](ptr: UnsafePointer[Scalar[dtype], _], n: Int) -> Scalar[dtype]:
    """Find maximum of n elements.

    SAFETY: Caller must ensure ptr points to at least n valid elements.
    Undefined behavior if n == 0.
    """
    comptime width = simd_width_of[dtype]()
    var first_val = ptr.load[width=1](0)
    if n == 1:
        return first_val

    var simd_acc = SIMD[dtype, width](first_val)
    var simd_end = (n // width) * width
    var i = 0
    if simd_end > 0:
        simd_acc = ptr.load[width=width](0)
        i = width
        while i < simd_end:
            var chunk = ptr.load[width=width](i)
            simd_acc = (simd_acc.gt(chunk)).select(simd_acc, chunk)
            i += width
    var result = simd_acc.reduce_max()
    while i < n:
        var v = ptr.load[width=1](i)
        if v > result:
            result = v
        i += 1
    return result


# =============================================================================
# PERF-CRITICAL: SIMD min+max in a single pass.
# =============================================================================
# Called from `_detect_key_domain` / `_detect_composite_domain` in the
# aggregation dispatcher. These functions scan the full key column to decide
# whether PerfectHash is applicable — a 6M-row int32 scan = ~24MB of loads.
#
# The scalar min/max update pattern `if v < kmin: kmin = v; if v > kmax: kmax = v`
# does NOT auto-vectorize in Mojo (a branchy conditional update runs at a
# large scalar penalty). This kernel uses the `select` pattern that does
# vectorize — read a W-wide chunk
# once, fold into both a running min SIMD-vec AND a running max SIMD-vec,
# finalize with reduce_min / reduce_max.
#
# Memory traffic is halved vs calling `_simd_min` then `_simd_max`
# (one pass vs two); that matters because the hot-cache win is already
# small, so the cold-cache path is the win.
#
# Scalar fallback: the final `while i < n` tail loop is unavoidable when
# `n` is not a multiple of `width`, but never more than `width - 1` rows.
# =============================================================================
def _simd_min_max[dtype: DType](ptr: UnsafePointer[Scalar[dtype], _], n: Int) -> Tuple[Scalar[dtype], Scalar[dtype]]:
    """Find (min, max) of n elements in one pass.

    Returns (min, max) tuple. Undefined behavior if n == 0.
    SAFETY: Caller must ensure ptr points to at least n valid elements.
    """
    var first_val = ptr.load[width=1](0)
    if n == 1:
        return (first_val, first_val)

    comptime width = simd_width_of[dtype]()
    var simd_end = (n // width) * width
    var i = 0
    var min_val = first_val
    var max_val = first_val

    if simd_end > 0:
        var first_chunk = ptr.load[width=width](0)
        var min_acc = first_chunk
        var max_acc = first_chunk
        i = width
        while i < simd_end:
            var chunk = ptr.load[width=width](i)
            # Branchless min/max via select — this is the pattern shown to
            # survive Mojo's codegen into NEON smin/umin (or PMIN on x86).
            min_acc = (min_acc.lt(chunk)).select(min_acc, chunk)
            max_acc = (max_acc.gt(chunk)).select(max_acc, chunk)
            i += width
        min_val = min_acc.reduce_min()
        max_val = max_acc.reduce_max()

    # Scalar tail — at most width-1 rows.
    while i < n:
        var v = ptr.load[width=1](i)
        if v < min_val:
            min_val = v
        if v > max_val:
            max_val = v
        i += 1
    return (min_val, max_val)


def _simd_count_if[dtype: DType](ptr: UnsafePointer[Scalar[dtype], _], n: Int, threshold: Scalar[dtype]) -> Int:
    """Count elements strictly greater than threshold.

    SAFETY: Caller must ensure ptr points to at least n valid elements.
    """
    if n == 0:
        return 0

    comptime width = simd_width_of[dtype]()
    var simd_end = (n // width) * width
    var count = Int(0)
    var thresh_vec = SIMD[dtype, width](threshold)

    var i = 0
    while i < simd_end:
        var chunk = ptr.load[width=width](i)
        var mask = chunk.gt(thresh_vec)
        count += Int(mask.cast[DType.uint8]().reduce_add())
        i += width
    while i < n:
        if ptr.load[width=1](i) > threshold:
            count += 1
        i += 1
    return count


# =============================================================================
# Fill / Initialize (write to dst — origin-generic, bound at callsite)
# =============================================================================


def _simd_fill[dtype: DType, o: Origin[mut=True]](
    ptr: UnsafePointer[Scalar[dtype], o], n: Int, value: Scalar[dtype]
):
    """Broadcast fill n elements with value.

    SAFETY: Caller must ensure ptr points to at least n writable elements.
    Origin `o` is inferred from the caller so liveness is tracked through
    the call -- no wildcard needed.
    """
    if n == 0:
        return

    comptime width = simd_width_of[dtype]()
    var val_vec = SIMD[dtype, width](value)
    var simd_end = (n // width) * width

    var i = 0
    while i < simd_end:
        ptr.store[width=width](i, val_vec)
        i += width
    while i < n:
        ptr.store[width=1](i, value)
        i += 1


def _simd_iota[dtype: DType, o: Origin[mut=True]](
    ptr: UnsafePointer[Scalar[dtype], o], n: Int, start: Scalar[dtype] = 0
):
    """Fill with sequential values: start, start+1, start+2, ...

    SAFETY: Caller must ensure ptr points to at least n writable elements.
    Origin `o` is inferred from the caller -- no wildcard needed.
    """
    if n == 0:
        return

    comptime width = simd_width_of[dtype]()
    var simd_end = (n // width) * width

    # Build the lane-offset vector: [0, 1, 2, ..., width-1]
    var lane_offsets = SIMD[dtype, width](0)
    for j in range(width):
        lane_offsets[j] = Scalar[dtype](j)

    var stride_vec = SIMD[dtype, width](Scalar[dtype](width))
    var base = SIMD[dtype, width](start) + lane_offsets

    var i = 0
    while i < simd_end:
        ptr.store[width=width](i, base)
        base += stride_vec
        i += width
    # Scalar tail
    var scalar_val = start + Scalar[dtype](simd_end)
    while i < n:
        ptr.store[width=1](i, scalar_val)
        scalar_val += Scalar[dtype](1)
        i += 1


# =============================================================================
# Element-wise array operations (dst[i] op= src[i])
# Origin-generic for both dst and src — caller binds o_dst / o_src.
# =============================================================================


def simd_add_arrays[
    dtype: DType, o_dst: Origin[mut=True], o_src: Origin
](
    dst: UnsafePointer[Scalar[dtype], o_dst],
    src: UnsafePointer[Scalar[dtype], o_src],
    n: Int,
):
    """Element-wise dst[i] += src[i].

    SAFETY: Caller must ensure both ptrs point to at least n valid elements.
    Origins are inferred from the caller -- no wildcard needed.
    """
    if n == 0:
        return

    comptime width = simd_width_of[dtype]()
    var simd_end = (n // width) * width

    var i = 0
    while i < simd_end:
        var d = dst.load[width=width](i)
        var s = src.load[width=width](i)
        dst.store[width=width](i, d + s)
        i += width
    while i < n:
        var d = dst.load[width=1](i)
        var s = src.load[width=1](i)
        dst.store[width=1](i, d + s)
        i += 1


def simd_min_arrays[
    dtype: DType, o_dst: Origin[mut=True], o_src: Origin
](
    dst: UnsafePointer[Scalar[dtype], o_dst],
    src: UnsafePointer[Scalar[dtype], o_src],
    n: Int,
):
    """Element-wise dst[i] = min(dst[i], src[i]).

    SAFETY: Caller must ensure both ptrs point to at least n valid elements.
    """
    if n == 0:
        return

    comptime width = simd_width_of[dtype]()
    var simd_end = (n // width) * width

    var i = 0
    while i < simd_end:
        var d = dst.load[width=width](i)
        var s = src.load[width=width](i)
        dst.store[width=width](i, (d.lt(s)).select(d, s))
        i += width
    while i < n:
        var d = dst.load[width=1](i)
        var s = src.load[width=1](i)
        if s < d:
            dst.store[width=1](i, s)
        i += 1


def simd_max_arrays[
    dtype: DType, o_dst: Origin[mut=True], o_src: Origin
](
    dst: UnsafePointer[Scalar[dtype], o_dst],
    src: UnsafePointer[Scalar[dtype], o_src],
    n: Int,
):
    """Element-wise dst[i] = max(dst[i], src[i]).

    SAFETY: Caller must ensure both ptrs point to at least n valid elements.
    """
    if n == 0:
        return

    comptime width = simd_width_of[dtype]()
    var simd_end = (n // width) * width

    var i = 0
    while i < simd_end:
        var d = dst.load[width=width](i)
        var s = src.load[width=width](i)
        dst.store[width=width](i, (d.gt(s)).select(d, s))
        i += width
    while i < n:
        var d = dst.load[width=1](i)
        var s = src.load[width=1](i)
        if s > d:
            dst.store[width=1](i, s)
        i += 1
