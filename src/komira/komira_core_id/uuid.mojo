# =============================================================================
# komira_core_id/uuid.mojo — UUIDv7 generator (RFC 9562 §5.7)
# =============================================================================
#
# A shared primitive for anything that mints time-ordered IDs (job stores,
# database rows, request ids).
#
# UUIDv7 layout (128 bits, big-endian on the wire):
#
#   0                   1                   2                   3
#   0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
#  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
#  |                       unix_ts_ms (48 bits)                    |
#  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
#  |   ver (4)   |          rand_a (12 bits)        | var(2)|      |
#  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
#  |                       rand_b (62 bits)                        |
#  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
#
#   bytes[0..6)  = unix_ts_ms, 48-bit big-endian milliseconds since epoch.
#   byte[6]      = (ver=0b0111 << 4) | high nibble of rand_a.
#   byte[7]      = low 8 bits of rand_a.
#   byte[8]      = (var=0b10 << 6) | high 6 bits of rand_b.
#   bytes[9..16) = remaining 56 bits of rand_b.
#
# Because the 48-bit millisecond timestamp is the high-order field and is
# stored big-endian, the 16-byte value compares (memcmp / unsigned-int
# order) in creation-time order — the whole point of v7: good DB primary
# keys + index locality.
#
# Encapsulation rule: the public surface is the `Uuid` value type
# (Copyable/Movable, 16 inline bytes), the `generate_uuidv7()` free fn,
# the `Uuidv7Generator` struct, and the format/parse helpers. NO
# UnsafePointer crosses this module's boundary. There is no raw pointer
# arithmetic in this file at all — all byte access goes through `SIMD` /
# `Array` indexing, so there is no `# SAFETY:` site to annotate.
#
# Time source:   komira_core_id.clock.now_unix_ms() — wall-clock ms since
#                Unix epoch (CLOCK_REALTIME, vDSO-accelerated). A caller that
#                needs a deterministic timestamp passes `now_ms` to
#                `generate_uuidv7` / `Uuidv7Generator.generate` instead; the
#                clock itself has no override. See clock.mojo's header for why
#                this package owns its clock.
# Randomness:    komira_core_id.entropy.system_entropy() — AWS-LC RAND_bytes
#                CSPRNG (the same AWS-LC entrypoint `komira_crypto` uses).
#                This package declares that C symbol itself, to stay a leaf;
#                see entropy.mojo's header. No RNG is reimplemented.
#
# Monotonicity: see `Uuidv7Generator` below.
# =============================================================================

from komira_atomic_alias import AtomicU64

from komira_core_id.clock import now_unix_ms
from komira_core_id.entropy import system_entropy


# -----------------------------------------------------------------------------
# Lowercase hex digit — package-local.
#
# Identical to `komira_crypto.hex._hex_digit_lower`. Duplicated (3 lines of
# total arithmetic on [0, 16) — no state, no cryptography) rather than imported,
# so that this package does not depend on `komira_crypto`; see `entropy.mojo`'s
# header for why that edge is worth avoiding. This package's test pins this
# against all 16 digit values.
# -----------------------------------------------------------------------------
@always_inline
def _hex_digit_lower(v: Int) -> String:
    """Return one lowercase hex digit (0-9, a-f) for v in [0, 16)."""
    if v < 10:
        return chr(0x30 + v)  # '0'..'9'
    return chr(0x61 + v - 10)  # 'a'..'f'


# -----------------------------------------------------------------------------
# Constants.
# -----------------------------------------------------------------------------

comptime _VERSION_V7: UInt8 = 0x70  # 0b0111_0000 — version nibble in byte[6].
comptime _VARIANT_RFC: UInt8 = 0x80  # 0b1000_0000 — variant bits in byte[8].

# rand_a is 12 bits; used as the per-millisecond monotonic sub-counter
# (RFC 9562 §6.2 "Method 1 — fixed-length dedicated counter bits").
comptime _RAND_A_MAX: UInt32 = 0x0FFF  # 4095 — max 12-bit value.

comptime _MS_MASK: UInt64 = (UInt64(1) << UInt64(48)) - UInt64(1)


# =============================================================================
# Uuid — 16-byte value type.
# =============================================================================


