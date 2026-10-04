# =============================================================================
# komira_table_store/key_index.mojo
#   KeyIndex / KeyChain — the in-RAM MVCC memtable + the visibility rules.
# =============================================================================
#
# The hot-row store: a key -> version-chain map, rebuildable from the WAL
# (so it holds NO durable truth). Visibility at a snapshot LSN is a pure
# function of the chain: the newest version with `commit_lsn <= S`,
# suppressed if it is a tombstone.
#
# -----------------------------------------------------------------------------
# stale-reuse / encapsulation discipline (the repository pointer rules) — NON-NEGOTIABLE
# -----------------------------------------------------------------------------
#   * The index stores version chains in a `List[KeyChain]` inside a plain
#     `List` — NOT a `Slab[T]` whose element owns an inner `List` (the
#     inner-heap-field double-free trap).
#   * `KeyChain.chain` is a plain `List[RowVersion]`.
#   * ZERO UnsafePointer in any signature; ZERO wildcard origins; the public
#     methods take/return refs + typed values only.
# =============================================================================

from komira_table_store.table_store_codec import (
    TS_OP_PUT,
    TS_OP_TOMBSTONE,
    RowVersion,
    WriteOp,
    bytes_cmp,
    bytes_eq,
)


# =============================================================================
# KeyValue — a (key, row) pair returned by scan.
# =============================================================================


@fieldwise_init
struct KeyValue(Copyable, Movable, Deinitable):
    """A visible (key, row) pair (the `scan` result element). POD-of-bytes."""

    var key: List[UInt8]
    var row: List[UInt8]


# =============================================================================
# VisibleVersion — the WINNING version of a key at a snapshot, WITH its
# commit_lsn + tombstone flag exposed (NOT collapsed to None like `visible_at`).
# =============================================================================
#
# SI-6c: a correct hot+cold dual-tier merge must be
# LWW-by-`commit_lsn` with TOMBSTONE-WINS, NOT a naive hot-else-cold fallback.
# The bare `visible_at` collapses BOTH "no version <= S" AND "the winning
# version is a tombstone" to the SAME `None`, so a merge built on it cannot tell
# a HOT tombstone (which must SUPPRESS a lower cold value) from a HOT absence
# (which must DEFER to the cold value). `VisibleVersion` keeps the winner's
# `commit_lsn` + `is_tombstone` so the merge can compare the hot vs cold winner
# by `commit_lsn` and let the higher one decide (tombstone => the key is None at
# S). `found=False` is genuine absence (no version <= S in this tier).


@fieldwise_init
struct VisibleVersion(Copyable, Movable, Deinitable):
    """The newest version of a key with `commit_lsn <= S` in ONE tier, with the
    `commit_lsn` + tombstone flag preserved for an LWW-by-`commit_lsn` merge.
    POD-of-bytes (reuse-safe trivially).

    Field layout:
      var found: Bool          — True iff a version with `commit_lsn <= S` exists
                                 in this tier (False => genuine absence; the
                                 other fields are unset).
      var commit_lsn: Int64    — the winning version's commit_lsn (its xmin).
      var is_tombstone: Bool   — True => the winning version DELETES the key.
      var row: List[UInt8]     — the winning row image (empty when tombstone).
    """

    var found: Bool
    var commit_lsn: Int64
    var is_tombstone: Bool
    var row: List[UInt8]

    @staticmethod
    def absent() -> VisibleVersion:
        """No version with `commit_lsn <= S` exists in this tier."""
        return VisibleVersion(False, Int64(-1), False, List[UInt8]())

    @always_inline
    def to_optional_row(self) -> Optional[List[UInt8]]:
        """Collapse to the `visible_at` view: the visible row, or None when
        absent OR tombstoned. Matches the existing `visible_at` semantics."""
        if not self.found or self.is_tombstone:
            return Optional[List[UInt8]](None)
        return Optional(self.row.copy())


# =============================================================================
# KeyChain — one key + its ascending-by-commit_lsn version chain.
# =============================================================================


