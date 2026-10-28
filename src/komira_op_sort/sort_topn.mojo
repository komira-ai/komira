# =============================================================================
# Top-K over one key column: heap selection, O(N log K)
# =============================================================================
#
# For ORDER BY col LIMIT K over N rows a full sort costs O(N log N); a bounded
# heap of K entries costs O(N log K). The heap holds the K best rows seen so
# far with the WORST of them on top (a max-heap for ASC, a min-heap for
# DESC); a row replaces the top only when it sorts strictly before it. The K
# survivors are then insertion-sorted (K is small).
#
# Keys compare through `sort.sort_key_lt`, so a float column has NaN above
# +inf here exactly as in the full sort: DESC LIMIT K returns the NaN rows
# first.
#
# ⚠ Ties at the cut are not broken by row position: among rows with the same
# key straddling the K-th place, which ones survive depends on the heap's
# evictions. A caller that needs a deterministic answer for tied keys adds a
# tie-break key (see `sort_topn_sink.append_deterministic_tiebreak`).
# =============================================================================

from std.memory import alloc

from komira_arrow.primitive_array import PrimitiveArray

from .sort import _sort_indices, sort_key_lt


def topn_indices_int64(
    keys: PrimitiveArray[DType.int64],
    k: Int,
    descending: Bool = False,
) -> PrimitiveArray[DType.int32]:
    """The indices of the first `k` rows of `keys` in sort order (all rows
    when `k >= len`; none when `k <= 0`)."""
    return _topn_indices(keys, k, descending)


def topn_indices_float64(
    keys: PrimitiveArray[DType.float64],
    k: Int,
    descending: Bool = False,
) -> PrimitiveArray[DType.int32]:
    """`topn_indices_int64` for Float64 keys; NaN sorts above +inf."""
    return _topn_indices(keys, k, descending)


@always_inline
def _before[dt: DType](a: Scalar[dt], b: Scalar[dt], descending: Bool) -> Bool:
    """True iff key `a` sorts strictly before key `b` in this direction."""
    if descending:
        return sort_key_lt(b, a)
    return sort_key_lt(a, b)


def _topn_indices[dt: DType](
    keys: PrimitiveArray[dt],
    k: Int,
    descending: Bool,
) -> PrimitiveArray[DType.int32]:
    var n = keys.length
    if n == 0 or k <= 0:
        return PrimitiveArray[DType.int32].allocate(0)
    if k >= n:
        return _sort_indices(keys, descending)

    var keys_view = keys.view_ro()
    var key_ptr = keys_view._unsafe_ptr().bitcast[Scalar[dt]]()

    # SAFETY: `heap_keys` / `heap_idx` are owned by this frame and freed
    # before return; `key_ptr` borrows `keys`, which outlives the selection.
    var heap_keys = alloc[Scalar[dt]](k)
    var heap_idx = alloc[Scalar[DType.int32]](k)
    for i in range(k):
        heap_keys[i] = (key_ptr + i)[]
        heap_idx[i] = Scalar[DType.int32](i)

    # Heapify, worst on top.
    var start = k // 2 - 1
    while start >= 0:
        _sift_down(heap_keys, heap_idx, k, start, descending)
        start -= 1

    for i in range(k, n):
        var val = (key_ptr + i)[]
        if _before(val, heap_keys[0], descending):
            heap_keys[0] = val
            heap_idx[0] = Scalar[DType.int32](i)
            _sift_down(heap_keys, heap_idx, k, 0, descending)

    # Order the K survivors. Insertion sort reading the keys from the input
    # (not from the heap copy), moving an element only past one it strictly
    # sorts before.
    var result = PrimitiveArray[DType.int32].allocate(k)
    var result_view = result.view_mut()
    var result_ptr = result_view._unsafe_ptr().bitcast[Scalar[DType.int32]]()
    for i in range(k):
        (result_ptr + i)[] = heap_idx[i]
    for i in range(1, k):
        var idx_i = (result_ptr + i)[]
        var key_i = (key_ptr + Int(idx_i))[]
        var j = i
        while j > 0:
            var idx_j = (result_ptr + j - 1)[]
            if not _before(key_i, (key_ptr + Int(idx_j))[], descending):
                break
            (result_ptr + j)[] = idx_j
            j -= 1
        (result_ptr + j)[] = idx_i

    heap_keys.free()
    heap_idx.free()
    return result^


def _sift_down[
    dt: DType, //, o_keys: Origin[mut=True], o_idx: Origin[mut=True]
](
    heap_keys: UnsafePointer[Scalar[dt], o_keys],
    heap_idx: UnsafePointer[Scalar[DType.int32], o_idx],
    n: Int,
    pos: Int,
    descending: Bool,
):
    """Restore the heap below `pos`: every parent sorts after (is worse than)
    or equal to its children, so the worst entry is at the top."""
    var current = pos
    while True:
        var worst = current
        var left = 2 * current + 1
        var right = 2 * current + 2
        if left < n and _before(heap_keys[worst], heap_keys[left], descending):
            worst = left
        if right < n and _before(heap_keys[worst], heap_keys[right], descending):
            worst = right
        if worst == current:
            break
        var tmp_key = heap_keys[current]
        heap_keys[current] = heap_keys[worst]
        heap_keys[worst] = tmp_key
        var tmp_idx = heap_idx[current]
        heap_idx[current] = heap_idx[worst]
        heap_idx[worst] = tmp_idx
        current = worst