struct Uuid(ImplicitlyCopyable, Movable, Writable):
    """A 128-bit UUID stored as 16 big-endian bytes.

    The internal storage is two `SIMD[DType.uint8, 8]` halves (inline — no
    heap, no pointer). The byte order is the canonical RFC 9562 network
    order, so the raw bytes compare in the same order as the canonical
    hyphenated string, and (for v7) in creation-time order.
    """

    # REPRESENTATION: two 8-lane halves, not an `InlineArray` and not one
    # 16-lane vector.
    #
    # Not `InlineArray[UInt8, 16]`: in Mojo 1.0.0 a struct with an
    # `InlineArray` field cannot be ImplicitlyCopyable at all. `InlineArray`
    # conforms to `Copyable` (explicit `.copy()`) but not
    # `ImplicitlyCopyable`, so synthesis refuses ("cannot synthesize implicit
    # copy constructor because field '_bytes' has non-implicitly-copyable
    # type"), and there is no hand-written escape: `__copyinit__` is not a
    # hook in 1.0.0 and `@register_passable("trivial")` is removed. For a
    # FIELD the choice is a representation choice, not `^` versus `.copy()`.
    #
    # ⛔⛔ Not `SIMD[DType.uint8, 16]` either: THE REPRESENTATION MUST NOT BE
    # OVER-ALIGNED. A 16-lane vector has alignment 16, and that trips a Mojo
    # 1.0.0 layout defect:
    #
    #     `Optional[T]` mis-lays out `T` when `T` has a field whose type is an
    #     aggregate with alignment > 8 AND tail padding (natural size not a
    #     multiple of that alignment). Everything after that field shifts by
    #     the padding amount, so `T`'s TRAILING field reads adjacent stack
    #     memory -- a wrong Int, or a String whose length is a stack address,
    #     which then SEGFAULTS on the first compare.
    #
    # `Uuid` itself would be 16 bytes at alignment 16, so it has no tail
    # padding and looks innocent in isolation. The damage is done by a struct
    # that CONTAINS one: for example 4 Uuid + 2 Int64 + a List is 104 bytes
    # natural at alignment 16, padded to 112, and an `Optional` of a struct
    # holding that one returns a trailing String whose `byte_length()` is
    # garbage. The bounds of the rule:
    #   * the SAME struct at alignment 8 is fine;
    #   * an alignment-8 aggregate WITH tail padding is fine -- it takes
    #     over-alignment AND padding, not either alone;
    #   * `Optional[S]` where S is ITSELF over-aligned and tail-padded is FINE.
    #     The trigger needs S to be a FIELD of the payload type, not the
    #     payload type.
    #
    # ⇒ TWO 8-LANE HALVES. Same 16 bytes, same index order, same RFC 9562
    # network byte order, still ImplicitlyCopyable (SIMD is), still a
    # register-width move per half -- but alignment 8, so no struct that
    # embeds a `Uuid` can become over-aligned, and the whole class is
    # unreachable rather than fixed at each containing type. Any over-aligned,
    # tail-padded type is a latent crash the moment it is put in a struct that
    # goes into an `Optional`, with no diagnostic and no compile error.
    #
    # ⚠ DO NOT "SIMPLIFY" THIS BACK TO `SIMD[DType.uint8, 16]`. It is the
    # obvious edit, it compiles, and every Uuid unit test passes.
    var _lo: SIMD[DType.uint8, 8]
    var _hi: SIMD[DType.uint8, 8]

    @always_inline
    def _byte(self, i: Int) -> UInt8:
        """The i-th big-endian byte, across the two halves."""
        if i < 8:
            return self._lo[i]
        return self._hi[i - 8]

    @always_inline
    def _set_byte(mut self, i: Int, v: UInt8):
        """Set the i-th big-endian byte, across the two halves."""
        if i < 8:
            self._lo[i] = v
        else:
            self._hi[i - 8] = v

    @always_inline
    def __init__(out self):
        """The nil UUID (all 16 bytes zero)."""
        self._lo = SIMD[DType.uint8, 8](0)
        self._hi = SIMD[DType.uint8, 8](0)

    @always_inline
    def __init__(out self, bytes: Array[UInt8, 16]):
        """Wrap an existing 16-byte big-endian buffer."""
        self._lo = SIMD[DType.uint8, 8](0)
        self._hi = SIMD[DType.uint8, 8](0)
        for i in range(16):
            self._set_byte(i, bytes[i])

    @always_inline
    def byte_at(self, i: Int) -> UInt8:
        """Return the i-th big-endian byte (0..15). Caller bounds-checks."""
        return self._byte(i)

    @always_inline
    def as_bytes(self) -> Array[UInt8, 16]:
        """Return a copy of the 16 big-endian bytes."""
        var out = Array[UInt8, 16](fill=0)
        for i in range(16):
            out[i] = self._byte(i)
        return out^

    @always_inline
    def version(self) -> UInt8:
        """The 4-bit version nibble (7 for a UUIDv7)."""
        return self._byte(6) >> 4

    @always_inline
    def variant(self) -> UInt8:
        """The 2 high variant bits of byte[8] (0b10 == RFC 9562 variant)."""
        return self._byte(8) >> 6

    @always_inline
    def unix_ts_ms(self) -> UInt64:
        """Extract the embedded 48-bit big-endian millisecond timestamp."""
        var ms: UInt64 = 0
        for i in range(6):
            ms = (ms << UInt64(8)) | UInt64(self._byte(i))
        return ms

    @always_inline
    def __eq__(self, other: Self) -> Bool:
        for i in range(16):
            if self._byte(i) != other._byte(i):
                return False
        return True

    @always_inline
    def __ne__(self, other: Self) -> Bool:
        return not (self == other)

    @always_inline
    def __lt__(self, other: Self) -> Bool:
        """Lexicographic (unsigned big-endian) ordering of the 16 bytes.

        For v7 UUIDs this is creation-time order (the time field is the
        big-endian high-order prefix).
        """
        for i in range(16):
            var a = self._byte(i)
            var b = other._byte(i)
            if a != b:
                return a < b
        return False  # equal

    @always_inline
    def __le__(self, other: Self) -> Bool:
        return self == other or self < other

    def to_hyphenated(self) -> String:
        """Canonical 8-4-4-4-12 lowercase hyphenated form, e.g.
        "0190ab1c-3d4e-7f80-8a1b-2c3d4e5f6071"."""
        var out = String()
        # Hyphen positions are *after* bytes 3, 5, 7, 9 (0-indexed).
        for i in range(16):
            var b = Int(self._byte(i))
            out += _hex_digit_lower(b >> 4)
            out += _hex_digit_lower(b & 0x0F)
            if i == 3 or i == 5 or i == 7 or i == 9:
                out += "-"
        return out^

    def write_to[W: Writer, //](self, mut writer: W):
        writer.write(self.to_hyphenated())

    def __str__(self) -> String:
        return self.to_hyphenated()


# =============================================================================
# Parse.
# =============================================================================


@always_inline
def _hex_nibble(c: UInt8) raises -> UInt8:
    if c >= UInt8(ord("0")) and c <= UInt8(ord("9")):
        return c - UInt8(ord("0"))
    if c >= UInt8(ord("a")) and c <= UInt8(ord("f")):
        return c - UInt8(ord("a")) + UInt8(10)
    if c >= UInt8(ord("A")) and c <= UInt8(ord("F")):
        return c - UInt8(ord("A")) + UInt8(10)
    raise Error("Uuid.from_hyphenated: invalid hex nibble")


def from_hyphenated(s: String) raises -> Uuid:
    """Parse a canonical hyphenated UUID string into a `Uuid`.

    Accepts upper- or lower-case hex and ignores ASCII '-' separators
    (the same leniency as PostgreSQL's uuid text input). Raises if the input
    does not yield exactly 16 bytes.
    """
    var b = s.as_bytes()
    var out = Array[UInt8, 16](fill=0)
    var oi = 0
    var i = 0
    var n = len(b)
    while i < n and oi < 16:
        if b[i] == UInt8(ord("-")):
            i += 1
            continue
        if i + 1 >= n:
            raise Error("Uuid.from_hyphenated: truncated UUID hex")
        var hi = _hex_nibble(b[i])
        var lo = _hex_nibble(b[i + 1])
        out[oi] = (hi << 4) | lo
        oi += 1
        i += 2
    if oi != 16:
        raise Error("Uuid.from_hyphenated: did not yield 16 bytes")
    return Uuid(out)


# =============================================================================
# Pack helper — assemble the 16 bytes from (ms, rand_a, rand_b bytes).
# =============================================================================


@always_inline
def _pack_v7(ms: UInt64, rand_a: UInt32, rand_b: Array[UInt8, 8]) -> Uuid:
    """Assemble a v7 Uuid from a 48-bit ms, a 12-bit rand_a, and 8 bytes of
    rand_b entropy (only the low 62 bits of which survive the variant set)."""
    var out = Array[UInt8, 16](fill=0)
    var m = ms & _MS_MASK

    # bytes[0..6) — 48-bit big-endian timestamp.
    out[0] = UInt8((m >> UInt64(40)) & UInt64(0xFF))
    out[1] = UInt8((m >> UInt64(32)) & UInt64(0xFF))
    out[2] = UInt8((m >> UInt64(24)) & UInt64(0xFF))
    out[3] = UInt8((m >> UInt64(16)) & UInt64(0xFF))
    out[4] = UInt8((m >> UInt64(8)) & UInt64(0xFF))
    out[5] = UInt8(m & UInt64(0xFF))

    # byte[6] = ver(4) | high nibble of rand_a; byte[7] = low byte of rand_a.
    var ra = rand_a & _RAND_A_MAX
    out[6] = _VERSION_V7 | UInt8((ra >> UInt32(8)) & UInt32(0x0F))
    out[7] = UInt8(ra & UInt32(0xFF))

    # byte[8] = var(2) | high 6 bits of rand_b's first entropy byte.
    out[8] = _VARIANT_RFC | (rand_b[0] & UInt8(0x3F))
    # bytes[9..16) = the remaining 7 entropy bytes.
    for j in range(7):
        out[9 + j] = rand_b[1 + j]

    return Uuid(out)


# =============================================================================
# generate_uuidv7 — stateless single-shot generator.
# =============================================================================


def generate_uuidv7(now_ms: Optional[UInt64] = None) raises -> Uuid:
    """Generate a fresh UUIDv7 from the current wall clock + CSPRNG entropy.

    `now_ms`, when given, is the Unix-epoch millisecond timestamp to embed
    instead of reading the wall clock (a caller pinning time, e.g. a test).
    Only its low 48 bits are stored.

    Stateless: `rand_a` (12 bits) and `rand_b` (62 bits) are filled fresh
    from the CSPRNG on every call. Uniqueness is guaranteed with
    overwhelming probability (74 bits of entropy per ID).

    NOTE ON ORDERING: because `rand_a` is random (not a counter), two IDs
    minted within the SAME millisecond are time-ordered at ms granularity
    but their *relative* order within that millisecond is random. For a
    strict, collision-free, strictly-increasing sequence under a rapid
    burst — use `Uuidv7Generator` instead, which dedicates `rand_a` to a
    monotonic per-ms counter.
    """
    var ms: UInt64
    if now_ms:
        ms = now_ms.value()
    else:
        ms = UInt64(now_unix_ms())

    var entropy = Array[UInt8, 10](fill=0)
    system_entropy(Span[UInt8](entropy))

    # First 2 bytes seed rand_a (12 bits used); remaining 8 are rand_b.
    var rand_a = (UInt32(entropy[0]) << UInt32(8)) | UInt32(entropy[1])
    var rand_b = Array[UInt8, 8](fill=0)
    for j in range(8):
        rand_b[j] = entropy[2 + j]

    return _pack_v7(ms, rand_a, rand_b)


# =============================================================================
# Uuidv7Generator — monotonic, strictly-increasing generator.
# =============================================================================


struct Uuidv7Generator(Deinitable):
    """A monotonic UUIDv7 generator with a strictly-increasing guarantee.

    Implements RFC 9562 §6.2 "Method 1" (fixed-length dedicated counter
    bits): the 12-bit `rand_a` field is repurposed as a per-millisecond
    sub-sequence counter. Within a single millisecond the counter is bumped
    on each call so successive IDs are strictly ordered. `rand_b` (62 bits)
    stays fully random for global uniqueness across generators / processes.

    Monotonic state is packed into a single `Atomic[DType.uint64]`:

        state = (last_ms << 16) | last_seq        (seq is the low 16 bits)

    Each `generate()` runs a CAS loop:
      * read now_ms;
      * if now_ms > last_ms: new state = (now_ms << 16) | seed_seq, where
        seed_seq is a small random value in [0, 2048) so distinct
        generators don't all start their per-ms run at 0 (anti-collision
        across processes) while leaving headroom to count up to 4095;
      * else (clock equal or went backwards): keep last_ms, seq = last_seq+1.
        If seq would exceed 4095 (12-bit rand_a max), bump the embedded ms
        by 1 — this preserves strict ordering even if >4096 IDs are minted
        in one wall-clock millisecond, at the cost of the timestamp running
        slightly ahead of the wall clock until it catches up.

    THREAD-SAFETY CONTRACT:
      * `generate()` is fully thread-safe for CONCURRENT callers sharing one
        `Uuidv7Generator` instance. The monotonic (ms, seq) state is a single
        `Atomic[uint64]` updated by a `compare_exchange_weak` CAS loop, so
        two threads can never observe or commit the same (ms, seq) pair —
        every returned ID is strictly greater than every previously-returned
        ID from the same instance, regardless of interleaving.
      * The `rand_b` entropy is pulled per-call from the CSPRNG (itself
        thread-safe — AWS-LC RAND_bytes), so the 62 random low bits differ
        per ID even when two threads commit adjacent (ms, seq) values.
      * The struct is non-Movable / non-Copyable (it owns an `Atomic` field,
        which has a stable-address contract). Share ONE instance by
        reference (`ref`); do NOT clone it (a clone would have an
        independent counter and lose the cross-thread ordering guarantee).
        If you need to store one inside another struct or move it across a
        boundary, wrap it in `OwnedPointer[Uuidv7Generator]` (the usual
        idiom for `Atomic`-bearing state).
    """

    var _state: AtomicU64
    """Packed (last_ms << 16) | last_seq. seq occupies the low 16 bits;
    only values 0..4095 are ever stored (12-bit rand_a), the extra 4 bits
    of headroom keep the pack arithmetic branch-free."""

    def __init__(out self):
        """Construct a generator with empty monotonic state (no IDs minted
        yet). The first `generate()` seeds from the live wall clock."""
        self._state = AtomicU64(0)

    def generate(
        mut self, now_ms: Optional[UInt64] = None
    ) raises -> Uuid:
        """Return a strictly-increasing UUIDv7. Thread-safe across concurrent
        callers sharing this instance (see THREAD-SAFETY CONTRACT).

        `now_ms`, when given, is used as the current Unix-epoch millisecond
        time instead of reading the wall clock (a caller pinning time, e.g. a
        test). The monotonic guarantee holds either way."""
        var now: UInt64
        if now_ms:
            now = now_ms.value() & _MS_MASK
        else:
            now = UInt64(now_unix_ms()) & _MS_MASK

        # Per-call entropy: 8 bytes rand_b + 2 bytes to seed a fresh per-ms
        # run's starting counter.
        var entropy = Array[UInt8, 10](fill=0)
        system_entropy(Span[UInt8](entropy))
        var rand_b = Array[UInt8, 8](fill=0)
        for j in range(8):
            rand_b[j] = entropy[j]
        # Seed value in [0, 2048): leaves >=2048 of counter headroom.
        var seed_seq = (
            (UInt32(entropy[8]) << UInt32(8)) | UInt32(entropy[9])
        ) & UInt32(0x07FF)

        var chosen_ms: UInt64
        var chosen_seq: UInt32

        # `expected` starts at the observed state; on a failed CAS the stdlib
        # `compare_exchange` rewrites `expected` with the current value, so we
        # just recompute and retry without a separate reload.
        var expected = self._state.load()

        while True:
            var last_ms = (expected >> UInt64(16)) & _MS_MASK
            var last_seq = UInt32(expected & UInt64(0xFFFF))

            if now > last_ms:
                chosen_ms = now
                chosen_seq = seed_seq
            else:
                # Clock equal or moved backwards: stay on last_ms, bump seq.
                chosen_ms = last_ms
                chosen_seq = last_seq + UInt32(1)
                if chosen_seq > _RAND_A_MAX:
                    # 12-bit counter exhausted within this ms — roll the
                    # embedded timestamp forward to preserve strict order.
                    chosen_ms = (last_ms + UInt64(1)) & _MS_MASK
                    chosen_seq = 0

            var new_state = (chosen_ms << UInt64(16)) | UInt64(
                chosen_seq & UInt32(0xFFFF)
            )
            # CAS: commit our (ms, seq). On failure `expected` is refreshed
            # with the value another thread committed; loop and retry.
            if self._state.compare_exchange(expected, new_state):
                break

        return _pack_v7(chosen_ms, chosen_seq, rand_b)