struct KeyChain(Copyable, Movable, Deinitable):
    """One key and its immutable version chain (ascending by `commit_lsn`).
    A plain struct held in a plain `List[KeyChain]` (reuse-safe trivially — its fields
    are Copyable `List[UInt8]` + `List[RowVersion]`; List[T] requires
    T: Copyable in Mojo 1.0.0b1, so KeyChain derives Copyable from its fields,
    NOT from any pointer/ArcPointer trick — hard-ban #8 N/A).

    Field layout:
      var key: List[UInt8]
      var chain: List[RowVersion]   — ascending by commit_lsn; append-only.
    """

    var key: List[UInt8]
    var chain: List[RowVersion]

    def __init__(out self, var key: List[UInt8]):
        self.key = key^
        self.chain = List[RowVersion]()

    def append_version(mut self, var v: RowVersion):
        """Append a version. The WAL replays + the live commit fold are both
        ascending by commit_lsn (the slot sequence is monotone gapless), so a
        plain append preserves the ascending invariant — no sort needed."""
        self.chain.append(v^)

    def visible_at(self, snapshot: Int64) -> Optional[List[UInt8]]:
        """The row visible at snapshot LSN `S`: the LAST chain entry with
        `commit_lsn <= S`. None if (a) no such entry exists (the key did not
        exist as of `S`) or (b) that entry is a tombstone (deleted as of `S`).
        Linear scan from the tail (chains are short in the correctness slice;
        a faster build would use binary search)."""
        var i = len(self.chain) - 1
        while i >= 0:
            ref v = self.chain[i]
            if v.commit_lsn <= snapshot:
                if v.is_tombstone:
                    return Optional[List[UInt8]](None)
                return Optional(v.row.copy())
            i -= 1
        return Optional[List[UInt8]](None)

    def visible_version_at(self, snapshot: Int64) -> VisibleVersion:
        """The WINNING version at snapshot `S` (the LAST chain entry with
        `commit_lsn <= S`) WITH its `commit_lsn` + tombstone flag preserved —
        the LWW-merge primitive (SI-6c). Unlike `visible_at`, a tombstone winner
        returns `found=True, is_tombstone=True` (NOT None), so a dual-tier merge
        can let a hot tombstone SUPPRESS a lower cold value. `found=False` only
        when NO chain entry has `commit_lsn <= S` (genuine absence in this
        tier)."""
        var i = len(self.chain) - 1
        while i >= 0:
            ref v = self.chain[i]
            if v.commit_lsn <= snapshot:
                return VisibleVersion(
                    True, v.commit_lsn, v.is_tombstone, v.row.copy()
                )
            i -= 1
        return VisibleVersion.absent()


# =============================================================================
# KeyIndex — the sorted-by-key list of chains (memtable).
# =============================================================================


