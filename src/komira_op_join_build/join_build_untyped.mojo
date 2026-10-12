# =============================================================================
# join_build_untyped -- `JoinBuildTable_Untyped`, the hash-join build and probe
# table whose key and payload layout is a runtime list of `ColDescriptor`s
# =============================================================================
#
# Storage: `ColumnFormatStorage` holds one slot per BUILD ROW (keys first, then
# payloads, by `col_idx_in_storage`); `HashDirectory` maps a key hash to the
# HEAD slot of that key's chain; `_chain_next` links the slots that share a key,
# so a probe emits one `MatchPair` per matching build row (M:N fan-out).
#
#   build_batch:  per row, skip a NULL key; hash the key columns; walk the
#                 directory (salt match, then key equality); on a miss insert a
#                 fresh chain head, on a hit allocate a slot and make it the new
#                 head of that key's chain.
#   probe_batch:  per row, skip a NULL key; hash; walk to the key's bucket and
#                 emit one `MatchPair(row, slot)` per slot of its chain.
#   read_payload_*_for: gather one payload column for a list of matches.
#
# Key semantics: a NULL key matches nothing (on either side). Float keys follow
# the query semantics' float model (every NaN equal, `-0.0 == +0.0`); see
# `join_build_untyped_cells`.
#
# Supported key and payload types: the fixed-width integer, float, date,
# timestamp and BOOL types, DECIMAL128 (both words), STRING and BINARY.
#
# No engine path constructs this table yet: the single-INT64-key joins use
# `HashJoinBuilder` (`join`) and the composite-key joins their own builder. It
# is carried, with its tests, for the untyped join route.
# =============================================================================

from komira_arrow.batch_view import BatchView
from komira_column_format.column_format_storage import (
    ColumnFormatStorage,
    ColDescriptor,
    COL_FIXED,
    DT_DATE32,
    DT_F64,
    DT_I32,
    DT_I64,
)

from .hash_directory import HashDirectory, SLOT_EMPTY
from .join_build_untyped_cells import (
    _encode_cell,
    _hash_single_col,
    _hash_storage_single_col,
    _key_eq_single_col,
    _storage_key_eq_single_col,
)
from .join_untyped_key_hash import _hash_compose


# -----------------------------------------------------------------------------
# MatchPair — per-row probe match record.
#
# Emitted by `probe_batch`; consumed by `emit_to_record_batch_columnar`
# to drain matched slot payloads + probe-side payloads into the output.
#
# Trivial POD (Copyable + Movable) so it can live in `List[MatchPair]`.
# -----------------------------------------------------------------------------


@fieldwise_init
struct MatchPair(Copyable, Movable, ImplicitlyCopyable, Deinitable):
    """Probe-side row + build-side slot pair.

    Storage fields:
        probe_row: Logical row index in the probe-side BatchView.
        build_slot: Slot index in the build-side ColumnFormatStorage.
            Always non-negative for live entries (callers do not
            construct MatchPair for misses).
    """

    var probe_row: Int
    var build_slot: Int


