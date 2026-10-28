# Sequence sets and UID sets (RFC 3501 section 9, `sequence-set`), and the
# stable sort the view of a folder is built with.
#
# A set is parsed into sorted, merged ranges; matching walks the messages once
# beside the ranges, so a command costs the messages plus the ranges, however
# wide a range is: `1:4294967295` never counts to its end.

# A set with more ranges than this is refused (BAD). One command line is at
# most `max_line` bytes anyway; this keeps the sort small.
comptime MAX_SET_RANGES: Int = 1024


def ascending_order(keys: List[Int]) -> List[Int]:
    """The indices of `keys` in ascending key order. A stable bottom-up merge
    sort over indices (equal keys keep their order), O(n log n): a folder can
    hold many thousands of messages."""
    var n = len(keys)
    var order = List[Int](capacity=n)
    for k in range(n):
        order.append(k)
    var scratch = List[Int](capacity=n)
    for _ in range(n):
        scratch.append(0)
    var width = 1
    while width < n:
        var lo = 0
        while lo < n:
            var mid = lo + width if lo + width < n else n
            var hi = lo + 2 * width if lo + 2 * width < n else n
            var a = lo
            var b = mid
            var o = lo
            while a < mid and b < hi:
                # Take from the right run only when it is strictly smaller,
                # which keeps the sort stable.
                if keys[order[a]] > keys[order[b]]:
                    scratch[o] = order[b]
                    b += 1
                else:
                    scratch[o] = order[a]
                    a += 1
                o += 1
            while a < mid:
                scratch[o] = order[a]
                a += 1
                o += 1
            while b < hi:
                scratch[o] = order[b]
                b += 1
                o += 1
            lo += 2 * width
        var spare = order^
        order = scratch^
        scratch = spare^
        width *= 2
    return order^


struct IdSet(Movable):
    """A parsed set: `ok` is False for a malformed set (the caller answers
    BAD); otherwise `los[i]..his[i]` are disjoint ranges in ascending order."""

    var ok: Bool
    var los: List[Int]
    var his: List[Int]

    def __init__(out self):
        self.ok = False
        self.los = List[Int]()
        self.his = List[Int]()


def _is_digit(c: UInt8) -> Bool:
    return c >= 0x30 and c <= 0x39


def _parse_number(
    bs: Span[UInt8, _], start: Int, end: Int, star_value: Int, mut out: Int
) -> Bool:
    """`bs[start:end]` is `*` (the largest number in use, `star_value`) or a
    number from 1 to 10 digits, 0 excluded. A number past the end of the folder
    matches nothing, however large."""
    if end <= start:
        return False
    if end - start == 1 and bs[start] == 0x2A:
        out = star_value
        return True
    if end - start > 10:
        return False
    var v = 0
    for i in range(start, end):
        if not _is_digit(bs[i]):
            return False
        v = v * 10 + Int(bs[i] - 0x30)
    if v == 0:
        return False
    out = v
    return True


def parse_id_set(text: String, star_value: Int) -> IdSet:
    """Parse `1,3:5,9:*` and the like. `star_value` is what `*` means (the
    number of messages, or the largest UID in the folder, 0 when it is empty).
    A range written backwards is the same range. Returns `ok` False for an
    empty set, an empty item, a 0, a non-number, a number over ten digits, or
    more than `MAX_SET_RANGES` items."""
    var out = IdSet()
    var bs = text.as_bytes()
    var n = len(bs)
    if n == 0:
        return out^
    var los = List[Int]()
    var his = List[Int]()
    var i = 0
    while i <= n:
        # One item: bs[i:j].
        var j = i
        while j < n and bs[j] != 0x2C:
            j += 1
        var colon = -1
        for k in range(i, j):
            if bs[k] == 0x3A:
                colon = k
                break
        var lo = 0
        var hi = 0
        if colon < 0:
            if not _parse_number(bs, i, j, star_value, lo):
                return out^
            hi = lo
        else:
            if not _parse_number(bs, i, colon, star_value, lo):
                return out^
            if not _parse_number(bs, colon + 1, j, star_value, hi):
                return out^
        if lo > hi:
            var t = lo
            lo = hi
            hi = t
        if len(los) >= MAX_SET_RANGES:
            return out^
        los.append(lo)
        his.append(hi)
        i = j + 1
    var order = ascending_order(los)
    var cur_lo = -1
    var cur_hi = -1
    for k in range(len(order)):
        var lo = los[order[k]]
        var hi = his[order[k]]
        if cur_lo < 0:
            cur_lo = lo
            cur_hi = hi
        elif lo <= cur_hi + 1:
            if hi > cur_hi:
                cur_hi = hi
        else:
            out.los.append(cur_lo)
            out.his.append(cur_hi)
            cur_lo = lo
            cur_hi = hi
    if cur_lo >= 0:
        out.los.append(cur_lo)
        out.his.append(cur_hi)
    out.ok = True
    return out^


def match_set(s: IdSet, keys: List[Int]) -> List[Int]:
    """The indices into `keys` whose key is in the set. `keys` must be in
    ascending order (sequence numbers, or the UIDs of a view). One pass over
    both."""
    var found = List[Int]()
    var r = 0
    for i in range(len(keys)):
        var key = keys[i]
        while r < len(s.his) and s.his[r] < key:
            r += 1
        if r >= len(s.his):
            break
        if s.los[r] <= key:
            found.append(i)
    return found^
