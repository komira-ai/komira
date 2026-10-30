# =============================================================================
# group_table -- the hash table of one worker of the grouped aggregation sink
# =============================================================================
#
# Open addressing over groups kept in insertion order. A group is its key (one
# 64-bit cell and one NULL flag per key column) and one `AggCell` per aggregate
# (`agg_fold`: a count and an exact 128-bit integer). Two keys are the same
# group when every cell and every flag agrees, so NULL is a key value of its
# own: all rows whose key is NULL form one group, and a NULL is never equal to
# a stored cell (the cell under a NULL flag is always zero, and the flag is
# compared first).
#
# Why this table and not `komira_op_agg_hash`: its entries hold Int64 keys and
# 64-bit or float accumulator slots, with no flag for a NULL key and no exact
# 128-bit fold, which a DECIMAL128 sum needs (`agg_fold`).
#
# Memory is charged in steps. The capacity doubles when the table is full, and
# the doubling is charged to the worker's `WorkerReservation` BEFORE any list
# grows: `find_or_insert` returns -1 and allocates nothing when the segment
# pool denies the step, and `denied_bytes` says how many bytes were asked for.
# The charge per group covers its key cells, flags, hash, cells and two
# 4-byte slots (the slot directory is kept at most half full).

from std.sys import size_of

from .agg_fold import AggCell
from .segment_pool import WorkerReservation

comptime _FIRST_CAPACITY: Int = 64
comptime _EMPTY_SLOT: Int32 = -1


@always_inline
def mix64(x: UInt64) -> UInt64:
    """A 64-bit finalizer (splitmix64): every input bit moves every output bit."""
    var z = x + UInt64(0x9E3779B97F4A7C15)
    z = (z ^ (z >> 30)) * UInt64(0xBF58476D1CE4E5B9)
    z = (z ^ (z >> 27)) * UInt64(0x94D049BB133111EB)
    return z ^ (z >> 31)


def hash_key(ref cells: List[Int64], ref nulls: List[UInt8]) -> UInt64:
    """The hash of a key: a function of the cells and flags alone, so the same
    key hashes the same in every worker."""
    var h = UInt64(0x2545F4914F6CDD1D)
    for i in range(len(cells)):
        var v = UInt64(0xD1B54A32D192ED03)
        if nulls[i] == 0:
            v = UInt64(cells[i].cast[DType.uint64]())
        h = mix64(h ^ v)
    return h


struct GroupTable(Movable):
    var nk: Int
    var na: Int
    var n: Int
    var capacity: Int
    var keys: List[Int64]
    var nulls: List[UInt8]
    var hashes: List[UInt64]
    var cells: List[AggCell]
    var _slots: List[Int32]
    var _per_group: Int
    var denied_bytes: Int

    def __init__(out self, num_keys: Int, num_aggs: Int):
        self.nk = num_keys
        self.na = num_aggs
        self.n = 0
        self.capacity = 0
        self.keys = List[Int64]()
        self.nulls = List[UInt8]()
        self.hashes = List[UInt64]()
        self.cells = List[AggCell]()
        self._slots = List[Int32]()
        self._per_group = (
            num_keys * 9 + 8 + num_aggs * size_of[AggCell]() + 8
        )
        self.denied_bytes = 0

    def per_group_bytes(self) -> Int:
        """The bytes charged for each group of capacity."""
        return self._per_group

    def _matches(
        self, g: Int, ref cells: List[Int64], ref nulls: List[UInt8]
    ) -> Bool:
        var base = g * self.nk
        for i in range(self.nk):
            if self.nulls[base + i] != nulls[i]:
                return False
            if nulls[i] == 0 and self.keys[base + i] != cells[i]:
                return False
        return True

    def _grow(mut self, mut res: WorkerReservation) -> Bool:
        var new_cap = _FIRST_CAPACITY if self.capacity == 0 else (
            self.capacity * 2
        )
        var step = (new_cap - self.capacity) * self._per_group
        if not res.try_grow(step):
            self.denied_bytes = step
            return False
        self.keys.reserve(new_cap * self.nk)
        self.nulls.reserve(new_cap * self.nk)
        self.hashes.reserve(new_cap)
        self.cells.reserve(new_cap * self.na)
        self.capacity = new_cap
        var slots = List[Int32](capacity=new_cap * 2)
        for _ in range(new_cap * 2):
            slots.append(_EMPTY_SLOT)
        var mask = new_cap * 2 - 1
        for g in range(self.n):
            var s = Int(self.hashes[g]) & mask
            while slots[s] != _EMPTY_SLOT:
                s = (s + 1) & mask
            slots[s] = Int32(g)
        self._slots = slots^
        return True

    def find_or_insert(
        mut self,
        h: UInt64,
        ref cells: List[Int64],
        ref nulls: List[UInt8],
        mut res: WorkerReservation,
    ) -> Int:
        """The index of the group of the key (`cells`, `nulls`) with hash `h`,
        made if new. -1 when a new group needed memory the pool denied."""
        if self.capacity > 0:
            var mask = self.capacity * 2 - 1
            var s = Int(h) & mask
            while self._slots[s] != _EMPTY_SLOT:
                var g = Int(self._slots[s])
                if self.hashes[g] == h and self._matches(g, cells, nulls):
                    return g
                s = (s + 1) & mask
        if self.n == self.capacity:
            if not self._grow(res):
                return -1
        var mask = self.capacity * 2 - 1
        var s = Int(h) & mask
        while self._slots[s] != _EMPTY_SLOT:
            s = (s + 1) & mask
        var g = self.n
        self._slots[s] = Int32(g)
        self.n += 1
        for i in range(self.nk):
            self.keys.append(cells[i])
            self.nulls.append(nulls[i])
        self.hashes.append(h)
        for _ in range(self.na):
            self.cells.append(AggCell())
        return g
