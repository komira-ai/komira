# =============================================================================
# test_uuid_v7.mojo — unit tests for the UUIDv7 generator
# =============================================================================
#
# Validates `komira_uuid/uuid.mojo`:
#   (a) format <-> parse round-trip (canonical string <-> 16 bytes);
#   (b) version nibble == 7, variant bits == 0b10;
#   (c) monotonic sort: generate N in a tight loop -> the 16-byte
#       big-endian values are strictly increasing (time-ordered) and
#       all unique;
#   (d) timestamp extraction: the embedded ms equals an explicitly passed
#       `now_ms`, and ~= now on a live read.
#   (e) the two package-local helpers that stand in for `komira_crypto`
#       imports (`_hex_digit_lower`, `entropy.system_entropy`) behave like
#       the crypto originals — see `entropy.mojo`.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false, assert_raises

from komira_uuid.uuid import (
    Uuid,
    generate_uuidv7,
    Uuidv7Generator,
    from_hyphenated,
)
from komira_uuid.clock import now_unix_ms
from komira_uuid.entropy import system_entropy


# -----------------------------------------------------------------------------
# (a) format <-> parse round-trip.
# -----------------------------------------------------------------------------


def test_round_trip_known_string() raises:
    """A known canonical string parses to 16 bytes and re-formats identically."""
    var s = String("0190ab1c-3d4e-7f80-8a1b-2c3d4e5f6071")
    var u = from_hyphenated(s)
    assert_equal(u.to_hyphenated(), s)


def test_round_trip_generated() raises:
    """A freshly generated v7 round-trips through string and back."""
    var u = generate_uuidv7()
    var s = u.to_hyphenated()
    # Canonical form is 36 chars: 32 hex + 4 hyphens.
    assert_equal(s.byte_length(), 36)
    var parsed = from_hyphenated(s)
    assert_true(parsed == u)
    # Byte-for-byte equality of the 16-byte payload.
    for i in range(16):
        assert_equal(parsed.byte_at(i), u.byte_at(i))


def test_hex_digit_lower_all_16_values() raises:
    """Every nibble 0x0..0xf renders as the correct LOWERCASE hex digit.

    Guards `komira_uuid.uuid._hex_digit_lower`, a package-local copy of
    `komira_crypto.hex._hex_digit_lower` kept so that this package does not
    depend on `komira_crypto`. The realistic failure mode of a duplicated
    digit table is an off-by-one at the 9->a boundary, which
    `test_round_trip_known_string`'s single fixed string does not exercise
    across all 16 values. This does: the bytes
    0x01,0x23,..,0xef place every nibble value in a known position.
    """
    var s = String("01234567-89ab-cdef-0123-456789abcdef")
    var u = from_hyphenated(s)
    # Re-formatting runs _hex_digit_lower over all 32 nibbles.
    assert_equal(u.to_hyphenated(), s)
    # ...and the letter digits really are lowercase, not uppercase.
    assert_equal(u.to_hyphenated(), u.to_hyphenated().lower())


def test_entropy_is_live_csprng() raises:
    """`komira_uuid.entropy.system_entropy` returns real random bytes.

    Guards the package-local `RAND_bytes` declaration that stands in for
    `komira_crypto.rng.system_entropy`. The failure this
    exists to catch is the SILENT one: a broken or omitted FFI declaration that
    leaves the destination at its `fill=0` initial value would make every
    UUIDv7's `rand_a`/`rand_b` a constant, and NO format/parse/monotonicity
    assertion in this file would notice.

    Two independent 32-byte draws must (a) not be all-zero and (b) not be
    equal. P(spurious failure) is 2^-256 per clause.
    """
    var a = Array[UInt8, 32](fill=0)
    var b = Array[UInt8, 32](fill=0)
    system_entropy(Span[UInt8](a))
    system_entropy(Span[UInt8](b))

    var a_nonzero = False
    var b_nonzero = False
    var differ = False
    for i in range(32):
        if a[i] != UInt8(0):
            a_nonzero = True
        if b[i] != UInt8(0):
            b_nonzero = True
        if a[i] != b[i]:
            differ = True
    assert_true(a_nonzero, "system_entropy left the buffer all-zero (draw 1)")
    assert_true(b_nonzero, "system_entropy left the buffer all-zero (draw 2)")
    assert_true(differ, "two system_entropy draws were byte-identical")


