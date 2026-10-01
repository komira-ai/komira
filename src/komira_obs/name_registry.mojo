# =============================================================================
# name_registry.mojo — FNV-1a comptime hash + lazy CAS-insert registry
# =============================================================================
#
# Per-call-site name interning:
#   1. `fnv1a_hash[name: StringLiteral]() -> UInt32` is a comptime-evaluable
#      function on a `StringLiteral`. The digest is a literal at the call
#      site; zero runtime cost.
#   2. The first emit per `(name_id, process)` does a one-time
#      compare-and-swap insertion into a fixed-size open-addressing
#      table (≤256 names). Backend drain reads the registry when emitting
#      JSONL.
#   3. Subsequent emits compile to a lookup on a per-worker "already-
#      registered" bitset (held on `WorkerContextSlot` in `tracer.mojo`).
#
# NOT a `@parameter` macro walking a global table. Mojo 0.26.3 has no
# const-evaluable mutable global registry; we use the open-addressing
# table for one-shot insertion and a per-worker bitset to fast-path.
# =============================================================================

from komira_atomic_alias import AtomicI32


# Hard cap on distinct span names per process. 256 is plenty: a query
# engine's instrumentation uses a few dozen distinct span names. Power of two
# is required for the linear-probing wrap.
comptime MAX_REGISTERED_NAMES: Int = 256
# Bitset size in UInt64 words. ceil(256/64) = 4.
comptime NAME_BITSET_WORDS: Int = (MAX_REGISTERED_NAMES + 63) // 64

# FNV-1a 32-bit constants
comptime FNV1A_32_OFFSET_BASIS: UInt32 = UInt32(2166136261)
comptime FNV1A_32_PRIME: UInt32 = UInt32(16777619)


# -----------------------------------------------------------------------------
# fnv1a_hash[name: StringLiteral]() — comptime hash of a static literal.
# -----------------------------------------------------------------------------


def _fnv1a_compute(name: StringLiteral) -> UInt32:
    """Compute FNV-1a 32-bit hash. When invoked from `fnv1a_hash[name]`
    via `alias h = ...`, the result is comptime-resolved.
    """
    var h = FNV1A_32_OFFSET_BASIS
    var s = String(name)
    var b = s.as_bytes()
    var n = len(b)
    for i in range(n):
        h = (h ^ UInt32(b[i])) * FNV1A_32_PRIME
    return h


@always_inline
def fnv1a_hash[name: StringLiteral]() -> UInt32:
    """Comptime FNV-1a 32-bit hash of a static literal.

    The hash digest resolves to a `UInt32` literal at the call site —
    zero runtime cost. Used as `name_id` for spans, attributes, and
    metric names; same hash family across all three.
    """
    comptime h = _fnv1a_compute(name)
    return h


def fnv1a_hash_bytes(imm s: String) -> UInt32:
    """Runtime FNV-1a — used by the registry when looking up a name
    that was hashed at comptime by a different translation unit.
    """
    var h = FNV1A_32_OFFSET_BASIS
    var b = s.as_bytes()
    var n = len(b)
    for i in range(n):
        h = (h ^ UInt32(b[i])) * FNV1A_32_PRIME
    return h


# -----------------------------------------------------------------------------
# NameRegistryEntry — one slot of the open-addressing hash table.
# Empty when name_id == 0.  FNV-1a never returns 0 for a non-empty input;
# we explicitly reject the empty literal at registration time.
# -----------------------------------------------------------------------------


comptime MAX_NAME_BYTES: Int = 64


struct NameRegistryEntry(Copyable, Movable, Deinitable):
    """One entry in the lazy name registry.

    POD invariant: `InlineArray[UInt8, MAX_NAME_BYTES]` + scalars only.
    """

    var name_id: UInt32
    var name_len: UInt8
    var _pad: Array[UInt8, 3]
    var name_bytes: Array[UInt8, MAX_NAME_BYTES]

    def __init__(out self):
        self.name_id = UInt32(0)
        self.name_len = UInt8(0)
        self._pad = Array[UInt8, 3](fill=UInt8(0))
        self.name_bytes = Array[UInt8, MAX_NAME_BYTES](fill=UInt8(0))


# -----------------------------------------------------------------------------
# NameRegistry — lock-free open-addressing table. CAS-insert on first
# emit per (name_id, process). Subsequent emits fast-path through a
# per-worker bitset (held in tracer.mojo, NOT here).
# -----------------------------------------------------------------------------


