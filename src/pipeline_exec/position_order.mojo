# =============================================================================
# position_order -- morsels sorted by the position their source gave them
# =============================================================================
#
# A source stamps each morsel with its position in the input,
# (`partition_id`, `origin_hint`): a Parquet morsel's partition id is its flat
# row group times 2^20 plus its index within that row group, and a resident
# batch's is the index of its slot. `position_order` sorts a list of positions
# into source order, so a sink that keeps what each worker handed it can read
# it back in the order of the input whatever the schedule was.

from std.builtin.swap import swap


def _before(
    a_part: Int, a_hint: Int, b_part: Int, b_hint: Int
) -> Bool:
    """True when position a sorts strictly before position b."""
    if a_part != b_part:
        return a_part < b_part
    return a_hint < b_hint


def position_order(parts: List[Int], hints: List[Int]) -> List[Int]:
    """The indices 0..n-1 sorted by (part, hint), equal positions in index
    order (a bottom-up merge sort)."""
    var n = len(parts)
    var order = List[Int](capacity=n)
    for i in range(n):
        order.append(i)
    var scratch = List[Int](length=n, fill=0)
    var width = 1
    while width < n:
        var lo = 0
        while lo < n:
            var mid = min(lo + width, n)
            var hi = min(lo + 2 * width, n)
            var l = lo
            var r = mid
            var k = lo
            while l < mid and r < hi:
                var a = order[l]
                var b = order[r]
                if _before(parts[b], hints[b], parts[a], hints[a]):
                    scratch[k] = b
                    r += 1
                else:
                    scratch[k] = a
                    l += 1
                k += 1
            while l < mid:
                scratch[k] = order[l]
                l += 1
                k += 1
            while r < hi:
                scratch[k] = order[r]
                r += 1
                k += 1
            lo += 2 * width
        swap(order, scratch)
        width *= 2
    return order^
