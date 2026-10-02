# =============================================================================
# attr_set.mojo — attribute SET interning
# =============================================================================
#
# SIZE. A table that stored only a key HASH per slot would be small, but it
# cannot: an exporter has to turn an `attrset_id` back into labels at serialize
# time, and collision detection needs to compare CONTENTS -- without the set,
# two different attribute sets sharing a digest merge into one series and
# nothing downstream can undo it. So each slot holds the set:
#
#     AttrKeyValue      = 4 + 4                        =  8 B
#     AttrSet           = 8 x 8 + 1 + 3 pad + 1 + pad  = 72 B
#     AttrSetEntry      = 4 + 1 + 3 pad + 72           = 80 B
#     x MAX_ATTRSETS 4096                              = 320 KiB per registry
#
# 320 KiB is still a rounding error against the 4 MiB series table it feeds:
# the interner is the cheap half of attributes. It is a bounded open-addressing
# table. The EXPENSIVE half is the per-worker SERIES TABLE mapping
# `(name_id, attrset_id)` -> Int64, which lives in `series_table.mojo`.
#
# WHY INTERN AT ALL: `ARG_INLINE_BYTES = 48` on `LogEventRecord`. Two
# realistic string labels do not fit in 48 bytes, so an inline label set would
# spill to the ring arena on EVERY point, on the hot path. Interning makes the
# on-ring record fixed-size REGARDLESS of label count and moves the string cost
# to a one-time insert.
#
# ⛔ NOT AN AT-REST FORMAT. This is process-local interning. How attribute sets
# are stored durably is a separate concern. An `attrset_id`
# is meaningful ONLY within the process that minted it -- it is a hash of the
# set's contents, not a stable global key -- so anything durable must write the
# SET, not the id. Stated here because the id is exactly the kind of value that
# looks safe to persist and is not.
#
# ⛔ NOT THE CARDINALITY CEILING. Collapse-on-overflow and the reserved OTel
# overflow attribute are a separate layer. This file REFUSES and COUNTS when
# full, which is the fail-closed behaviour a collapse builds on top of. It does
# not silently reuse a slot.
#
# Encapsulation: `InlineArray` of POD entries + one Atomic. No
# `UnsafePointer`, no wildcard origin, no heap-owning field.
# =============================================================================

from komira_atomic_alias import AtomicI32
from std.sys import size_of

from komira_obs.name_registry import (
    FNV1A_32_OFFSET_BASIS,
    FNV1A_32_PRIME,
)


# Attributes per set. OTel's own guidance is that a metric's attribute set is
# small and fixed per instrument; 8 covers every realistic case here while
# keeping `AttrSet` fixed-stride at 8 pairs x 8 B + 8 B header = 72 B.
comptime MAX_ATTRS_PER_SET: Int = 8

# Distinct attribute SETS per process. This ceiling is derived -- it is
# the ring capacity (`DEFAULT_RING_CAPACITY = 4096`), deliberately, so the
# interner cannot outgrow the transport that carries its points. Power of two
# is required for the linear-probing wrap.
comptime MAX_ATTRSETS: Int = 4096

# The EMPTY attribute set's id. A real and common case -- most metrics carry no
# attributes -- so it is a VALUE, not a sentinel for "unset". Nothing else
# hashes to it: `intern` special-cases the empty set before hashing.
comptime EMPTY_ATTRSET_ID: UInt32 = UInt32(0)

# Returned by `intern` when the table is full. ⚠ DISTINCT FROM
# `EMPTY_ATTRSET_ID`: conflating "no attributes" with "we ran out of room"
# would make an overflowed series silently join the unattributed series, which
# is a silent series corruption.
comptime ATTRSET_OVERFLOW_ID: UInt32 = UInt32(0xFFFFFFFF)


