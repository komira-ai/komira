# =============================================================================
# ptn_dense_directory -- a key-agnostic open-addressing partition directory
# =============================================================================
#
# `PTNDenseDirectory` maps a partition to a dense index 0, 1, 2, ... without
# ever seeing the key: it stores only `salt | dense_idx` words and each
# entry's hash. The caller hashes the key, walks the probe
# (`probe_start` / `advance`), tests its own typed key columns for equality on
# every slot whose salt matches, and either accepts the slot's dense index or
# calls `insert_new(hash)`. Composite and STRING keys are therefore the
# caller's business (`part_key_block`), and the directory is written once.
#
# The probe is a salt-derived odd stride over a power-of-two table; the table
# doubles at a 2/3 load and is rebuilt from the cached hashes (dense indices
# never move).
# =============================================================================


comptime _PTN_INITIAL_CAPACITY: Int = 256
comptime _PTN_EMPTY_SLOT: UInt64 = 0
# UInt64: every use shifts a UInt64 by it.
comptime _PTN_SALT_SHIFT: UInt64 = 48
comptime _PTN_IDX_MASK: UInt64 = (UInt64(1) << 48) - 1


@always_inline
def _ptn_salt_of(h: UInt64) -> UInt64:
    var s = h >> UInt64(_PTN_SALT_SHIFT)
    return s | (UInt64(1) << 15)


@always_inline
def _ptn_stride(salt: UInt64, mask: UInt64) -> UInt64:
    return (salt & mask) | 1


@fieldwise_init
struct ProbeCursor(Copyable, Movable, ImplicitlyCopyable):
    """The in-progress probe walk handed back to the caller. `probe_start(hash)`
    returns a cursor positioned at the first slot to inspect; the caller loops
    advancing while the slot is occupied + the delegated equality says
    "different key", inserting at the first empty slot."""

    var slot: UInt64
    var salt: UInt64
    var stride: UInt64
    var mask: UInt64


@fieldwise_init
struct PTNDenseDirectory(Copyable, Movable):
    """Key-type-AGNOSTIC salt-packed open-addressing directory. Stores only the
    packed (salt | dense_idx) words + a cached_hash side array; NEVER sees key
    bytes. Equality is delegated to the caller's typed key SoA."""

    var directory: List[UInt64]
    var cached_hash: List[UInt64]
    var capacity: Int
    var n_entries: Int

    @staticmethod
    def new(initial_capacity: Int = _PTN_INITIAL_CAPACITY) -> PTNDenseDirectory:
        var cap = 1
        while cap < initial_capacity:
            cap = cap * 2
        var dir = List[UInt64](capacity=cap)
        for _ in range(cap):
            dir.append(_PTN_EMPTY_SLOT)
        return PTNDenseDirectory(
            directory=dir^,
            cached_hash=List[UInt64](),
            capacity=cap,
            n_entries=0,
        )

    @always_inline
    def size(self) -> Int:
        return self.n_entries

    @always_inline
    def probe_start(self, hash: UInt64) -> ProbeCursor:
        """Begin a probe walk for `hash`. Returns a cursor at the first slot."""
        var mask = UInt64(self.capacity - 1)
        var salt = _ptn_salt_of(hash)
        var stride = _ptn_stride(salt, mask)
        return ProbeCursor(slot=hash & mask, salt=salt, stride=stride, mask=mask)

    @always_inline
    def slot_is_empty(self, cur: ProbeCursor) -> Bool:
        return self.directory[Int(cur.slot)] == _PTN_EMPTY_SLOT

    @always_inline
    def slot_salt_matches(self, cur: ProbeCursor) -> Bool:
        var word = self.directory[Int(cur.slot)]
        return (word >> UInt64(_PTN_SALT_SHIFT)) == cur.salt

    @always_inline
    def slot_dense_idx(self, cur: ProbeCursor) -> Int:
        return Int(self.directory[Int(cur.slot)] & _PTN_IDX_MASK)

    @always_inline
    def advance(self, cur: ProbeCursor) -> ProbeCursor:
        var nxt = cur
        nxt.slot = (cur.slot + cur.stride) & cur.mask
        return nxt

    @always_inline
    def would_grow(self) -> Bool:
        """True if inserting one more entry crosses the ~0.67 load threshold."""
        return self.n_entries >= (self.capacity * 2) // 3

    def grow(mut self):
        """Double capacity + rehash directory-only off cached_hash (dense indices
        are stable — never moved)."""
        var new_cap = self.capacity * 2
        var new_dir = List[UInt64](capacity=new_cap)
        for _ in range(new_cap):
            new_dir.append(_PTN_EMPTY_SLOT)
        self.directory = new_dir^
        self.capacity = new_cap
        var mask = UInt64(new_cap - 1)
        for g in range(self.n_entries):
            var h = self.cached_hash[g]
            var salt = _ptn_salt_of(h)
            var stride = _ptn_stride(salt, mask)
            var slot = h & mask
            var packed = (salt << UInt64(_PTN_SALT_SHIFT)) | UInt64(g)
            while self.directory[Int(slot)] != _PTN_EMPTY_SLOT:
                slot = (slot + stride) & mask
            self.directory[Int(slot)] = packed

    def insert_new(mut self, hash: UInt64) -> Int:
        """Assign the next dense index for `hash`, record cached_hash, write the
        packed directory word at the first empty slot on the probe walk. Returns
        the new dense index. Caller has already confirmed (delegated equality)
        the key is not present. Grows BEFORE insert if at threshold."""
        if self.would_grow():
            self.grow()
        var dense_idx = self.n_entries
        self.cached_hash.append(hash)
        self.n_entries += 1
        var mask = UInt64(self.capacity - 1)
        var salt = _ptn_salt_of(hash)
        var stride = _ptn_stride(salt, mask)
        var slot = hash & mask
        var packed = (salt << UInt64(_PTN_SALT_SHIFT)) | UInt64(dense_idx)
        while self.directory[Int(slot)] != _PTN_EMPTY_SLOT:
            slot = (slot + stride) & mask
        self.directory[Int(slot)] = packed
        return dense_idx
