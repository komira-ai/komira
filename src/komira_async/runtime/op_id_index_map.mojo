# =============================================================================
# komira_async.runtime.op_id_index_map — OpIdIndexMap
# =============================================================================
# Streaming demux scaling: an O(n)->hash demux for the parked-frame store.
#
# An OPEN-ADDRESSED, linear-probed hash map keyed `op_id: Int64 -> index: Int`.
# It is the index-acceleration structure behind two O(n) linear scans that the
# streaming work (thousands of idle streams) would make O(n^2):
#   * `ParkedMorselSlab.take` / `.contains` (parked-frame store), and
#   * `Reactor._find_slot_idx` (the WakerSlot demux).
# Both scanned a parallel array keyed by op_id; both were scoped in-comment to
# "<100 in-flight/worker", which the streaming gap (thousands of idle streams)
# blows past. This map gives O(1) amortized lookup / insert / remove so a per-
# wakeup demux is O(1), not O(n), and a wake STORM over N parked frames is O(N),
# not O(N^2).
#
# ── WHY A PURPOSE-BUILT OPEN-ADDRESSED MAP (not stdlib Dict) ──────────────────
# `ParkedMorselSlab`'s header (and `try_pop_any_completion`'s) already document
# the reason: Mojo's stdlib `Dict` has a non-trivial copy / partial-move shape
# that interacts poorly with the Movable-only state these structures hold. This
# map is ALL POD — two parallel `List`s of trivially-Copyable scalars (Int64
# keys, Int values) plus a per-slot UInt8 state byte (EMPTY / OCCUPIED /
# TOMBSTONE). There is NO heap-owning field, NO pointer, NO origin: it is destroy-recreate-
# clean BY CONSTRUCTION. Storing it inside a `Movable` struct that itself enters
# a byte-slab is therefore safe (the destroy-recreate audit is trivially satisfied — the
# value is an index, the key is an Int64).
#
# ── PAIRING WITH SWAP-REMOVE (the O(1) removal contract) ──────────────────────
# Both callers store their payload in a DENSE array (a `List[WakerSlot]` /
# `Slab[State]` + parallel `List[Int64]` of keys) and remove via SWAP-REMOVE:
# move the LAST element into the freed slot, then pop. Swap-remove changes the
# index of AT MOST ONE other key (the element that was last and is now at the
# freed index). So the map removal contract is two O(1) ops: `remove(removed_op)`
# then `update(moved_op, freed_idx)` for the swapped-in element (skipped when the
# removed element WAS the last). This keeps the whole remove path O(1) amortized
# — a tombstone insert + at most one rehash-free key relocation — with no full
# reindex.
#
# ── ENCAPSULATION ───────────────────────────────────────────────────
# ZERO UnsafePointer in any signature; ZERO wildcard origin; ZERO
# unsafe_from_address. The public surface is `insert(op_id, idx)` /
# `lookup(op_id) -> Int (or -1)` / `remove(op_id)` / `update(op_id, idx)` /
# `len()` / `clear()` — typed scalars only. Mojo 1.0.0b1.
# =============================================================================


# Per-slot state. EMPTY = never used (a probe that hits EMPTY stops — the key is
# absent). OCCUPIED = a live (key, value). TOMBSTONE = a removed slot — a probe
# must SKIP it and keep going (it may shadow a later live key), but an insert MAY
# reuse it.
comptime _SLOT_EMPTY: UInt8 = 0
comptime _SLOT_OCCUPIED: UInt8 = 1
comptime _SLOT_TOMBSTONE: UInt8 = 2

# Initial capacity (a power of two so the index mask is `cap - 1`). Grows by
# doubling when the load factor (occupied + tombstones) crosses ~7/8.
comptime _INITIAL_CAP: Int = 16


@always_inline
def _mix_op_id(op_id: Int64) -> UInt64:
    """A cheap integer hash (a fixed-point fibonacci/`splitmix`-style finalizer)
    so monotone op_ids (the allocator hands out `OP_ID_ALLOC_BASE + k` — biased
    by 2^40 and incrementing by 1) spread across the table instead of colliding
    in one cache line. Without mixing, biased+monotone keys land in adjacent
    buckets and probe chains lengthen; mixing restores ~uniform spread."""
    var x = UInt64(op_id)
    x = (x ^ (x >> 30)) * UInt64(0xBF58476D1CE4E5B9)
    x = (x ^ (x >> 27)) * UInt64(0x94D049BB133111EB)
    x = x ^ (x >> 31)
    return x


