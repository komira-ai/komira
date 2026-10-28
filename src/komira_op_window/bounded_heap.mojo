# =============================================================================
# bounded_heap -- bounded binary heaps for the top-N states
# =============================================================================
#
# A top-N keeps the N best rows seen so far; the heap's ROOT is the WORST row
# kept, so a candidate is compared once against the root and either replaces
# it or is dropped. Three heaps:
#
#   * `BoundedHeapInt64Payload[N]`: capacity N at compile time, storage an
#     `InlineArray` (no allocation). A max-heap on an Int64 key: it keeps the
#     N SMALLEST keys. A caller that wants the N largest stores `~key` (the
#     bitwise NOT reverses the order of every Int64 without overflow) or any
#     other order-reversing encoding; a caller with float or NULL keys maps
#     them to an order-preserving Int64 first.
#   * `BoundedHeapInt64PayloadDynamic`: the same with a run-time capacity
#     (List storage, reserved once).
#   * `BoundedHeapStringPayload[N, sort_dir]`: a STRING key compared byte-wise
#     (DuckDB's default collation: bytes over the common prefix, the shorter
#     string first on a prefix tie). The key bytes live in the heap's own
#     arena, appended when a candidate is kept, so the arena grows with the
#     number of winners, not with the input. `sort_dir` is ASC (keep the N
#     smallest) or DESC (keep the N largest).
#
# Ties: slots order by (key, payload id), the SMALLER payload id better. A
# caller whose payload id is the input row index therefore gets exactly the
# stable sort's rows and order among equal keys, and the kept set does not
# depend on the order rows arrive (nor on how worker states are merged).
#
# Each slot carries an opaque Int64 payload id (a row index or a buffer slot
# the caller owns). `push_returning_evicted` reports which payload id left the
# heap, so the caller can recycle its storage and keep memory O(N).
# =============================================================================

from komira_counters.keyeq_census import KEYEQ_BHEAP_SLOTS_EQUAL, keyeq_record


@fieldwise_init
struct HeapSlot(Copyable, Movable, ImplicitlyCopyable):
    """One Int64-key heap slot: the key and an opaque payload id."""

    var key: Int64
    var payload_row_id: Int64


@fieldwise_init
struct HeapSlotStr(Copyable, Movable, ImplicitlyCopyable):
    """One STRING-key heap slot: the key's `(offset, length)` in the owning
    heap's arena and an opaque payload id."""

    var key_off: Int
    var key_len: Int
    var payload_row_id: Int64


@always_inline
def _slot_worse(a: HeapSlot, b: HeapSlot) -> Bool:
    """True if `a` is worse to keep than `b`: the larger key, and on equal
    keys the larger payload id."""
    return a.key > b.key or (a.key == b.key and a.payload_row_id > b.payload_row_id)


@always_inline
def _key_beats(key: Int64, payload_row_id: Int64, root: HeapSlot) -> Bool:
    """True if a candidate orders strictly before `root` by (key, payload id)."""
    return key < root.key or (key == root.key and payload_row_id < root.payload_row_id)


# =============================================================================
# BoundedHeapInt64Payload[N]
# =============================================================================