struct AttrKeyValue(Copyable, Movable, Deinitable):
    """One (key, value) pair, both already interned to ids by the caller.

    ⚠ BOTH SIDES ARE IDS, NOT STRINGS. Keeping bytes here would defeat the
    entire point of interning -- the set would stop being fixed-stride."""

    var key_id: UInt32
    var value_id: UInt32

    def __init__(out self, key_id: UInt32 = UInt32(0), value_id: UInt32 = UInt32(0)):
        self.key_id = key_id
        self.value_id = value_id


struct AttrSet(Copyable, Movable, Deinitable):
    """Up to `MAX_ATTRS_PER_SET` (key_id, value_id) pairs. POD, fixed-stride.

    ⭐ A SET, NOT A LIST -- and that is the whole difficulty. `{a=1, b=2}` and
    `{b=2, a=1}` are the SAME series and must intern to the same id, or a
    caller that happens to add attributes in a different order silently creates
    a second series measuring the same thing. `canonicalize()` sorts by
    `key_id` so both the digest and the equality test are order-independent.
    """

    var pairs: Array[AttrKeyValue, MAX_ATTRS_PER_SET]
    var n: UInt8
    var _pad: Array[UInt8, 3]
    # Set when `add` was called on a full set. The set is then INCOMPLETE, and
    # interning it would mint an id for a series that silently lost a label.
    var truncated: Bool

    def __init__(out self):
        self.pairs = Array[AttrKeyValue, MAX_ATTRS_PER_SET](
            fill=AttrKeyValue()
        )
        self.n = UInt8(0)
        self._pad = Array[UInt8, 3](fill=UInt8(0))
        self.truncated = False

    @always_inline
    def count(self) -> Int:
        return Int(self.n)

    def add(mut self, key_id: UInt32, value_id: UInt32) -> Bool:
        """Append a pair. Returns False (and sets `truncated`) if the set is
        already at `MAX_ATTRS_PER_SET`.

        ⚠ A DUPLICATE KEY IS REPLACED, NOT APPENDED. Two pairs with the same
        key would make `{a=1, a=2}` hash differently depending on insertion
        order even after sorting, and OTel attribute sets are maps."""
        for i in range(Int(self.n)):
            if self.pairs[i].key_id == key_id:
                self.pairs[i].value_id = value_id
                return True
        if Int(self.n) >= MAX_ATTRS_PER_SET:
            self.truncated = True
            return False
        self.pairs[Int(self.n)] = AttrKeyValue(key_id, value_id)
        self.n = UInt8(Int(self.n) + 1)
        return True

    def canonicalize(mut self):
        """Sort pairs by `key_id`, ascending. Insertion sort -- `n` is at most
        8, so this is faster than anything cleverer and has no allocation."""
        var n = Int(self.n)
        for i in range(1, n):
            var cur = self.pairs[i].copy()
            var j = i - 1
            while j >= 0 and self.pairs[j].key_id > cur.key_id:
                self.pairs[j + 1] = self.pairs[j].copy()
                j -= 1
            self.pairs[j + 1] = cur.copy()

    def digest(self) -> UInt32:
        """FNV-1a over the pairs AS LAID OUT. Call `canonicalize()` first, or
        two orderings of one set digest differently -- which is the bug this
        whole struct exists to prevent. `intern` canonicalizes for you.

        The empty set digests to `EMPTY_ATTRSET_ID` by construction (the loop
        body never runs and the basis is folded to 0 below), which is why the
        empty case needs no sentinel."""
        if self.n == UInt8(0):
            return EMPTY_ATTRSET_ID
        var h = FNV1A_32_OFFSET_BASIS
        for i in range(Int(self.n)):
            var k = self.pairs[i].key_id
            var v = self.pairs[i].value_id
            # Fold all four bytes of each id, low byte first.
            for b in range(4):
                h = (h ^ ((k >> UInt32(b * 8)) & UInt32(0xFF))) * FNV1A_32_PRIME
            for b in range(4):
                h = (h ^ ((v >> UInt32(b * 8)) & UInt32(0xFF))) * FNV1A_32_PRIME
        # ⚠ 0 and the overflow sentinel are RESERVED. A non-empty set whose
        # digest lands on either is nudged rather than allowed to collide with
        # "empty" or "we ran out of room".
        if h == EMPTY_ATTRSET_ID or h == ATTRSET_OVERFLOW_ID:
            h = FNV1A_32_PRIME
        return h

    def equals(self, other: AttrSet) -> Bool:
        """Pairwise equality over canonicalized sets. Used to resolve a digest
        collision -- WITHOUT it, two different sets sharing a digest would be
        silently merged into one series."""
        if self.n != other.n:
            return False
        for i in range(Int(self.n)):
            if self.pairs[i].key_id != other.pairs[i].key_id:
                return False
            if self.pairs[i].value_id != other.pairs[i].value_id:
                return False
        return True