def test_generated_uuids_have_varying_random_bits() raises:
    """The `rand_b` field actually varies across UUIDs minted in the same ms.

    End-to-end companion to `test_entropy_is_live_csprng`: proves the entropy
    reaches the UUID, not just the buffer. Bytes 10..15 are pure `rand_b` (no
    timestamp, no version/variant bits), so under a pinned `now_ms` they are
    the ONLY thing that can differ between two `generate_uuidv7()` results.
    """
    var pinned = UInt64(1_700_000_000_000)
    var u1 = generate_uuidv7(now_ms=pinned)
    var u2 = generate_uuidv7(now_ms=pinned)

    var rand_b_differs = False
    for i in range(10, 16):
        if u1.byte_at(i) != u2.byte_at(i):
            rand_b_differs = True
    assert_true(
        rand_b_differs,
        "two UUIDv7s minted at the same pinned ms had identical rand_b — the"
        " CSPRNG is not reaching the generator",
    )


def test_parse_uppercase() raises:
    """Uppercase hex parses identically to lowercase (canonical out is lower)."""
    var lower = String("0190ab1c-3d4e-7f80-8a1b-2c3d4e5f6071")
    var upper = String("0190AB1C-3D4E-7F80-8A1B-2C3D4E5F6071")
    assert_true(from_hyphenated(lower) == from_hyphenated(upper))


def test_parse_rejects_short() raises:
    """A truncated string raises rather than silently zero-padding."""
    with assert_raises():
        _ = from_hyphenated(String("0190ab1c-3d4e"))


def test_parse_rejects_bad_nibble() raises:
    """A non-hex character raises."""
    with assert_raises():
        _ = from_hyphenated(String("0190ab1c-3d4e-7f80-8a1b-2c3d4e5f60zz"))


# -----------------------------------------------------------------------------
# (b) version + variant bits.
# -----------------------------------------------------------------------------


def test_version_is_7() raises:
    """Every generated UUID has version nibble == 7."""
    var u = generate_uuidv7()
    assert_equal(Int(u.version()), 7)
    # Byte[6] high nibble is the version.
    assert_equal(Int(u.byte_at(6) >> 4), 7)


def test_variant_is_rfc() raises:
    """Variant bits (top 2 of byte[8]) == 0b10."""
    var u = generate_uuidv7()
    assert_equal(Int(u.variant()), 2)  # 0b10
    assert_equal(Int(u.byte_at(8) >> 6), 2)


def test_version_variant_on_generator() raises:
    """The monotonic generator also sets ver=7 / var=0b10."""
    var gen = Uuidv7Generator()
    var u = gen.generate()
    assert_equal(Int(u.version()), 7)
    assert_equal(Int(u.variant()), 2)


# -----------------------------------------------------------------------------
# (c) monotonic sort + uniqueness.
# -----------------------------------------------------------------------------


def _less(a: Uuid, b: Uuid) -> Bool:
    """Unsigned big-endian 16-byte compare (creation-time order for v7)."""
    return a < b


def test_monotonic_strictly_increasing() raises:
    """Generate N in a tight loop -> strictly increasing (no equal/disorder)
    and all unique. This is the load-bearing v7 property."""
    var n = 1000
    var prev = Uuid()  # nil UUID — all zero, < any real v7.
    var gen = Uuidv7Generator()
    for k in range(n):
        var cur = gen.generate()
        if k > 0:
            # Strictly greater than the previous one.
            assert_true(prev < cur)
            assert_false(cur < prev)
            assert_true(prev != cur)
        prev = cur