struct BoundedHeapInt64Payload[N: Int](Copyable, Movable):
    """A max-heap of at most N (key, payload id) slots that keeps the N
    smallest (key, payload id) slots; no child is worse than its parent."""

    var slots: InlineArray[HeapSlot, Self.N]
    var n_used: Int

    def __init__(out self):
        self.slots = InlineArray[HeapSlot, Self.N](fill=HeapSlot(Int64(0), Int64(0)))
        self.n_used = 0

    @always_inline
    def capacity(self) -> Int:
        return Self.N

    @always_inline
    def size(self) -> Int:
        return self.n_used

    @always_inline
    def _percolate_up(mut self, start_idx: Int):
        var i = start_idx
        while i > 0:
            var parent = (i - 1) // 2
            if _slot_worse(self.slots[i], self.slots[parent]):
                var tmp = self.slots[i]
                self.slots[i] = self.slots[parent]
                self.slots[parent] = tmp
                i = parent
            else:
                return

    @always_inline
    def _percolate_down(mut self, start_idx: Int):
        var i = start_idx
        while True:
            var left = 2 * i + 1
            var right = 2 * i + 2
            var largest = i
            if left < self.n_used and _slot_worse(self.slots[left], self.slots[largest]):
                largest = left
            if right < self.n_used and _slot_worse(self.slots[right], self.slots[largest]):
                largest = right
            if largest == i:
                return
            var tmp = self.slots[i]
            self.slots[i] = self.slots[largest]
            self.slots[largest] = tmp
            i = largest

    @always_inline
    def push(mut self, key: Int64, payload_row_id: Int64):
        """Add a slot; when full, replace the root only if the candidate orders
        before it by (key, payload id)."""
        if self.n_used < Self.N:
            self.slots[self.n_used] = HeapSlot(key, payload_row_id)
            self.n_used = self.n_used + 1
            self._percolate_up(self.n_used - 1)
        elif _key_beats(key, payload_row_id, self.slots[0]):
            self.slots[0] = HeapSlot(key, payload_row_id)
            self._percolate_down(0)

    def push_returning_evicted(mut self, key: Int64, payload_row_id: Int64) -> Int64:
        """`push`, returning the payload id that left the heap: -1 when the
        heap was not full, the displaced root's id when the candidate was
        kept, the candidate's own id when it was dropped."""
        if self.n_used < Self.N:
            self.slots[self.n_used] = HeapSlot(key, payload_row_id)
            self.n_used = self.n_used + 1
            self._percolate_up(self.n_used - 1)
            return Int64(-1)
        if _key_beats(key, payload_row_id, self.slots[0]):
            var displaced = self.slots[0].payload_row_id
            self.slots[0] = HeapSlot(key, payload_row_id)
            self._percolate_down(0)
            return displaced
        return payload_row_id

    @always_inline
    def peek_root(self) -> HeapSlot:
        """The root (the largest key). Requires `size() > 0`."""
        return self.slots[0]

    def extract_sorted(mut self) -> List[HeapSlot]:
        """Drain the heap into ascending key order. O(N log N)."""
        var out = List[HeapSlot](capacity=self.n_used)
        while self.n_used > 0:
            out.append(self.slots[0])
            self.n_used = self.n_used - 1
            if self.n_used > 0:
                self.slots[0] = self.slots[self.n_used]
                self._percolate_down(0)
        var rev = List[HeapSlot](capacity=len(out))
        for i in range(len(out) - 1, -1, -1):
            rev.append(out[i])
        return rev^


# =============================================================================
# BoundedHeapStringPayload[N, sort_dir]
# =============================================================================