struct KeyIndex(Movable, Deinitable):
    """The in-RAM memtable: a `List[KeyChain]` kept sorted by key (byte-
    lexicographic), so `scan(lo, hi)` is a bounded walk and `chain_for` is a
    binary search. Rebuildable from the WAL — holds no durable truth.

    A faster build would swap the sorted `List` + binary search for a skiplist /
    B-tree; for the CORRECTNESS slice a sorted `List` is sufficient and keeps
    the slice free of a net-new concurrent index primitive.

    Field layout:
      var entries: List[KeyChain]   — sorted ascending by key; reuse-safe trivially.
    """

    var entries: List[KeyChain]

    def __init__(out self):
        self.entries = List[KeyChain]()

    def _find_idx(self, key: List[UInt8]) -> Int:
        """Binary search for `key`'s chain index, or -1 if absent."""
        var lo = 0
        var hi = len(self.entries) - 1
        while lo <= hi:
            var mid = (lo + hi) // 2
            var c = bytes_cmp(self.entries[mid].key, key)
            if c == 0:
                return mid
            if c < 0:
                lo = mid + 1
            else:
                hi = mid - 1
        return -1

    def _lower_bound(self, key: List[UInt8]) -> Int:
        """First index whose key is >= `key` (insertion point / scan start)."""
        var lo = 0
        var hi = len(self.entries)
        while lo < hi:
            var mid = (lo + hi) // 2
            if bytes_cmp(self.entries[mid].key, key) < 0:
                lo = mid + 1
            else:
                hi = mid
        return lo

    def _chain_idx_or_insert(mut self, key: List[UInt8]) -> Int:
        """Index of `key`'s chain, creating an empty chain at the sorted
        position if absent. Returns the (now-existing) index."""
        var pos = self._lower_bound(key)
        if pos < len(self.entries) and bytes_eq(self.entries[pos].key, key):
            return pos
        # Insert a fresh empty chain at `pos` (keep the list sorted). Build a
        # new list — the correctness slice is small; a faster build would use a
        # structure with O(log n) insert.
        var rebuilt = List[KeyChain]()
        for i in range(pos):
            rebuilt.append(self.entries[i].copy())
        rebuilt.append(KeyChain(key.copy()))
        for i in range(pos, len(self.entries)):
            rebuilt.append(self.entries[i].copy())
        self.entries = rebuilt^
        return pos

    def apply_write(mut self, commit_lsn: Int64, w: WriteOp):
        """Fold one committed write into the index at `commit_lsn` (the won
        commit slot). Appends a RowVersion to the key's chain (ascending —
        commit_lsn is monotone across the WAL)."""
        var idx = self._chain_idx_or_insert(w.key)
        var is_tomb = w.op == TS_OP_TOMBSTONE
        self.entries[idx].append_version(
            RowVersion(commit_lsn, is_tomb, w.row.copy())
        )

    def apply_write_set(mut self, commit_lsn: Int64, write_set: List[WriteOp]):
        """Fold an entire committed write-set at `commit_lsn` (in chunk order
        — the txn already deduped by key, so order within the set is fine)."""
        for i in range(len(write_set)):
            self.apply_write(commit_lsn, write_set[i])

    def visible_at(
        self, key: List[UInt8], snapshot: Int64
    ) -> Optional[List[UInt8]]:
        """The row visible for `key` at snapshot `S`, or None if invisible
        (absent or tombstoned as of `S`)."""
        var idx = self._find_idx(key)
        if idx < 0:
            return Optional[List[UInt8]](None)
        return self.entries[idx].visible_at(snapshot)

    def visible_version_at(
        self, key: List[UInt8], snapshot: Int64
    ) -> VisibleVersion:
        """The WINNING hot version of `key` at snapshot `S`, with its
        `commit_lsn` + tombstone flag preserved (SI-6c LWW-merge primitive). A
        key absent from the memtable returns `VisibleVersion.absent()` (NOT a
        tombstone) — the dual-tier merge then DEFERS to the cold tier instead of
        treating the miss as a delete."""
        var idx = self._find_idx(key)
        if idx < 0:
            return VisibleVersion.absent()
        return self.entries[idx].visible_version_at(snapshot)

    def scan_visible(
        self, lo: List[UInt8], hi: List[UInt8], snapshot: Int64
    ) raises -> List[KeyValue]:
        """Range scan `[lo, hi)` at snapshot `S`: the visible (key, row) pairs
        in ascending key order. Tombstoned / invisible keys are suppressed.
        Half-open: `lo` inclusive, `hi` exclusive."""
        var out = List[KeyValue]()
        var start = self._lower_bound(lo)
        var i = start
        while i < len(self.entries):
            ref c = self.entries[i]
            # Stop at the first key >= hi (half-open upper bound).
            if bytes_cmp(c.key, hi) >= 0:
                break
            var v = c.visible_at(snapshot)
            if v:
                out.append(KeyValue(c.key.copy(), v.value().copy()))
            i += 1
        return out^

    def scan_visible_from(
        self, lo: List[UInt8], snapshot: Int64
    ) raises -> List[KeyValue]:
        """Range scan `[lo, +inf)` at snapshot `S`: the visible (key, row) pairs
        from `lo` (inclusive) to the END of the sorted index, ascending. This is
        the UNBOUNDED-UPPER scan mode the SQL face needs for a full scan and for
        open-ended `>=`/`>` ranges (the storage layer owns +inf semantics; the
        SQL layer must NOT synthesize a fixed-length max byte-string, which
        silently drops TEXT keys longer/larger than the sentinel). Identical to
        `scan_visible` minus the `hi` upper-bound test."""
        var out = List[KeyValue]()
        var i = self._lower_bound(lo)
        while i < len(self.entries):
            ref c = self.entries[i]
            var v = c.visible_at(snapshot)
            if v:
                out.append(KeyValue(c.key.copy(), v.value().copy()))
            i += 1
        return out^