def test_monotonic_unique_pairwise() raises:
    """A smaller batch, checked for full pairwise uniqueness (O(n^2) but
    n is small) — guards against any same-(ms,seq) collision."""
    var n = 200
    var ids = List[Uuid]()
    var gen = Uuidv7Generator()
    for _ in range(n):
        ids.append(gen.generate())
    for i in range(n):
        for j in range(i + 1, n):
            assert_true(ids[i] != ids[j])


def test_generator_ordering_survives_string() raises:
    """The string form sorts in the same order as the byte form (since the
    canonical hex is just the big-endian bytes)."""
    var gen = Uuidv7Generator()
    var a = gen.generate()
    var b = gen.generate()
    assert_true(a < b)
    # Lexicographic string compare must agree with byte compare.
    assert_true(a.to_hyphenated() < b.to_hyphenated())


# -----------------------------------------------------------------------------
# (d) timestamp extraction.
# -----------------------------------------------------------------------------


def test_timestamp_extraction_pinned() raises:
    """With `now_ms` pinned, the embedded ms equals the pinned value."""
    # 0x0190AB1C3D4E = a plausible 48-bit ms value.
    var pinned: UInt64 = 0x0190AB1C3D4E
    var u = generate_uuidv7(now_ms=pinned)
    assert_equal(u.unix_ts_ms(), pinned)
    # Verify the first 6 bytes are exactly the big-endian ms.
    assert_equal(Int(u.byte_at(0)), 0x01)
    assert_equal(Int(u.byte_at(1)), 0x90)
    assert_equal(Int(u.byte_at(2)), 0xAB)
    assert_equal(Int(u.byte_at(3)), 0x1C)
    assert_equal(Int(u.byte_at(4)), 0x3D)
    assert_equal(Int(u.byte_at(5)), 0x4E)


def test_generator_pinned_now_ms() raises:
    """`Uuidv7Generator.generate(now_ms=...)` embeds the pinned ms, and a
    pinned clock that goes BACKWARDS still yields strictly increasing IDs
    (the generator stays on its last ms and bumps the counter)."""
    var gen = Uuidv7Generator()
    var pinned: UInt64 = 0x0190AB1C3D4E
    var a = gen.generate(now_ms=pinned)
    var b = gen.generate(now_ms=pinned)
    assert_equal(a.unix_ts_ms(), pinned)
    assert_equal(b.unix_ts_ms(), pinned)
    assert_true(a < b)
    var c = gen.generate(now_ms=pinned - UInt64(5000))
    assert_equal(c.unix_ts_ms(), pinned)
    assert_true(b < c)


def test_timestamp_extraction_live() raises:
    """Without `now_ms`, the embedded ms is within a few seconds of now."""
    var before = UInt64(now_unix_ms())
    var u = generate_uuidv7()
    var after = UInt64(now_unix_ms())
    var ts = u.unix_ts_ms()
    # ts must lie in [before-1s, after+1s] (allow clock skew / scheduling).
    assert_true(ts + UInt64(1000) >= before)
    assert_true(ts <= after + UInt64(1000))


def main() raises:
    test_round_trip_known_string()
    test_round_trip_generated()
    test_hex_digit_lower_all_16_values()
    test_entropy_is_live_csprng()
    test_generated_uuids_have_varying_random_bits()
    test_parse_uppercase()
    test_parse_rejects_short()
    test_parse_rejects_bad_nibble()
    test_version_is_7()
    test_variant_is_rfc()
    test_version_variant_on_generator()
    test_monotonic_strictly_increasing()
    test_monotonic_unique_pairwise()
    test_generator_ordering_survives_string()
    test_timestamp_extraction_pinned()
    test_generator_pinned_now_ms()
    test_timestamp_extraction_live()
    print("all UUIDv7 tests passed")
