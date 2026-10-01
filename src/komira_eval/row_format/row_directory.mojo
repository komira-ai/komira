# =============================================================================
# row_directory.mojo — shared open-addressing directory for the row-format family
# =============================================================================
#
# Shared by `RowHashAggTable` (row_block.mojo) and the row join-build and
# row distinct tables. All three slow-path row tables maintain the SAME
# open-addressing slot directory over a byte-arena `RowBlock`:
#
#   * `directory: List[Int]`  — slot -> row-index table; `-1` == empty slot.
#   * `capacity_mask: Int`    — power-of-2 mask (== capacity - 1); `0` == empty.
#   * pow2 growth + rehash at load factor <= 0.5.
#   * linear-probe slot mechanics (`hash & mask`, `(slot + 1) & mask`).
#
# What is SHARED (this primitive): the directory storage, the pow2 grow +
# rehash, and the slot mechanics. What stays in each caller: the per-format
# PROBE LOOP BODY — agg/distinct upsert-on-miss (insert + eq-check), join
# build append-always (insert, no eq), join probe read-only collect (eq, no
# insert). Those bodies are structurally different and are driven through the
# slot helper methods below; they are NOT unified (unifying them would require
# hash/eq callbacks through the hot loop, re-introducing the wildcard-origin /
# fn-ptr hazard).
#
# Encapsulation: this struct owns only `List[Int]` + `Int` (no UnsafePointer,
# no wildcard origin). The rehash hashes rows via the existing free function
# `_hash_row_bytes[ro](ref [ro] RowBlock, row, key_stride)` — a concrete
# origin-poly accessor — so the byte-arena pointer never crosses a module
# boundary and no callback is needed. slab-safe: a `List[Int]` field is the
# canonical heap-owning Movable field that ASAP-destruction tracks correctly.
#
# A cross-boundary column<->row hash-substrate share is NOT viable (the two
# are structurally disjoint).
#
# References:
#   * `_hash_row_bytes` / `_row_bytes_equal`: row_block.mojo (already-shared
#     free fns; not duplicated — only the directory machinery was).
# =============================================================================

from komira_eval.row_format.row_block import RowBlock, _hash_row_bytes


