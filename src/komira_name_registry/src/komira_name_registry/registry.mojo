# =============================================================================
# registry.mojo -- interned-name registry: comptime name ids + a fixed table
# =============================================================================
#
# Per-call-site name interning:
#   1. `name_id[name]()` is the FNV-1a 32-bit digest of a `StringLiteral`,
#      evaluated at compile time, so the id is a literal at the call site.
#   2. The first registration of a name inserts it into a fixed-size
#      open-addressing table (at most `MAX_REGISTERED_NAMES` names).
#   3. A drain reads the table back by id (`lookup`, `contains`).
#
# CONCURRENCY CONTRACT. `n_registered` is atomic, but the slot claim and the
# name-byte stores are plain writes: two threads registering at the same time
# can interleave, and a concurrent `lookup` can observe an id whose bytes are
# not yet written. Register from one thread at a time (or under the caller's
# own lock); once registration has finished, any number of threads may call
# `lookup`, `contains` and `count` concurrently. Registering the same name
# twice is harmless (the second call is a no-op).
# =============================================================================

from std.atomic import Atomic
from komira_hash import fnv1a_32


# Hard cap on distinct names per process. Power of two: required for the
# linear-probing wrap.
comptime MAX_REGISTERED_NAMES: Int = 256
comptime MAX_NAME_BYTES: Int = 64


def name_id_of(name: String) -> UInt32:
    """FNV-1a 32-bit id of `name`, computed at run time.

    Equal to `name_id[name]()` for the same bytes.
    """
    return fnv1a_32(name.as_bytes())


def _name_id_compute(name: StringLiteral) -> UInt32:
    var s = String(name)
    return fnv1a_32(s.as_bytes())


@always_inline
def name_id[name: StringLiteral]() -> UInt32:
    """Compile-time FNV-1a 32-bit id of a static literal; zero run-time cost."""
    comptime h = _name_id_compute(name)
    return h


# -----------------------------------------------------------------------------
# NameRegistryEntry -- one slot of the open-addressing hash table.
# Empty when name_id == 0. An id of 0 is reserved as the empty-slot marker, so
# a name that hashes to 0 is rejected at registration time.
# -----------------------------------------------------------------------------


struct NameRegistryEntry(Copyable, Movable, Deinitable):
    """One slot of the name registry table.

    POD invariant: `Array[UInt8, MAX_NAME_BYTES]` + scalars only.
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
# NameRegistry -- open-addressing table with linear probing. See the
# concurrency contract in the file header.
# -----------------------------------------------------------------------------


struct NameRegistry(Deinitable):
    """Fixed-capacity name registry.

    Layout: `entries: Array[NameRegistryEntry, MAX_REGISTERED_NAMES]`,
    linear probing. Max load 50% -- at MAX_REGISTERED_NAMES/2 entries the
    probe-chain length stays bounded.

    Concurrency: see the contract in the file header (register serially,
    read concurrently once registration is done).
    """

    var entries: Array[NameRegistryEntry, MAX_REGISTERED_NAMES]
    var n_registered: Atomic[DType.int32]

    def __init__(out self):
        self.entries = Array[NameRegistryEntry, MAX_REGISTERED_NAMES](
            fill=NameRegistryEntry()
        )
        self.n_registered = Atomic[DType.int32](Int32(0))

    @always_inline
    def count(self) -> Int:
        return Int(self.n_registered.load())

    def try_register[name: StringLiteral](mut self) -> Bool:
        """Register `name` (with its comptime-known id) into the table if not
        already present.

        Returns True on first-time success, False if the slot was already
        owned by `name_id` or the table is full.
        """
        comptime h = _name_id_compute(name)
        var name_id = h
        if name_id == UInt32(0):
            # Reserved empty-slot marker -- reject.
            return False

        var idx = Int(name_id) & (MAX_REGISTERED_NAMES - 1)
        var probe = 0

        while probe < MAX_REGISTERED_NAMES:
            var existing = self.entries[idx].name_id
            if existing == name_id:
                return False
            if existing == UInt32(0):
                # Claim the slot (callers serialise registration).
                self.entries[idx].name_id = name_id
                var s = String(name)
                var sb = s.as_bytes()
                var slen = len(sb)
                if slen > MAX_NAME_BYTES:
                    slen = MAX_NAME_BYTES
                    # Never cut inside a multi-byte sequence: back up past
                    # continuation bytes (0b10xxxxxx) so the stored name stays
                    # valid UTF-8.
                    while slen > 0 and (UInt8(sb[slen]) & UInt8(0xC0)) == UInt8(0x80):  # cov: unreachable slen > 0 never fails: byte 0 of a UTF-8 literal is a lead byte, not 0b10xxxxxx
                        slen -= 1
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
                # Copy the stored bytes verbatim. Re-encoding each byte as a
                # code point (`chr`) would turn every byte >= 0x80 of a
                # multi-byte name into a two-byte sequence.
                var raw = List[UInt8](capacity=slen)
                for i in range(slen):
                    raw.append(self.entries[idx].name_bytes[i])
                var out = String(unsafe_from_utf8=Span(raw))
                return Optional[String](out)
            if entry_id == UInt32(0):
                return Optional[String]()
            idx = (idx + 1) & (MAX_REGISTERED_NAMES - 1)
            probe += 1
        return Optional[String]()

    @always_inline
    def contains(self, name_id: UInt32) -> Bool:
        """Cheap allocation-free presence check.

        Returns True iff `name_id` is registered: a single linear probe,
        O(1) under a 50% load factor, with no String allocation.
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