struct AttrSetEntry(Copyable, Movable, Deinitable):
    """One slot of the interner. `occupied` is its own field rather than
    `id != 0`, because 0 is the LEGAL id of the empty set."""

    var id: UInt32
    var occupied: Bool
    var _pad: Array[UInt8, 3]
    var set: AttrSet

    def __init__(out self):
        self.id = UInt32(0)
        self.occupied = False
        self._pad = Array[UInt8, 3](fill=UInt8(0))
        self.set = AttrSet()


struct AttrSetRegistry(Deinitable):
    """Bounded open-addressing interner: `AttrSet` -> `UInt32 attrset_id`.

    Same shape as `name_registry.mojo`'s table (linear probing, power-of-two
    capacity), with two differences that matter:

      1. The key is a SET, so it is canonicalized before hashing.
      2. A digest collision between two DIFFERENT sets is DETECTED and counted,
         not silently merged. `name_registry` can accept a benign double-insert
         because its drain dedups by name_id; here a merge would make two
         distinct series report as one, which no downstream can undo.

    ⚠ SINGLE-WRITER. Unlike `NameRegistry` this table is NOT CAS-inserted --
    it is intended to be owned per-worker or behind the export sweep's single
    thread, matching the per-worker series table it feeds. Do not share
    one across workers without adding the CAS; the `Atomic` counters below are
    for observability, NOT for making insertion safe.
    """

    var entries: Array[AttrSetEntry, MAX_ATTRSETS]
    var n_interned: AtomicI32
    # Interning attempts refused because the table was full.
    var overflowed: AtomicI32
    # Distinct sets that digested to an id already held by a different set.
    var digest_collisions: AtomicI32
    # Interning attempts refused because the set was TRUNCATED by `add`.
    var truncated_refused: AtomicI32

    def __init__(out self):
        self.entries = Array[AttrSetEntry, MAX_ATTRSETS](
            fill=AttrSetEntry()
        )
        self.n_interned = AtomicI32(Int32(0))
        self.overflowed = AtomicI32(Int32(0))
        self.digest_collisions = AtomicI32(Int32(0))
        self.truncated_refused = AtomicI32(Int32(0))

    @always_inline
    def count(self) -> Int:
        return Int(self.n_interned.load())

    @always_inline
    def num_overflowed(self) -> Int:
        """Interning attempts refused because the table was full. NON-ZERO
        MEANS SERIES WERE LOST -- a cardinality collapse layer is what turns this
        from a loss into a documented bucket."""
        return Int(self.overflowed.load())

    @always_inline
    def num_digest_collisions(self) -> Int:
        """Distinct sets whose digests collided. NON-ZERO MEANS THE CEILING IS
        TOO CLOSE TO THE HASH WIDTH, not that anything was corrupted -- the
        colliding set is REFUSED, never merged."""
        return Int(self.digest_collisions.load())

    @always_inline
    def num_truncated_refused(self) -> Int:
        """Sets refused because `add` had already dropped a pair."""
        return Int(self.truncated_refused.load())

    def intern(mut self, var set: AttrSet) -> UInt32:
        """Canonicalize, hash, and insert `set` if new. Returns its id.

        Returns `ATTRSET_OVERFLOW_ID` -- never a wrong id -- when the set is
        truncated, the digest collides with a DIFFERENT set, or the table is
        full. Every refusal is counted.
        """
        # ⛔ A TRUNCATED SET IS REFUSED. Interning it would mint an id for a
        # series that silently lost a label, and every later reading of that
        # series would be attributed to the wrong thing.
        if set.truncated:
            _ = self.truncated_refused.fetch_add(Int32(1))
            return ATTRSET_OVERFLOW_ID

        set.canonicalize()
        var id = set.digest()
        if set.n == UInt8(0):
            # The empty set is not stored: it has one id, always available, and
            # occupying a slot for it would waste the ceiling.
            return EMPTY_ATTRSET_ID

        var idx = Int(id) & (MAX_ATTRSETS - 1)
        var probe = 0
        while probe < MAX_ATTRSETS:
            if not self.entries[idx].occupied:
                self.entries[idx].occupied = True
                self.entries[idx].id = id
                self.entries[idx].set = set.copy()
                _ = self.n_interned.fetch_add(Int32(1))
                return id
            if self.entries[idx].id == id:
                if self.entries[idx].set.equals(set):
                    return id
                # SAME DIGEST, DIFFERENT SET. Refuse -- see the struct note.
                _ = self.digest_collisions.fetch_add(Int32(1))
                return ATTRSET_OVERFLOW_ID
            idx = (idx + 1) & (MAX_ATTRSETS - 1)
            probe += 1

        _ = self.overflowed.fetch_add(Int32(1))
        return ATTRSET_OVERFLOW_ID

    def lookup(self, id: UInt32) -> Optional[AttrSet]:
        """Resolve an id back to its set. `EMPTY_ATTRSET_ID` yields the empty
        set (which is never stored); an unknown id yields None.

        This is what an exporter calls at serialize time to turn an
        `attrset_id` on a `MetricPoint` back into labels."""
        if id == EMPTY_ATTRSET_ID:
            return Optional[AttrSet](AttrSet())
        if id == ATTRSET_OVERFLOW_ID:
            return Optional[AttrSet]()
        var idx = Int(id) & (MAX_ATTRSETS - 1)
        var probe = 0
        while probe < MAX_ATTRSETS:
            if not self.entries[idx].occupied:
                return Optional[AttrSet]()
            if self.entries[idx].id == id:
                return Optional[AttrSet](self.entries[idx].set.copy())
            idx = (idx + 1) & (MAX_ATTRSETS - 1)
            probe += 1
        return Optional[AttrSet]()