struct BoundedHeapStringPayload[N: Int, sort_dir: Int](Copyable, Movable):
    """A bounded heap over STRING keys compared byte-wise. `sort_dir` 0
    (ASC) keeps the N smallest strings, 1 (DESC) the N largest; the root is
    the worst string kept. Keys arrive as a `Span[UInt8]` and are copied into
    the arena only when kept."""

    var slots: List[HeapSlotStr]
    var arena: List[UInt8]
    var n_used: Int

    def __init__(out self):
        self.slots = List[HeapSlotStr]()
        self.arena = List[UInt8]()
        self.n_used = 0

    @always_inline
    def capacity(self) -> Int:
        return Self.N

    @always_inline
    def size(self) -> Int:
        return self.n_used

    @always_inline
    def _cmp_pos(self, pos_a: Int, pos_b: Int) -> Int:
        """-1 / 0 / 1 for the key at heap position `pos_a` against `pos_b`,
        ascending byte order."""
        var abase = self.slots[pos_a].key_off
        var alen = self.slots[pos_a].key_len
        var bbase = self.slots[pos_b].key_off
        var blen = self.slots[pos_b].key_len
        var min_len = alen if alen < blen else blen
        for p in range(min_len):
            var ca = self.arena[abase + p]
            var cb = self.arena[bbase + p]
            if ca != cb:
                return -1 if ca < cb else 1
        if alen < blen:
            return -1
        if alen > blen:
            return 1
        return 0

    @always_inline
    def _slot_worse_pos(self, pos_a: Int, pos_b: Int) -> Bool:
        """True if the key at `pos_a` is worse to keep than the one at
        `pos_b`: larger for ASC, smaller for DESC."""
        var c = self._cmp_pos(pos_a, pos_b)
        if c == 0:
            return self.slots[pos_a].payload_row_id > self.slots[pos_b].payload_row_id
        comptime if Self.sort_dir == 1:
            return c < 0
        else:
            return c > 0

    @always_inline
    def _cmp_span_slot[bo: Origin[mut=False]](self, cand: Span[UInt8, bo], slot: Int) -> Int:
        """-1 / 0 / 1 for a candidate key against the key at heap position
        `slot`, ascending byte order."""
        var sbase = self.slots[slot].key_off
        var slen = self.slots[slot].key_len
        var clen = len(cand)
        var min_len = clen if clen < slen else slen
        for p in range(min_len):
            var ca = cand[p]
            var cb = self.arena[sbase + p]
            if ca != cb:
                return -1 if ca < cb else 1
        if clen < slen:
            return -1
        if clen > slen:
            return 1
        return 0

    @always_inline
    def _span_worse_than_root[bo: Origin[mut=False]](
        self, cand: Span[UInt8, bo], payload_row_id: Int64
    ) -> Bool:
        """True if the candidate does not order strictly before the root by
        (key, payload id), i.e. it is dropped by a full heap."""
        var c = self._cmp_span_slot[bo](cand, 0)
        if c == 0:
            return payload_row_id >= self.slots[0].payload_row_id
        comptime if Self.sort_dir == 1:
            return c < 0
        else:
            return c > 0

    @always_inline
    def _append_key[bo: Origin[mut=False]](mut self, key: Span[UInt8, bo]) -> Int:
        var start = len(self.arena)
        for i in range(len(key)):
            self.arena.append(key[i])
        return start

    @always_inline
    def _percolate_up(mut self, start_idx: Int):
        var i = start_idx
        while i > 0:
            var parent = (i - 1) // 2
            if self._slot_worse_pos(i, parent):
                var tmp = self.slots[i]
                self.slots[i] = self.slots[parent]
                self.slots[parent] = tmp
                i = parent
            else:
                return

    @always_inline
    def _percolate_down(mut self, start_idx: Int):
        var i = start_idx
        while True:
            var left = 2 * i + 1
            var right = 2 * i + 2
            var worst = i
            if left < self.n_used and self._slot_worse_pos(left, worst):
                worst = left
            if right < self.n_used and self._slot_worse_pos(right, worst):
                worst = right
            if worst == i:
                return
            var tmp = self.slots[i]
            self.slots[i] = self.slots[worst]
            self.slots[worst] = tmp
            i = worst

    def push_returning_evicted[bo: Origin[mut=False]](
        mut self, key: Span[UInt8, bo], payload_row_id: Int64
    ) -> Int64:
        """As `BoundedHeapInt64Payload.push_returning_evicted`. The bytes of
        a displaced key stay in the arena (append-only)."""
        if self.n_used < Self.N:
            var off = self._append_key[bo](key)
            self.slots.append(HeapSlotStr(off, len(key), payload_row_id))
            self.n_used = self.n_used + 1
            self._percolate_up(self.n_used - 1)
            return Int64(-1)
        if self.n_used == 0:
            # Capacity 0 keeps nothing (there is no root to compare with).
            return payload_row_id
        if self._span_worse_than_root[bo](key, payload_row_id):
            return payload_row_id
        var displaced = self.slots[0].payload_row_id
        var off = self._append_key[bo](key)
        self.slots[0] = HeapSlotStr(off, len(key), payload_row_id)
        self._percolate_down(0)
        return displaced

    @always_inline
    def peek_root_payload(self) -> Int64:
        return self.slots[0].payload_row_id

    @always_inline
    def compare_to_root[bo: Origin[mut=False]](self, cand: Span[UInt8, bo]) -> Int:
        """-1 if the candidate key is better to keep than the root (the worst
        key kept), 0 if it ties with it, 1 if it is worse; payload ids are not
        compared. Requires `size() > 0`."""
        var c = self._cmp_span_slot[bo](cand, 0)
        comptime if Self.sort_dir == 1:
            return -c
        else:
            return c

    def root_key_bytes(self) -> List[UInt8]:
        """The root's key bytes, copied. Requires `size() > 0`."""
        var out = List[UInt8](capacity=self.slots[0].key_len)
        for i in range(self.slots[0].key_len):
            out.append(self.arena[self.slots[0].key_off + i])
        return out^

    @always_inline
    def candidate_beats_root[bo: Origin[mut=False]](
        self, key: Span[UInt8, bo], payload_row_id: Int64
    ) -> Bool:
        """True if a full heap would keep the candidate (no store). A heap
        of capacity 0 keeps nothing."""
        if Self.N == 0:
            return False
        return not self._span_worse_than_root[bo](key, payload_row_id)

    def extract_sorted(mut self) -> List[HeapSlotStr]:
        """Drain the heap best-first (ascending strings for ASC, descending
        for DESC). The arena is not reclaimed, so the returned slots still
        index valid bytes."""
        var out = List[HeapSlotStr](capacity=self.n_used)
        while self.n_used > 0:
            out.append(self.slots[0])
            self.n_used = self.n_used - 1
            if self.n_used > 0:
                self.slots[0] = self.slots[self.n_used]
                self._percolate_down(0)
            _ = self.slots.pop()
        var rev = List[HeapSlotStr](capacity=len(out))
        for i in range(len(out) - 1, -1, -1):
            rev.append(out[i])
        return rev^

    @always_inline
    def key_span_of_slot(self, slot: HeapSlotStr) -> Span[UInt8, origin_of(self.arena)]:
        """The key bytes of an extracted slot, as a view of the arena."""
        return Span[UInt8, origin_of(self.arena)](self.arena)[
            slot.key_off : slot.key_off + slot.key_len
        ]

    def key_bytes_of_slot(self, slot: HeapSlotStr) -> List[UInt8]:
        """The key bytes of an extracted slot, copied."""
        var out = List[UInt8](capacity=slot.key_len)
        for i in range(slot.key_len):
            out.append(self.arena[slot.key_off + i])
        return out^

    @always_inline
    def slots_equal(self, a: HeapSlotStr, b: HeapSlotStr) -> Bool:
        """True iff two extracted slots hold the same key bytes."""
        if a.key_len != b.key_len:
            keyeq_record(KEYEQ_BHEAP_SLOTS_EQUAL, a.key_len, 0, False)
            return False
        var i = 0
        var eq = True
        while i < a.key_len:
            if self.arena[a.key_off + i] != self.arena[b.key_off + i]:
                eq = False
                break
            i += 1
        keyeq_record(KEYEQ_BHEAP_SLOTS_EQUAL, a.key_len, i, eq)
        return eq