struct OpIdIndexMap(Movable, Deinitable):
    """Open-addressed (linear-probe) `op_id: Int64 -> index: Int` map. ALL POD;
    safe across destroy-recreate by construction (no heap-owning value, no pointer, no origin).

    Used as the O(1) demux accelerator for the parked-frame store
    (`ParkedMorselSlab`) and the reactor's WakerSlot table (`Reactor._wakers`).
    The payload arrays those callers own stay dense + are mutated via swap-remove;
    this map mirrors their key->index mapping. See the module banner for the
    swap-remove removal contract.

    NOT thread-safe (each worker owns its own reactor / slab — single-pthread
    access, mirroring the structures it accelerates)."""

    # Parallel slot arrays. `_keys[i]` is the op_id, `_vals[i]` the payload index,
    # `_state[i]` the slot state. All trivially Copyable scalars => List auto-
    # synthesizes move + drop; no heap-owning element => trivially safe across destroy-recreate.
    var _keys: List[Int64]
    var _vals: List[Int]
    var _state: List[UInt8]
    var _occupied: Int  # number of OCCUPIED slots (live entries)
    var _tombstones: Int  # number of TOMBSTONE slots (removed, not yet reclaimed)
    var _cap: Int  # table capacity (power of two); mask = _cap - 1
    # Cumulative probe-step counter — a SUB-LINEARITY instrument for the scaling
    # test. Every slot a lookup/insert probe VISITS bumps
    # this. For an O(1)-amortized open-addressed map under low load, total probes
    # across N operations is O(N) (a small constant per op); a regression to a
    # linear scan would make it O(N^2). Test-only; zero hot-path cost (one Int
    # add per probe). Reset via `reset_probe_counter`.
    var _probe_steps: Int

    def __init__(out self):
        """Construct an empty map at the initial capacity."""
        self._cap = _INITIAL_CAP
        self._keys = List[Int64]()
        self._vals = List[Int]()
        self._state = List[UInt8]()
        self._occupied = 0
        self._tombstones = 0
        self._probe_steps = 0
        for _ in range(self._cap):
            self._keys.append(Int64(0))
            self._vals.append(0)
            self._state.append(_SLOT_EMPTY)

    def __init__(out self, capacity_hint: Int):
        """Construct an empty map sized for `capacity_hint` expected entries.

        Rounds the table capacity up to a power of two >= 2 * capacity_hint
        (load factor headroom), clamped to at least the initial capacity. A
        worker that knows it will park thousands of idle streams can pre-size the
        table to avoid incremental growth under a burst."""
        var want = _INITIAL_CAP
        var target = capacity_hint * 2
        while want < target:
            want = want * 2
        self._cap = want
        self._keys = List[Int64]()
        self._vals = List[Int]()
        self._state = List[UInt8]()
        self._occupied = 0
        self._tombstones = 0
        self._probe_steps = 0
        for _ in range(self._cap):
            self._keys.append(Int64(0))
            self._vals.append(0)
            self._state.append(_SLOT_EMPTY)

    @always_inline
    def len(self) -> Int:
        """Number of live entries."""
        return self._occupied

    @always_inline
    def is_empty(self) -> Bool:
        return self._occupied == 0

    @always_inline
    def capacity(self) -> Int:
        """Current table capacity (power of two). Test / introspection."""
        return self._cap

    def _slot_for_lookup(self, op_id: Int64) -> Int:
        """Probe for `op_id`. Returns the OCCUPIED slot index holding it, or -1
        if absent. Skips tombstones (a removed slot may shadow a live key further
        down the probe chain) and stops at the first EMPTY (the key cannot be
        beyond an EMPTY slot — open addressing never leaves a gap before a key)."""
        var mask = self._cap - 1
        var i = Int(_mix_op_id(op_id) & UInt64(mask))
        var probes = 0
        while probes < self._cap:
            var st = self._state[i]
            if st == _SLOT_EMPTY:
                return -1
            if st == _SLOT_OCCUPIED and self._keys[i] == op_id:
                return i
            i = (i + 1) & mask
            probes += 1
        return -1

    @always_inline
    def lookup(self, op_id: Int64) -> Int:
        """Return the payload index mapped to `op_id`, or -1 if absent. O(1)
        amortized."""
        var slot = self._slot_for_lookup(op_id)
        if slot < 0:
            return -1
        return self._vals[slot]

    @always_inline
    def reset_probe_counter(mut self):
        """Zero the cumulative probe-step counter (test instrument)."""
        self._probe_steps = 0

    @always_inline
    def probe_steps(self) -> Int:
        """Cumulative probe steps since construction / last reset (test
        instrument for the sub-linearity assertion). See `_probe_steps`."""
        return self._probe_steps

    def probe_lookup(mut self, op_id: Int64) -> Int:
        """Identical to `lookup` but COUNTS each slot the probe visits into
        `_probe_steps`. The sub-linearity test drives N
        lookups through this and asserts total probes is O(N), not O(N^2). The
        production hot path uses the un-instrumented `lookup` (zero counter
        cost)."""
        var mask = self._cap - 1
        var i = Int(_mix_op_id(op_id) & UInt64(mask))
        var probes = 0
        while probes < self._cap:
            self._probe_steps += 1
            var st = self._state[i]
            if st == _SLOT_EMPTY:
                return -1
            if st == _SLOT_OCCUPIED and self._keys[i] == op_id:
                return self._vals[i]
            i = (i + 1) & mask
            probes += 1
        return -1

    @always_inline
    def contains(self, op_id: Int64) -> Bool:
        """Predicate: is `op_id` present? O(1) amortized."""
        return self._slot_for_lookup(op_id) >= 0

    def _grow(mut self):
        """Double the table + rehash all OCCUPIED entries (drops tombstones).
        Triggered when (occupied + tombstones) crosses ~7/8 of capacity."""
        var old_keys = self._keys^
        var old_vals = self._vals^
        var old_state = self._state^
        var old_cap = self._cap
        self._cap = old_cap * 2
        self._keys = List[Int64]()
        self._vals = List[Int]()
        self._state = List[UInt8]()
        for _ in range(self._cap):
            self._keys.append(Int64(0))
            self._vals.append(0)
            self._state.append(_SLOT_EMPTY)
        self._occupied = 0
        self._tombstones = 0
        for j in range(old_cap):
            if old_state[j] == _SLOT_OCCUPIED:
                self._insert_no_grow(old_keys[j], old_vals[j])

    def _insert_no_grow(mut self, op_id: Int64, idx: Int):
        """Insert (or overwrite) `op_id -> idx` without considering growth.
        Reuses the first TOMBSTONE on the probe chain if the key is new."""
        var mask = self._cap - 1
        var i = Int(_mix_op_id(op_id) & UInt64(mask))
        var first_tombstone = -1
        var probes = 0
        while probes < self._cap:
            var st = self._state[i]
            if st == _SLOT_EMPTY:
                # Key absent. Reuse an earlier tombstone if we passed one.
                var target = i
                if first_tombstone >= 0:
                    target = first_tombstone
                    self._tombstones -= 1
                self._keys[target] = op_id
                self._vals[target] = idx
                self._state[target] = _SLOT_OCCUPIED
                self._occupied += 1
                return
            if st == _SLOT_OCCUPIED and self._keys[i] == op_id:
                # Overwrite an existing key's index in place.
                self._vals[i] = idx
                return
            if st == _SLOT_TOMBSTONE and first_tombstone < 0:
                first_tombstone = i
            i = (i + 1) & mask
            probes += 1
        # Table full of occupied+tombstone with no EMPTY seen (should not happen
        # given the load-factor grow); reuse a tombstone if one was found.
        if first_tombstone >= 0:
            self._keys[first_tombstone] = op_id
            self._vals[first_tombstone] = idx
            self._state[first_tombstone] = _SLOT_OCCUPIED
            self._tombstones -= 1
            self._occupied += 1

    def insert(mut self, op_id: Int64, idx: Int):
        """Map `op_id -> idx`. If `op_id` is already present, its index is
        overwritten (no duplicate slot). O(1) amortized.

        Grows the table first if the live+tombstone load would exceed ~7/8 —
        keeping probe chains short."""
        # Load factor check counts tombstones (they lengthen probe chains too).
        if (self._occupied + self._tombstones + 1) * 8 >= self._cap * 7:
            self._grow()
        self._insert_no_grow(op_id, idx)

    @always_inline
    def update(mut self, op_id: Int64, idx: Int):
        """Set the payload index for an EXISTING `op_id` (the swap-remove
        relocation: the element that was at the table tail moved to `idx`). If
        `op_id` is absent this inserts it. O(1) amortized."""
        var slot = self._slot_for_lookup(op_id)
        if slot >= 0:
            self._vals[slot] = idx
        else:
            self.insert(op_id, idx)

    def remove(mut self, op_id: Int64) -> Bool:
        """Remove `op_id`'s mapping. Returns True if it was present. Leaves a
        TOMBSTONE (so a later key on the same probe chain stays reachable). O(1)
        amortized. The caller's dense payload array is compacted SEPARATELY via
        swap-remove; if the swap moved another key into the freed payload index,
        the caller calls `update(moved_op, freed_idx)` after this."""
        var slot = self._slot_for_lookup(op_id)
        if slot < 0:
            return False
        self._state[slot] = _SLOT_TOMBSTONE
        self._occupied -= 1
        self._tombstones += 1
        return True

    def clear(mut self):
        """Reset to empty (keeps current capacity)."""
        for i in range(self._cap):
            self._state[i] = _SLOT_EMPTY
        self._occupied = 0
        self._tombstones = 0
