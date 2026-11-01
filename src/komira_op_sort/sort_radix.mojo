# =============================================================================
# LSD radix sort over 64-bit keys, producing permutation indices
# =============================================================================
#
# 8-bit digits, 256 buckets, at most 8 passes, least significant byte first.
# Each pass is a counting sort, so the whole sort is STABLE: equal keys keep
# their input order. Ascending only; a caller that wants descending reverses
# the result (equal keys then come out in reverse input order) or complements
# the keys (equal keys keep input order).
#
# A pass whose byte is the same for every key would leave the order as it is,
# so it is skipped. Keys drawn from a small range share their upper bytes,
# and those passes cost one histogram each instead of a histogram and a
# scatter.
#
# Two entry points over one kernel:
#   * `radix_sort_int64`: signed keys. The sign bit is flipped first
#     (INT64_MIN -> 0x0000..., -1 -> 0x7FFF..., 0 -> 0x8000...,
#     INT64_MAX -> 0xFFFF...), so unsigned byte order is signed order.
#   * `radix_sort_u64_keys`: keys that are already unsigned magnitudes, such
#     as the big-endian string prefixes `sort_string` packs. Flipping their
#     top bit would corrupt their order, so they are sorted as they are.
# =============================================================================

from std.memory import alloc, memcpy
from std.sys import simd_width_of

from komira_arrow.primitive_array import PrimitiveArray

from .sort import _identity_indices


comptime _RADIX_BUCKETS: Int = 256
comptime _RADIX_PASSES: Int = 8
comptime _SIGN_BIT_MASK: UInt64 = 0x8000000000000000


def radix_sort_int64(
    keys: PrimitiveArray[DType.int64],
) -> PrimitiveArray[DType.int32]:
    """Stable ascending radix sort of signed Int64 keys; returns the
    permutation such that `keys[result[i]]` is ascending."""
    var n = keys.length
    if n <= 1:
        return _identity_indices(n)
    # SAFETY: `ukeys` is owned by this frame and handed to `_radix_sort_u64`,
    # which reads it and returns before the free below.
    var ukeys = alloc[UInt64](n)
    var keys_view = keys.view_ro()
    var key_ptr = keys_view._unsafe_ptr().bitcast[Scalar[DType.uint64]]()
    # PERF-CRITICAL: SIMD sign-bit XOR (load, xor a broadcast constant, store).
    comptime _WK = simd_width_of[DType.uint64]()
    var mask_vec = SIMD[DType.uint64, _WK](_SIGN_BIT_MASK)
    var simd_end = (n // _WK) * _WK
    var i = 0
    while i < simd_end:
        (ukeys + i).store[width=_WK](key_ptr.load[width=_WK](i) ^ mask_vec)
        i += _WK
    while i < n:
        ukeys[i] = (key_ptr + i)[] ^ _SIGN_BIT_MASK
        i += 1
    var result = _radix_sort_u64(ukeys, n)
    ukeys.free()
    return result^


def radix_sort_u64_keys(
    keys: PrimitiveArray[DType.uint64],
) -> PrimitiveArray[DType.int32]:
    """Stable ascending radix sort of UInt64 keys read as unsigned
    magnitudes (no sign flip); returns the permutation."""
    var n = keys.length
    if n <= 1:
        return _identity_indices(n)
    # SAFETY: as in `radix_sort_int64`.
    var ukeys = alloc[UInt64](n)
    var keys_view = keys.view_ro()
    var key_ptr = keys_view._unsafe_ptr().bitcast[Scalar[DType.uint64]]()
    memcpy(dest=ukeys, src=key_ptr, count=n)
    var result = _radix_sort_u64(ukeys, n)
    ukeys.free()
    return result^


def _radix_sort_u64[
    o_keys: Origin
](
    ukeys: UnsafePointer[UInt64, o_keys],
    n: Int,
) -> PrimitiveArray[DType.int32]:
    """The kernel: the permutation that orders `ukeys[0:n)` ascending,
    unsigned, stably. `n >= 2`."""
    var indices = _identity_indices(n)
    var indices_view = indices.view_mut()
    var idx_ptr = indices_view._unsafe_ptr().bitcast[Scalar[DType.int32]]()
    # SAFETY: `tmp` and `counts` are owned by this frame and freed below.
    var tmp = alloc[Scalar[DType.int32]](n)
    var counts = alloc[Int](_RADIX_BUCKETS)

    # The permutation ping-pongs between `indices` and `tmp`. `in_tmp` says
    # which buffer holds it now; the two buffers are never swapped as
    # pointers, so each keeps its own origin.
    var in_tmp = False
    for pass_num in range(_RADIX_PASSES):
        var shift = UInt64(pass_num * 8)
        var moved: Bool
        if in_tmp:
            moved = _radix_pass(tmp, idx_ptr, ukeys, counts, n, shift)
        else:
            moved = _radix_pass(idx_ptr, tmp, ukeys, counts, n, shift)
        if moved:
            in_tmp = not in_tmp

    if in_tmp:
        memcpy(dest=idx_ptr, src=tmp, count=n)
    counts.free()
    tmp.free()
    return indices^


def _radix_pass[
    o_src: Origin[mut=True], o_dst: Origin[mut=True], o_keys: Origin,
    o_counts: Origin[mut=True],
](
    src: UnsafePointer[Scalar[DType.int32], o_src],
    dst: UnsafePointer[Scalar[DType.int32], o_dst],
    ukeys: UnsafePointer[UInt64, o_keys],
    counts: UnsafePointer[Int, o_counts],
    n: Int,
    shift: UInt64,
) -> Bool:
    """One counting-sort pass on the byte at `shift`, from `src` into `dst`.

    Returns False, writing nothing, when every key has the same byte there
    (the pass would not change the order)."""
    for b in range(_RADIX_BUCKETS):
        counts[b] = 0
    for i in range(n):
        var idx = Int(src[i])
        counts[Int((ukeys[idx] >> shift) & UInt64(0xFF))] += 1

    for b in range(_RADIX_BUCKETS):
        if counts[b] == n:
            return False

    # Exclusive prefix sum: counts[b] becomes the first output slot of b.
    var running = 0
    for b in range(_RADIX_BUCKETS):
        var count = counts[b]
        counts[b] = running
        running += count

    for i in range(n):
        var idx = src[i]
        var bucket = Int((ukeys[Int(idx)] >> shift) & UInt64(0xFF))
        dst[counts[bucket]] = idx
        counts[bucket] += 1
    return True