# =============================================================================
# BoundedHeapInt64PayloadDynamic
# =============================================================================


struct BoundedHeapInt64PayloadDynamic(Copyable, Movable):
    """`BoundedHeapInt64Payload` with a run-time capacity; the slot list is
    sized once at construction."""

    var slots: List[HeapSlot]
    var n_used: Int
    var capacity_n: Int

    def __init__(out self, capacity: Int):
        var sl = List[HeapSlot](capacity=capacity)
        for _ in range(capacity):
            sl.append(HeapSlot(Int64(0), Int64(0)))
        self.slots = sl^
        self.n_used = 0
        self.capacity_n = capacity

    @always_inline
    def capacity(self) -> Int:
        return self.capacity_n

    @always_inline
    def size(self) -> Int:
        return self.n_used

    @always_inline
    def _percolate_up(mut self, start_idx: Int):
        var i = start_idx
        while i > 0:
            var parent = (i - 1) // 2
            if _slot_worse(self.slots[i], self.slots[parent]):
                var tmp = self.slots[i]
                self.slots[i] = self.slots[parent]
                self.slots[parent] = tmp
                i = parent
            else:
                return

    @always_inline
    def _percolate_down(mut self, start_idx: Int):
        var i = start_idx
        while True:
            var left = 2 * i + 1
            var right = 2 * i + 2
            var largest = i
            if left < self.n_used and _slot_worse(self.slots[left], self.slots[largest]):
                largest = left
            if right < self.n_used and _slot_worse(self.slots[right], self.slots[largest]):
                largest = right
            if largest == i:
                return
            var tmp = self.slots[i]
            self.slots[i] = self.slots[largest]
            self.slots[largest] = tmp
            i = largest

    @always_inline
    def push(mut self, key: Int64, payload_row_id: Int64):
        """As `BoundedHeapInt64Payload.push`. A capacity of 0 keeps nothing."""
        if self.n_used < self.capacity_n:
            self.slots[self.n_used] = HeapSlot(key, payload_row_id)
            self.n_used = self.n_used + 1
            self._percolate_up(self.n_used - 1)
        elif self.n_used > 0 and _key_beats(key, payload_row_id, self.slots[0]):
            self.slots[0] = HeapSlot(key, payload_row_id)
            self._percolate_down(0)

    @always_inline
    def peek_root(self) -> HeapSlot:
        return self.slots[0]

    def extract_sorted(mut self) -> List[HeapSlot]:
        """Drain the heap into ascending key order."""
        var out = List[HeapSlot](capacity=self.n_used)
        while self.n_used > 0:
            out.append(self.slots[0])
            self.n_used = self.n_used - 1
            if self.n_used > 0:
                self.slots[0] = self.slots[self.n_used]
                self._percolate_down(0)
        var rev = List[HeapSlot](capacity=len(out))
        for i in range(len(out) - 1, -1, -1):
            rev.append(out[i])
        return rev^