# -----------------------------------------------------------------------------
# Compile-time SIZE anchors — the convention `span_record.mojo` and
# `span_packet.mojo` already follow in this package.
#
# ⚠ THESE PIN THE HEADER'S ARITHMETIC, WHICH IS THE WHOLE POINT. The 320 KiB
# figure at the top of this file is derived from `AttrSetEntry` being 80 B, and
# a comment nothing executes is a number that drifts.
#
# ⛔ THEY ARE NOT POD GUARDS: `size_of` of a non-POD type is NOT rejected, so a
# field-type swap that drops a POD constraint still elaborates here. Why no
# Mojo 1.0.0 construct can make it a POD guard is recorded once beside
# `_METRIC_POINT_SIZE_GUARD` in `metric_point.mojo`. What these lines buy is a
# number evaluated at elaboration and READ by
# `test_the_size_guard_constants_are_the_bytes_the_headers_claim`; a LAYOUT
# change is what they catch, and only because that test reads them.
# -----------------------------------------------------------------------------
comptime _ATTR_KEY_VALUE_SIZE_GUARD: Int = size_of[AttrKeyValue]()
comptime _ATTR_SET_SIZE_GUARD: Int = size_of[AttrSet]()
comptime _ATTR_SET_ENTRY_SIZE_GUARD: Int = size_of[AttrSetEntry]()
comptime _ATTR_SET_REGISTRY_SIZE_GUARD: Int = size_of[AttrSetRegistry]()