struct JoinBuildTable_Untyped(Movable, Deinitable):
    """Runtime-ColDescriptor-dispatched hash-join build table.

    Layout convention: the `storage`'s ColDescriptor list interleaves
    keys + payloads (keys first, payloads after) by
    `col_idx_in_storage`. `key_descriptors[k].col_idx_in_storage == k`;
    `payload_descriptors[p].col_idx_in_storage == n_keys + p`. This
    keeps the storage layout uniform and the per-DType dispatch loops
    use the same per-col path for both keys and payloads.

    Build and probe loops: see the module header.
    """

    var key_descriptors: List[ColDescriptor]
    """Per-key-col metadata; layout governs the build/probe per-row
    hashing + key-equality loops."""

    var payload_descriptors: List[ColDescriptor]
    """Per-payload-col metadata; layout governs the slot-side gather
    on probe-side output."""

    var storage: ColumnFormatStorage
    """Per-col hash-slot store. Holds both keys + payloads under one
    descriptor list (keys first, payloads after, by `col_idx_in_storage`)."""

    var directory: HashDirectory
    """SoA hash directory; salt + slot per bucket."""

    var has_duplicate_keys: Bool
    """True iff any build-side row hashed to a slot whose keys already
    matched a prior row. Used by JOIN-INNER vs JOIN-LEFT semantics
    downstream."""

    # build-side key fanout (per-key chain walker):
    # `_chain_next[slot]` is the NEXT slot index in the same-key chain,
    # or SLOT_EMPTY (-1) for the chain tail. The HashDirectory bucket
    # holds the HEAD slot of the chain for a given key; every build row
    # sharing that key gets its OWN storage slot, linked head-first via
    # `_chain_next`. PROBE walks the chain emitting one MatchPair per
    # slot, restoring full M:N fan-out (one match per build row sharing
    # the probe key) instead of the prior FIRST-match-only behavior.
    #
    # This is an OWNED `List[Int32]` (no UnsafePointer, no wildcard
    # origin) parallel to the storage slots; `_chain_next.__len__()`
    # tracks 1:1 with `storage.n_slots` (each new slot appends one entry).
    var _chain_next: List[Int32]
    """Per-slot next-in-chain link (-1 = chain tail). Parallel to storage
    slots; index by slot, length tracks storage.n_slots."""

    var _slot_hashes: List[UInt64]
    """JOIN-HASH-STORE: the composite key hash that
    PLACED each build slot, kept alongside the slot. `_slot_hashes[s]` is the
    exact `h` that `_build_one_row` probed with when it allocated slot `s`, so
    `_rehash_directory` rebuilds the directory AND the per-key chains WITHOUT
    touching a single key byte.

    WHY THE STORED HASH IS THE AUTHORITATIVE ONE — this is a WRONG-ANSWER fix,
    not only a perf lever. `_hash_storage_row` is NOT a faithful reproduction of
    `_hash_row`: a NEGATIVE DT_I16 / DT_I8 key is hashed SIGN-EXTENDED on the
    batch side (`_hash_u64(UInt64(Int(v)))`, Int16 -30000 ->
    0xFFFF_FFFF_FFFF_8AD0) but read back UNSIGNED out of its two's-complement
    slot cell (`read_slot_u16` -> 35536). Re-deriving therefore moved every
    chain head to a bucket the probe's sign-extended hash never visits, so
    `probe_batch` DROPPED every match for that key — a smaller, plausible join
    result with no crash. Guarded by
    `tests/test_join_hash_store_grow.mojo`. For every other key dtype the
    two hashes are equal, so bucket placement, chain order and probe order are
    UNCHANGED — this is a no-op for every corpus shape.

    PREFIX INVARIANT — read this before touching any slot-allocating loop. This
    is a FOURTH index space over the storage slots (alongside the slot-indexed
    key/payload columns, the directory's bucket space, and the slot-indexed
    `_chain_next` links), and it is maintained as a valid PREFIX, not a
    full-length parallel array:

        len(self._slot_hashes) <= self.storage.n_slots,   and
        for s < len(self._slot_hashes):  _slot_hashes[s] is slot s's hash.

    The single writer is `_note_slot_hash`, which appends ONLY when
    `len == new_slot`. A slot allocated without probing (there is no such site
    in this file today — `_alloc_slot_with_chain` is the only allocator and both
    of its callers hold `h`) would freeze the prefix rather than shift it, and
    every read past the prefix falls back to the original `_hash_storage_row`
    re-derivation. An off-by-N is not a representable state."""

    var _storage_hash_recomputes: Int
    """JOIN-HASH-STORE: count of live slots whose composite hash the rehash path
    still had to RE-DERIVE from stored key bytes (i.e. the prefix did not cover
    them). Zero for a build-probe-populated table — that is the structural
    assertion the regression test makes, since "the recompute is gone" is
    otherwise unfalsifiable. At most one per slot per rehash, never per row."""

    var _directory_rehashes: Int
    """JOIN-HASH-STORE: count of directory doublings this table has performed.
    Exists so a `_storage_hash_recomputes == 0` assertion cannot pass vacuously
    by never having grown."""

    # ─────────────────────────────────────────────────────────────────────
    # Construction
    # ─────────────────────────────────────────────────────────────────────

    def __init__(
        out self,
        var key_descriptors: List[ColDescriptor],
        var payload_descriptors: List[ColDescriptor],
        initial_capacity: Int,
    ) raises:
        """Build a JoinBuildTable_Untyped with the given key + payload
        layout.

        The combined storage layout is built by appending `key_descriptors`
        + `payload_descriptors`; per-DType cell allocation honors each
        descriptor's `dtype_tag` + `kind`.

        Args:
            key_descriptors: Per-key-col metadata. MUST have
                `col_idx_in_storage` equal to the col's 0-based index
                within key_descriptors (caller-enforced; this ctor does
                NOT renumber).
            payload_descriptors: Per-payload-col metadata. MUST have
                `col_idx_in_storage` equal to `n_keys + p` where p is
                the col's 0-based index within payload_descriptors.
            initial_capacity: Pre-allocated slot capacity. Directory is
                sized at 4x to keep load factor below 0.25 at start.
        """
        # Snapshot lengths BEFORE moving the lists into self.
        var n_keys = key_descriptors.__len__()
        var n_payload = payload_descriptors.__len__()

        # Build the combined storage layout (keys first, payloads after).
        # We READ from the local lists BEFORE moving them into self.
        var combined = List[ColDescriptor]()
        for k in range(n_keys):
            combined.append(key_descriptors[k])
        for p in range(n_payload):
            combined.append(payload_descriptors[p])

        # Allocate per-col storage. ColumnFormatStorage.alloc takes
        # ownership of the layout list.
        self.storage = ColumnFormatStorage.alloc(combined^, initial_capacity)

        # Directory: 4x initial capacity keeps load factor below 0.25
        # initially.
        self.directory = HashDirectory(initial_capacity * 4)

        # Move the descriptor lists into self LAST (var-param contract:
        # all reads from local lists happen before move).
        self.key_descriptors = key_descriptors^
        self.payload_descriptors = payload_descriptors^
        self.has_duplicate_keys = False
        # Per-slot chain link, grown 1:1 with storage slots.
        self._chain_next = List[Int32]()

        # JOIN-HASH-STORE: the per-slot placing hash. Reserved to the initial
        # slot capacity so the first `initial_capacity` slots append without a
        # realloc; the List's own doubling takes over after that (one 8-byte
        # push per BUILD SLOT, never per probe row).
        self._slot_hashes = List[UInt64]()
        if initial_capacity > 0:
            self._slot_hashes.reserve(initial_capacity)
        self._storage_hash_recomputes = 0
        self._directory_rehashes = 0

    # ─────────────────────────────────────────────────────────────────────
    # JOIN-HASH-STORE — the per-slot placing hash.
    #
    # ONE choke point writes it (`_note_slot_hash`, reached only through
    # `_alloc_slot_with_chain`) and ONE reads it (`slot_hash`). Any future
    # slot-allocating branch must call `_note_slot_hash` as it bumps
    # `storage.n_slots`, or the prefix freezes there (correct, just slower).
    # It can NEVER misalign: the append is guarded on `len == new_slot`.
    # ─────────────────────────────────────────────────────────────────────

    @always_inline
    def _note_slot_hash(mut self, new_slot: Int, h: UInt64):
        """Record the hash that just PLACED build slot `new_slot`.

        Appends only when the prefix ends exactly at `new_slot`, so a table
        whose slots were allocated without a known hash keeps a short prefix
        instead of an off-by-N one."""
        if len(self._slot_hashes) == new_slot:
            self._slot_hashes.append(h)

    def slot_hash(self, slot: Int) raises -> UInt64:
        """The canonical directory hash of build slot `slot`.

        Returns the STORED placing hash when the prefix covers `slot`, else
        re-derives it from stored key bytes (`_hash_storage_row`) exactly as
        `_rehash_directory` did before JOIN-HASH-STORE. This is the single
        accessor any consumer must use to re-route a stored slot — a routing
        hash and the hash a later probe uses must never be able to disagree."""
        if slot < len(self._slot_hashes):
            return self._slot_hashes[slot]
        return self._hash_storage_row(slot)

    @always_inline
    def hash_cache_covered(self) -> Int:
        """JOIN-HASH-STORE: how many leading slots carry a stored placing hash.
        Equals `n_slots()` for any table populated through `build_batch`."""
        return len(self._slot_hashes)

    @always_inline
    def storage_hash_recomputes(self) -> Int:
        """JOIN-HASH-STORE: slots the rehash path still had to re-hash from
        stored key bytes. See `_storage_hash_recomputes`."""
        return self._storage_hash_recomputes

    @always_inline
    def directory_rehashes(self) -> Int:
        """JOIN-HASH-STORE: directory doublings performed. Pairs with
        `storage_hash_recomputes()` so a zero-recompute claim is falsifiable."""
        return self._directory_rehashes

    # ─────────────────────────────────────────────────────────────────────
    # Diagnostics / accessors
    # ─────────────────────────────────────────────────────────────────────

    @always_inline
    def n_keys(self) -> Int:
        """Number of key cols."""
        return self.key_descriptors.__len__()

    @always_inline
    def n_payload(self) -> Int:
        """Number of payload cols."""
        return self.payload_descriptors.__len__()

    @always_inline
    def n_slots(self) -> Int:
        """Live slot count (number of distinct build-side rows)."""
        return self.storage.n_slots

    @always_inline
    def capacity(self) -> Int:
        """Current per-col slot capacity."""
        return self.storage.capacity

    # ─────────────────────────────────────────────────────────────────────
    # Per-DType key-equality verification — file-internal probe helper.
    #
    # Compare a BatchView row's key cols against a stored slot's keys.
    # Returns True iff all key cols match byte-for-byte. Used by both
    # build_batch (to detect duplicate keys after a salt match) and
    # probe_batch (to verify a salt-match candidate is a true match).
    # ─────────────────────────────────────────────────────────────────────

    def _keys_match[
        bo: Origin[mut=False]
    ](
        self,
        batch: BatchView[bo],
        row: Int,
        slot: Int,
    ) raises -> Bool:
        """True iff the keys at (`batch`, `row`) match the keys stored
        at `slot`. Used to verify salt-match candidates.
        """
        for k in range(self.key_descriptors.__len__()):
            var desc = self.key_descriptors[k]
            if not _key_eq_single_col(self.storage, batch, row, slot, desc):
                return False
        return True

    # ──────────────────────────────────────────────────────────────────────
    # ⭐⭐ STRKEY-BULK JOIN TWIN — the join side of the lever
    # an earlier change landed on the AGGREGATE side.
    #
    # WHAT WAS WRONG. The COL_VAR_STRING / COL_VAR_BINARY probe-compare arm
    # allocated TWO `List[UInt8]` per probe that reached a compare:
    #
    #   1. a fresh `List[UInt8]` built from the BATCH cell by appending
    #      `sv.byte_at(i)` — and `byte_at` re-derives the whole
    #      `batch -> columns slab -> Column -> _data buffer` chain, plus a
    #      bounds check and a raise edge, ON EVERY BYTE;
    #   2. a second `List[UInt8]` off the STORAGE heap via
    #      `read_slot_str_bytes`, which re-resolves its own descriptor cell and
    #      then appends one byte at a time too;
    #
    # and only then ran `_bytes_eq` over the two — a THIRD per-byte loop. This
    # is O(rows), not O(build-side keys): it runs on every probe row whose salt
    # matches. `sdk/c5_inner_join_varchar` and `sdk/c5hc_inner_join_varchar`
    # are 83.6% of the entire corpus gap and both key on a
    # VARCHAR.
    #
    # THE FIX is the same two-part hoist the agg side took: resolve the batch
    # cell ONCE into a `(ptr, len)` `ByteView` (`StringView.bytes_view()`), and
    # resolve the storage cell ONCE inside `slot_str_first_diff`, which then
    # compares EIGHT BYTES PER ITERATION. It is not an approximation of the
    # byte loop — it returns the index of the FIRST differing byte, exactly the
    # index the scalar loop broke at, so the `keyeq_census` `bytes_touched`
    # statistic is preserved to the byte.
    #
    # ⚠ THE CENSUS TRIPLE IS PART OF THE CONTRACT, LENGTH-MISMATCH ARM
    # INCLUDED. `_bytes_eq(a, b)` recorded `(len(a), 0, False)` when the
    # lengths differed — and `a` was the BATCH cell, so the recorded width is
    # the BATCH length, not the stored one. Recording the stored length here
    # would silently re-base every width histogram this site feeds.
    # ──────────────────────────────────────────────────────────────────────

    # ─────────────────────────────────────────────────────────────────────
    # Per-row composite hash — read each key col from the BatchView,
    # hash each scalar, xor+rotate-mix them.
    #
    # hashes via the unified `_hash_u64` (FNV-1a) after
    # bit-reinterpreting each typed scalar to UInt64. Production hot
    # path will swap xxh3 in (Row UNTYPED D2 perf-reuse).
    # ─────────────────────────────────────────────────────────────────────

    def _hash_row[
        bo: Origin[mut=False]
    ](
        self,
        batch: BatchView[bo],
        row: Int,
    ) raises -> UInt64:
        """Compose-hash all key cols at `row`."""
        var h: UInt64 = UInt64(0)
        var n_keys = self.key_descriptors.__len__()
        for k in range(n_keys):
            var desc = self.key_descriptors[k]
            var per_col_h = _hash_single_col(batch, desc, row)
            if k == 0:
                h = per_col_h
            else:
                h = _hash_compose(h, per_col_h)
        return h

    # ─────────────────────────────────────────────────────────────────────
    # Capacity management — amortized-doubling grow.
    #
    # Triggered on insert when the directory would exceed its load
    # factor OR when storage is full. Storage growth is constant-time
    # per slot already-occupied (via ColumnFormatStorage.grow_to's
    # copy-on-grow path); directory growth rehashes from stored keys.
    # ─────────────────────────────────────────────────────────────────────

    def _grow_if_needed(mut self) raises:
        """Grow storage + directory if either is at threshold.

        Storage grows to 2x current capacity via
        `ColumnFormatStorage.grow_to`; the live `n_slots` bytes are
        preserved via copy-on-grow.

        Directory grows to 2x current capacity via reset_doubled +
        re-insertion of all stored keys (rehashed via `_hash_row` over
        the stored key cols — same hash kernels used at build).
        """
        # Storage full?
        if self.storage.n_slots >= self.storage.capacity:
            var new_cap = self.storage.capacity * 2
            if new_cap < 16:
                new_cap = 16
            self.storage.grow_to(new_cap)

        # Directory at threshold?
        if self.directory.would_grow_on_insert():
            self._rehash_directory()

    def _rehash_directory(mut self) raises:
        """Double directory capacity + rebuild the directory AND the
        per-key chains from the stored slots.

        With build-side key fan-out, the directory holds ONE
        bucket per distinct key (the chain head), and `_chain_next` links
        same-key slots head-first. A naive "insert every slot" rehash
        would register every chain member as its own directory head and
        destroy the chain invariant. Instead we re-derive both structures
        from scratch: for each slot in index order, hash its stored key
        and probe the doubled directory — a fresh key becomes a new chain
        head (chain tail link), a duplicate key links onto the existing
        head (the slot becomes the new head). This is order-independent
        and produces correct chains regardless of the prior chain order.

        Slot indices are stable across rehash (storage does not move
        slots), so rewriting `_chain_next[s]` in place is safe.

        JOIN-HASH-STORE: each slot is re-placed at the hash
        that PLACED it, read straight out of `_slot_hashes` — no key-byte reads,
        no per-column dtype dispatch, no FNV mixing. Only slots past the prefix
        fall back to the original `_hash_storage_row` re-derivation.

        That re-derivation was ALSO WRONG for a negative DT_I16 / DT_I8 key (see
        `_slot_hashes`): it hashed the two's-complement cell UNSIGNED while every
        probe hashes the batch value SIGN-EXTENDED, so the rebuilt chain head sat
        at a bucket no probe would visit and `probe_batch` silently dropped every
        match for that key. Slots sharing a key still share a hash — the stored
        hash is a pure function of the key bytes on the batch side — so the
        salt-then-verify chain grouping below is unchanged, as is the ascending
        slot iteration order and hence the resulting chain order.
        """
        self.directory.reset_doubled()
        self._directory_rehashes += 1
        var n_slots = self.storage.n_slots
        var n_cached = len(self._slot_hashes)
        for s in range(n_slots):
            var h: UInt64
            if s < n_cached:
                h = self._slot_hashes[s]
            else:
                self._storage_hash_recomputes += 1
                h = self._hash_storage_row(s)
            var salt = HashDirectory._salt_of(h)
            var bucket = self.directory.bucket_of(h)
            while True:
                var head = self.directory.read_slot_at(bucket)
                if Int(head) == Int(SLOT_EMPTY):
                    # Fresh key — slot `s` is a new chain head (tail link).
                    self._chain_next[s] = SLOT_EMPTY
                    _ = self.directory.insert_raw(h, Int32(s))
                    break
                var bucket_salt = self.directory.read_salt_at(bucket)
                if bucket_salt == salt:
                    if self._storage_keys_match(Int(head), s):
                        # Duplicate key — link `s` onto the existing head
                        # and promote it to the new chain head.
                        self._chain_next[s] = head
                        self.directory.set_slot_at(bucket, Int32(s))
                        break
                bucket = self.directory.next_bucket(bucket)

    def _storage_keys_match(self, slot_a: Int, slot_b: Int) raises -> Bool:
        """True iff the stored keys at `slot_a` and `slot_b` are equal
        across all key cols. Used by the rehash to group same-key slots
        into one chain (storage-vs-storage key equality, the sister of
        `_keys_match`'s batch-vs-storage compare)."""
        for k in range(self.key_descriptors.__len__()):
            var desc = self.key_descriptors[k]
            if not _storage_key_eq_single_col(self.storage, desc, slot_a, slot_b):
                return False
        return True

    def _hash_storage_row(self, slot: Int) raises -> UInt64:
        """Compose-hash all key cols at `slot` (storage-side equivalent
        of `_hash_row`)."""
        var h: UInt64 = UInt64(0)
        var n_keys = self.key_descriptors.__len__()
        for k in range(n_keys):
            var desc = self.key_descriptors[k]
            var per_col_h = _hash_storage_single_col(self.storage, desc, slot)
            if k == 0:
                h = per_col_h
            else:
                h = _hash_compose(h, per_col_h)
        return h

    # ─────────────────────────────────────────────────────────────────────
    # build_batch — primary build-side entry.
    # ─────────────────────────────────────────────────────────────────────

    def build_batch[
        bo: Origin[mut=False]
    ](mut self, batch: BatchView[bo]) raises:
        """Insert each row of `batch` into the build table.

        For each row r:
          1. Compose-hash all key cols at row r.
          2. Probe directory: salt-match -> verify key bytes.
          3. miss: alloc slot, write all keys + all payloads via
             per-DType `_encode_cell`, directory.insert_raw.
          4. hit: set `has_duplicate_keys = True`.

        Storage + directory grow on threshold via
        `_grow_if_needed`.
        """
        var n_rows = batch.n_rows()
        for r in range(n_rows):
            self._build_one_row(batch, r)

    def _keys_any_null[
        bo: Origin[mut=False]
    ](self, batch: BatchView[bo], row: Int) -> Bool:
        """SW-C: is ANY key column NULL at `row`? A NULL join key matches
        NOTHING (SQL "NULL never matches" — not a real value, not another NULL).
        Build skips the insert; probe skips the lookup. DType-agnostic (reads
        only the validity bitmap via `BatchView.col_is_null`); all-valid columns
        return False (byte-identical fast path)."""
        for k in range(self.key_descriptors.__len__()):
            if batch.col_is_null(self.key_descriptors[k].col_idx_in_batch, row):
                return True
        return False

    def _build_one_row[
        bo: Origin[mut=False]
    ](mut self, batch: BatchView[bo], row: Int) raises:
        """Build hot path for ONE row. Factored out so `build_batch`
        + the test path can share the same logic without nesting more
        @parameter blocks.
        """
        # SW-C nullable-key correctness: a NULL build key is NEVER a match
        # target (SQL "NULL never matches"). Skip the entire insert for a row
        # whose any key column is NULL — it must never be reachable from a probe.
        # `_keys_any_null` is the all-valid fast path (no validity -> False), so
        # a non-null build is byte-identical to pre-SW-C.
        if self._keys_any_null(batch, row):
            return

        # Grow before probe — directory growth invalidates buckets, so
        # we MUST grow before we observe the bucket for an insert.
        self._grow_if_needed()

        var h = self._hash_row(batch, row)
        var salt = HashDirectory._salt_of(h)
        var bucket = self.directory.bucket_of(h)

        # Salt-match-then-verify probe loop.
        #
        # build-side key fanout: EVERY build row gets its own
        # storage slot. The directory bucket holds the HEAD of the per-key
        # chain; on a duplicate-key hit we allocate a fresh slot, write its
        # keys + payloads, link it as the NEW chain head, and rewrite the
        # bucket's slot to point at it. On a miss we allocate a slot with an
        # empty (-1) chain link and insert it as a new chain head. The
        # common N:1 case stays a single insert with a 1-long chain.
        while True:
            var s = self.directory.read_slot_at(bucket)
            if Int(s) == Int(SLOT_EMPTY):
                # Miss — allocate slot, write keys + payloads, chain tail.
                var new_slot = self._alloc_slot_with_chain(SLOT_EMPTY, h)
                # Write all key cols. Copy the descriptor into a local
                # before passing — Mojo 1.0.0b1 forbids passing a mut
                # arg + a ref through self in the same call (aliasing).
                for k in range(self.key_descriptors.__len__()):
                    var key_desc = self.key_descriptors[k]
                    _encode_cell(self.storage, batch, key_desc, row, new_slot)
                # Write all payload cols.
                for p in range(self.payload_descriptors.__len__()):
                    var pay_desc = self.payload_descriptors[p]
                    _encode_cell(self.storage, batch, pay_desc, row, new_slot)
                _ = self.directory.insert_raw(h, Int32(new_slot))
                return
            # Salt fingerprint check before full key equality.
            var bucket_salt = self.directory.read_salt_at(bucket)
            if bucket_salt == salt:
                if self._keys_match(batch, row, Int(s)):
                    # Hit on duplicate key — fan-out insert. Allocate a
                    # fresh slot whose chain link points at the prior head
                    # `s`, write its cells, then rewrite the bucket so the
                    # new slot becomes the chain head.
                    self.has_duplicate_keys = True
                    var dup_slot = self._alloc_slot_with_chain(s, h)
                    for k in range(self.key_descriptors.__len__()):
                        var key_desc = self.key_descriptors[k]
                        _encode_cell(self.storage, batch, key_desc, row, dup_slot)
                    for p in range(self.payload_descriptors.__len__()):
                        var pay_desc = self.payload_descriptors[p]
                        _encode_cell(self.storage, batch, pay_desc, row, dup_slot)
                    self.directory.set_slot_at(bucket, Int32(dup_slot))
                    return
            bucket = self.directory.next_bucket(bucket)

    def _alloc_slot_with_chain(
        mut self, next_link: Int32, placing_hash: UInt64
    ) raises -> Int:
        """Allocate one fresh storage slot and append its chain link.

        Reserves the next storage slot index, grows `_chain_next` 1:1
        with `storage.n_slots`, and records `next_link` as the new slot's
        next-in-chain pointer (`SLOT_EMPTY` for a chain tail / fresh head).

        Args:
            next_link: The new slot's next-in-chain pointer.
            placing_hash: JOIN-HASH-STORE — the `_hash_row` value the caller
                probed with. Recorded so `_rehash_directory` never has to
                re-derive it from the stored key bytes (which is both slower
                and, for a negative narrow signed int key, WRONG; see
                `_slot_hashes`).

        Returns:
            The newly allocated slot index.
        """
        var new_slot = self.storage.n_slots
        self.storage.set_n_slots(new_slot + 1)
        # Keep `_chain_next` aligned 1:1 with storage slots. Slots are
        # allocated in strictly increasing order, so appending is correct.
        self._chain_next.append(next_link)
        # JOIN-HASH-STORE: same index space, appended in the same step so the
        # two can never drift. Guarded on `len == new_slot` inside.
        self._note_slot_hash(new_slot, placing_hash)
        return new_slot

    # ─────────────────────────────────────────────────────────────────────
    # probe_batch — primary probe-side entry.
    # ─────────────────────────────────────────────────────────────────────

    def probe_batch[
        bo: Origin[mut=False]
    ](
        self,
        batch: BatchView[bo],
        mut match_pairs: List[MatchPair],
    ) raises:
        """Emit a MatchPair into `match_pairs` for each probe row that
        finds a build-side key.

        For each row r:
          1. Compose-hash all key cols at row r.
          2. directory.read_slot_at: walk the probe chain.
          3. salt match + key bytes match: append MatchPair(r, slot).
          4. on bucket SLOT_EMPTY: stop (probe chain exhausted).

        Multi-match build-side keys (M:N fan-out): when a probe key
        matches K build rows, the per-key chain walker emits
        K MatchPairs (one per build slot sharing the key) via
        `_emit_chain`. The N:1 common case walks a length-1 chain (single
        emit), preserving the fast path.
        """
        var n_rows = batch.n_rows()
        for r in range(n_rows):
            self._probe_one_row(batch, r, match_pairs)

    def _probe_one_row[
        bo: Origin[mut=False]
    ](
        self,
        batch: BatchView[bo],
        row: Int,
        mut match_pairs: List[MatchPair],
    ) raises:
        """Probe hot path for ONE row. Factored out so `probe_batch`
        + the test path can share the same logic.

        build-side key fanout: once the bucket holding this
        key is found, its slot is the HEAD of the per-key chain. We emit
        one MatchPair per slot along the `_chain_next` chain, restoring
        full M:N fan-out (one row per build row sharing the probe key).
        For the N:1 common case the chain is length 1 (single emit)."""
        # SW-C: a NULL probe key matches NOTHING -> emit no MatchPair (the probe
        # row is unmatched; LEFT/ANTI keep it via the absence of a pair).
        if self._keys_any_null(batch, row):
            return
        var h = self._hash_row(batch, row)
        var salt = HashDirectory._salt_of(h)
        var bucket = self.directory.bucket_of(h)

        while True:
            var s = self.directory.read_slot_at(bucket)
            if Int(s) == Int(SLOT_EMPTY):
                return
            var bucket_salt = self.directory.read_salt_at(bucket)
            if bucket_salt == salt:
                if self._keys_match(batch, row, Int(s)):
                    # Walk the per-key chain from the head slot `s`.
                    self._emit_chain(row, Int(s), match_pairs)
                    return
            bucket = self.directory.next_bucket(bucket)

    def _emit_chain(
        self,
        probe_row: Int,
        head_slot: Int,
        mut match_pairs: List[MatchPair],
    ) raises:
        """Emit one MatchPair for every build slot in the per-key chain
        starting at `head_slot`. Chain members all share the matched key
        (linked at build time), so no per-slot key re-verification is
        needed. Terminates at the SLOT_EMPTY (-1) chain tail."""
        var cur = head_slot
        while cur != Int(SLOT_EMPTY):
            match_pairs.append(
                MatchPair(probe_row=probe_row, build_slot=cur)
            )
            cur = Int(self._chain_next[cur])

    # ─────────────────────────────────────────────────────────────────────
    # probe_batch_remapped — probe-side entry that reads the probe batch
    # via CALLER-SUPPLIED probe key descriptors rather than the build
    # table's own `self.key_descriptors`.
    #
    # WHY IT EXISTS:
    # `probe_batch` reuses `self.key_descriptors` (whose `col_idx_in_batch`
    # points at the BUILD batch's key column positions) to read the PROBE
    # batch. That only yields a correct probe when every join key sits at
    # the SAME column index on both sides. For composite (multi-key)
    # joins — and any join whose probe-side key columns differ in position
    # from the build side — the caller must supply PROBE descriptors whose
    # `col_idx_in_batch` is the probe-batch column index and whose
    # `col_idx_in_storage` matches the build storage layout (key k -> k),
    # so hashing reads the probe batch while equality compares against the
    # build storage slot.
    # ─────────────────────────────────────────────────────────────────────

    def probe_batch_remapped[
        bo: Origin[mut=False]
    ](
        self,
        batch: BatchView[bo],
        probe_key_descriptors: List[ColDescriptor],
        mut match_pairs: List[MatchPair],
    ) raises:
        """Probe `batch` using `probe_key_descriptors` (probe-side
        `col_idx_in_batch`, build-storage-aligned `col_idx_in_storage`)
        instead of `self.key_descriptors`.

        Each descriptor MUST carry `col_idx_in_storage == k` for key k
        (matching the build storage layout) so that key equality reads
        the correct storage cell while the per-col hash + batch read use
        the probe batch's column index.
        """
        var n_rows = batch.n_rows()
        for r in range(n_rows):
            self._probe_one_row_remapped(
                batch, probe_key_descriptors, r, match_pairs
            )

    def _probe_one_row_remapped[
        bo: Origin[mut=False]
    ](
        self,
        batch: BatchView[bo],
        probe_key_descriptors: List[ColDescriptor],
        row: Int,
        mut match_pairs: List[MatchPair],
    ) raises:
        """Probe hot path for ONE row using probe-side key descriptors."""
        # SW-C: a NULL probe key matches NOTHING -> emit no MatchPair.
        for k in range(probe_key_descriptors.__len__()):
            if batch.col_is_null(
                probe_key_descriptors[k].col_idx_in_batch, row
            ):
                return
        var h = self._hash_row_with_descs(batch, probe_key_descriptors, row)
        var salt = HashDirectory._salt_of(h)
        var bucket = self.directory.bucket_of(h)

        while True:
            var s = self.directory.read_slot_at(bucket)
            if Int(s) == Int(SLOT_EMPTY):
                return
            var bucket_salt = self.directory.read_salt_at(bucket)
            if bucket_salt == salt:
                if self._keys_match_with_descs(
                    batch, probe_key_descriptors, row, Int(s)
                ):
                    # Walk the per-key chain from head `s`.
                    self._emit_chain(row, Int(s), match_pairs)
                    return
            bucket = self.directory.next_bucket(bucket)

    def _hash_row_with_descs[
        bo: Origin[mut=False]
    ](
        self,
        batch: BatchView[bo],
        descs: List[ColDescriptor],
        row: Int,
    ) raises -> UInt64:
        """Compose-hash all key cols at `row` using `descs` (probe-side).

        MUST stay bit-identical to `_hash_row` for matching key bytes —
        the only difference is the descriptor source (probe vs build),
        which carries the probe batch column index. `_hash_single_col`
        reads via `desc.col_idx_in_batch`, so passing probe descriptors
        hashes the probe batch.
        """
        var h: UInt64 = UInt64(0)
        var n_keys = descs.__len__()
        for k in range(n_keys):
            var desc = descs[k]
            var per_col_h = _hash_single_col(batch, desc, row)
            if k == 0:
                h = per_col_h
            else:
                h = _hash_compose(h, per_col_h)
        return h

    def _keys_match_with_descs[
        bo: Origin[mut=False]
    ](
        self,
        batch: BatchView[bo],
        descs: List[ColDescriptor],
        row: Int,
        slot: Int,
    ) raises -> Bool:
        """True iff the keys at (`batch`, `row`) — read via probe-side
        `descs` — match the keys stored at `slot`. `_key_eq_single_col`
        reads the batch at `desc.col_idx_in_batch` and storage at
        `desc.col_idx_in_storage`, so the probe descriptors' storage
        index (== build key index) drives the storage read while the
        batch index drives the probe-batch read.
        """
        for k in range(descs.__len__()):
            var desc = descs[k]
            if not _key_eq_single_col(self.storage, batch, row, slot, desc):
                return False
        return True

    # ─────────────────────────────────────────────────────────────────────
    # emit_to_record_batch_columnar — drain matched slot payloads into a
    # per-DType `List[T]` per output payload col.
    #
    # The table returns parallel lists, NOT a `RecordBatch`: a caller knows
    # its own output schema and calls the per-DType reader for each payload
    # column, mirroring `ColumnFormatStorage.read_slot_*`.
    # ─────────────────────────────────────────────────────────────────────

    def read_payload_i64_for(
        self, match_pairs: List[MatchPair], payload_idx: Int
    ) raises -> List[Int64]:
        """Gather Int64 payload col `payload_idx` for every matched
        slot in `match_pairs`. Output length == match_pairs length.

        Raises:
            On payload_idx out of range OR on payload col not being
            an Int64 fixed col.
        """
        if payload_idx < 0 or payload_idx >= self.payload_descriptors.__len__():
            raise Error(
                "JoinBuildTable_Untyped.read_payload_i64_for: payload_idx"
                " out of range"
            )
        var desc = self.payload_descriptors[payload_idx]
        if desc.kind != COL_FIXED or desc.dtype_tag != DT_I64:
            raise Error(
                "JoinBuildTable_Untyped.read_payload_i64_for: payload col"
                " is not Int64 fixed (kind="
                + String(Int(desc.kind))
                + " dtype_tag=" + String(Int(desc.dtype_tag))
                + ")"
            )
        var out = List[Int64]()
        for i in range(match_pairs.__len__()):
            var slot = match_pairs[i].build_slot
            out.append(self.storage.read_slot_i64(desc.col_idx_in_storage, slot))
        return out^

    def read_payload_f64_for(
        self, match_pairs: List[MatchPair], payload_idx: Int
    ) raises -> List[Float64]:
        """Gather Float64 payload col `payload_idx` for every matched
        slot."""
        if payload_idx < 0 or payload_idx >= self.payload_descriptors.__len__():
            raise Error(
                "JoinBuildTable_Untyped.read_payload_f64_for: payload_idx"
                " out of range"
            )
        var desc = self.payload_descriptors[payload_idx]
        if desc.kind != COL_FIXED or desc.dtype_tag != DT_F64:
            raise Error(
                "JoinBuildTable_Untyped.read_payload_f64_for: payload col"
                " is not Float64 fixed"
            )
        var out = List[Float64]()
        for i in range(match_pairs.__len__()):
            var slot = match_pairs[i].build_slot
            out.append(self.storage.read_slot_f64(desc.col_idx_in_storage, slot))
        return out^

    def read_payload_i32_for(
        self, match_pairs: List[MatchPair], payload_idx: Int
    ) raises -> List[Int32]:
        """Gather Int32 payload col `payload_idx`."""
        if payload_idx < 0 or payload_idx >= self.payload_descriptors.__len__():
            raise Error(
                "JoinBuildTable_Untyped.read_payload_i32_for: payload_idx"
                " out of range"
            )
        var desc = self.payload_descriptors[payload_idx]
        if (desc.kind != COL_FIXED
                or (desc.dtype_tag != DT_I32 and desc.dtype_tag != DT_DATE32)):
            raise Error(
                "JoinBuildTable_Untyped.read_payload_i32_for: payload col"
                " is not Int32 / Date32 fixed"
            )
        var out = List[Int32]()
        for i in range(match_pairs.__len__()):
            var slot = match_pairs[i].build_slot
            out.append(self.storage.read_slot_i32(desc.col_idx_in_storage, slot))
        return out^