struct RowDirectory(Movable, Deinitable):
    """Open-addressing slot directory shared by the slow-path row tables.

    Owns the `slot -> row-index` table and the power-of-2 probe mask. The
    table holds row indices into a separately-owned byte-arena `RowBlock`;
    `-1` marks an empty slot. Capacity is always a power of two and grows to
    keep the load factor <= 0.5.

    The owning table drives the probe loop itself (insert-on-miss vs
    append-always vs read-only-collect differ per format) using the slot
    helpers (`slot_for`, `next_slot`, `get`, `set`, `is_empty`); the directory
    owns only the slot mechanics + grow/rehash.

    Fields:
        directory:     slot -> row index (`-1` == empty). `len == capacity`.
        capacity_mask: power-of-2 mask (== capacity - 1). `0` == uninitialized.
    """

    var directory: List[Int]
    var capacity_mask: Int

    def __init__(out self):
        """Empty-shell ctor; caller `reserve`s (or `ensure_cap`s) before use."""
        self.directory = List[Int]()
        self.capacity_mask = 0

    @always_inline
    def is_initialized(self) -> Bool:
        """True once the directory has been sized (a non-zero mask)."""
        return self.capacity_mask != 0

    @always_inline
    def capacity(self) -> Int:
        """Current slot capacity (== `capacity_mask + 1`; `1` when empty)."""
        return self.capacity_mask + 1

    def reserve(mut self, estimated_entries: Int):
        """(Re)allocate the directory to hold `estimated_entries` at load
        factor <= 0.5 (capacity = next pow2 >= 2 * estimated, min 16). All
        slots are reset to empty (`-1`). Discards any existing contents — use
        only for the initial sizing of an empty table.
        """
        var dir_cap = 16
        while dir_cap < estimated_entries * 2:
            dir_cap = dir_cap * 2
        var new_dir = List[Int](capacity=dir_cap)
        for _ in range(dir_cap):
            new_dir.append(-1)
        self.directory = new_dir^
        self.capacity_mask = dir_cap - 1

    def ensure_cap[
        ro: Origin[mut=False], //,
    ](
        mut self,
        ref [ro] rows: RowBlock,
        n_live: Int,
        key_stride: Int,
    ) raises:
        """Ensure capacity >= `2 * n_live` (load factor <= 0.5), rehashing all
        currently-indexed entries at the new mask.

        Rows are re-hashed via the free function `_hash_row_bytes(rows, row,
        key_stride)` — the byte-arena pointer is derived internally by that
        accessor (concrete origin `ro`), so no callback / pointer crosses the
        boundary. If the table was never sized this auto-initializes it AND
        indexes every row `rows` already holds.

        ⛔ THE ROWS A NEVER-SIZED DIRECTORY IS HANDED MUST BE INDEXED. A SHELL table rebuilt from a spilled group-row image
        (`RowHashAggTable.from_spilled_group_rows`) holds its group rows with the
        directory left EMPTY, and the grace-hash repartition then `combine`s the
        other sources INTO such a shell. This arm used to `reserve` an empty
        directory and return, so every key the shell already held was invisible
        to the probe and each matching key from another source was inserted
        AGAIN: `sum(v) ... GROUP BY k` answered TWO rows for a key present in
        both a spilled run and the surviving table (MEASURED: k=0 -> 5 and 10
        where the answer is 15). A fresh table holds no rows, so this is a no-op
        for every other caller.

        Parameters:
            ro: Origin of the borrowed row byte-arena (concrete, not wildcard).
        """
        if self.capacity_mask == 0:
            var n_have = rows.n_rows
            var want = n_live if n_live > n_have else n_have
            self.reserve(want if want > 16 else 16)
            for row in range(n_have):
                var h = _hash_row_bytes(rows, row, key_stride)
                var slot = Int(h) & self.capacity_mask
                while self.directory[slot] != -1:
                    slot = (slot + 1) & self.capacity_mask
                self.directory[slot] = row
            return
        var cap = self.capacity_mask + 1
        if n_live * 2 <= cap:
            return
        var new_cap = cap
        while new_cap < n_live * 2 or new_cap < 16:
            new_cap = new_cap * 2 if new_cap > 0 else 16
        if new_cap == cap:
            return
        var new_dir = List[Int](capacity=new_cap)
        for _ in range(new_cap):
            new_dir.append(-1)
        var new_mask = new_cap - 1
        # Rehash every non-empty old slot into the new directory.
        for old_slot in range(cap):
            var row = self.directory[old_slot]
            if row == -1:
                continue
            var h = _hash_row_bytes(rows, row, key_stride)
            var slot = Int(h) & new_mask
            while new_dir[slot] != -1:
                slot = (slot + 1) & new_mask
            new_dir[slot] = row
        self.directory = new_dir^
        self.capacity_mask = new_mask

    @always_inline
    def slot_for(self, h: UInt64) -> Int:
        """Initial probe slot for a hash value (`hash & mask`)."""
        return Int(h) & self.capacity_mask

    @always_inline
    def next_slot(self, slot: Int) -> Int:
        """Next linear-probe slot (`(slot + 1) & mask`)."""
        return (slot + 1) & self.capacity_mask

    @always_inline
    def get(self, slot: Int) -> Int:
        """Row index stored at `slot` (`-1` if empty)."""
        return self.directory[slot]

    @always_inline
    def is_empty(self, slot: Int) -> Bool:
        """True iff `slot` holds no row (`get(slot) == -1`)."""
        return self.directory[slot] == -1

    @always_inline
    def set(mut self, slot: Int, row: Int):
        """Record `row` at `slot`."""
        self.directory[slot] = row