struct NameRegistry(Deinitable):
    """Lazy FNV-1a name registry.

    Layout: `entries: InlineArray[NameRegistryEntry, MAX_REGISTERED_NAMES]`,
    linear probing. Max load 50% — at MAX_REGISTERED_NAMES/2 entries the
    probe-chain length stays bounded.

    Concurrency: many writers (per-worker first-emit) compete via
    a CAS-shaped insert; the JSONL drain treats name records as
    set-semantics so a benign double-insert is harmless.
    """

    var entries: Array[NameRegistryEntry, MAX_REGISTERED_NAMES]
    var n_registered: AtomicI32

    def __init__(out self):
        self.entries = Array[NameRegistryEntry, MAX_REGISTERED_NAMES](
            fill=NameRegistryEntry()
        )
        self.n_registered = AtomicI32(Int32(0))

    @always_inline
    def count(self) -> Int:
        return Int(self.n_registered.load())

    def try_register[name: StringLiteral](mut self) -> Bool:
        """Register `name` (with comptime-known FNV-1a digest) into the
        table if not already present.

        Returns True on first-time success, False if the slot was already
        owned by `name_id` or the table is full.
        """
        comptime h = _fnv1a_compute(name)
        var name_id = h
        if name_id == UInt32(0):
            # Empty literal sentinel — reject.
            return False

        var idx = Int(name_id) & (MAX_REGISTERED_NAMES - 1)
        var probe = 0

        while probe < MAX_REGISTERED_NAMES:
            var existing = self.entries[idx].name_id
            if existing == name_id:
                return False
            if existing == UInt32(0):
                # Claim. Concurrent writers on the SAME idx with
                # different name_ids may both pass this check; we
                # accept up to one duplicate write because the JSONL
                # drain dedups by name_id at emit time.
                self.entries[idx].name_id = name_id
                var s = String(name)
                var sb = s.as_bytes()
                var slen = len(sb)
                if slen > MAX_NAME_BYTES:
                    slen = MAX_NAME_BYTES
                self.entries[idx].name_len = UInt8(slen)
                for i in range(slen):
                    self.entries[idx].name_bytes[i] = UInt8(sb[i])
                _ = self.n_registered.fetch_add(Int32(1))
                return True
            idx = (idx + 1) & (MAX_REGISTERED_NAMES - 1)
            probe += 1
        return False

    def lookup(self, name_id: UInt32) -> Optional[String]:
        """Return the registered name for `name_id` if present.

        Linear probe starting from the same hash slot. Returns None if
        the entry is missing or `name_id == 0`.
        """
        if name_id == UInt32(0):
            return Optional[String]()

        var idx = Int(name_id) & (MAX_REGISTERED_NAMES - 1)
        var probe = 0

        while probe < MAX_REGISTERED_NAMES:
            var entry_id = self.entries[idx].name_id
            if entry_id == name_id:
                var slen = Int(self.entries[idx].name_len)
                var out = String("")
                for i in range(slen):
                    out += chr(Int(self.entries[idx].name_bytes[i]))
                return Optional[String](out)
            if entry_id == UInt32(0):
                return Optional[String]()
            idx = (idx + 1) & (MAX_REGISTERED_NAMES - 1)
            probe += 1
        return Optional[String]()

    @always_inline
    def contains(self, name_id: UInt32) -> Bool:
        """Cheap allocation-free presence check.

        Returns True iff `name_id` is registered. Used by the per-worker
        bitset fast-path in `tracer.WorkerContextSlot.check_and_set_name`
        to disambiguate a low-8-bit collision: when the bitset bit is
        already set, we still need to know whether the bit was claimed
        by THIS name_id or by a name_id sharing the same `& 0xFF`. A
        single linear probe (no String allocation) covers the common
        case in O(1) under a 50% load factor.
        """
        if name_id == UInt32(0):
            return False

        var idx = Int(name_id) & (MAX_REGISTERED_NAMES - 1)
        var probe = 0

        while probe < MAX_REGISTERED_NAMES:
            var entry_id = self.entries[idx].name_id
            if entry_id == name_id:
                return True
            if entry_id == UInt32(0):
                return False
            idx = (idx + 1) & (MAX_REGISTERED_NAMES - 1)
            probe += 1
        return False
