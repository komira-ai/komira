# =============================================================================
# test_pack_byte_spans.mojo — Q1-OPT-2 packing scheme unit tests
# =============================================================================
#
# Validates the byte-span → Int64 packing scheme used to route small-width
# STRING composite keys through the i64-keyed dense HashAggTable substrate
# (Q1-OPT-2). The CRITICAL invariant tested here is COLLISION SAFETY across
# heterogeneous lengths: two distinct (byte-tuple) inputs MUST map to distinct
# packed-i64 outputs.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_engine_operators.stage_primitives.pack_byte_spans import (
    pack_2_byte_spans_u64,
    unpack_2_byte_spans_u64,
    pack_3_byte_spans_u64,
    unpack_3_byte_spans_u64,
)


def _bytes_of(s: String) -> List[UInt8]:
    var sb = s.as_bytes()
    var out = List[UInt8](capacity=len(sb))
    for k in range(len(sb)):
        out.append(sb[k])
    return out^


def _bytes_eq(a: List[UInt8], b: List[UInt8]) -> Bool:
    if len(a) != len(b):
        return False
    for k in range(len(a)):
        if a[k] != b[k]:
            return False
    return True


# =============================================================================
# §1 — Basic pack/unpack round-trip
# =============================================================================


def test_pack2_roundtrip_q1_shape() raises:
    """Q1's actual shape — single-char STRINGs round-trip exactly."""
    var c0 = _bytes_of(String("A"))
    var c1 = _bytes_of(String("F"))
    var packed_opt = pack_2_byte_spans_u64(Span(c0), Span(c1))
    assert_true(Bool(packed_opt), "1-byte components fit")
    var packed = packed_opt.value()

    var unpacked = unpack_2_byte_spans_u64(packed)
    assert_true(_bytes_eq(unpacked[0], c0), "c0 round-trip")
    assert_true(_bytes_eq(unpacked[1], c1), "c1 round-trip")


def test_pack2_roundtrip_3_byte_max() raises:
    """3-byte components (the max for arity-2 packing)."""
    var c0 = _bytes_of(String("ABC"))
    var c1 = _bytes_of(String("XYZ"))
    var packed_opt = pack_2_byte_spans_u64(Span(c0), Span(c1))
    assert_true(Bool(packed_opt), "3-byte components fit")
    var unpacked = unpack_2_byte_spans_u64(packed_opt.value())
    assert_true(_bytes_eq(unpacked[0], c0), "c0 round-trip 3-byte")
    assert_true(_bytes_eq(unpacked[1], c1), "c1 round-trip 3-byte")


def test_pack2_overflow_returns_none() raises:
    """Components > 3 bytes must return None (caller falls back)."""
    var c0 = _bytes_of(String("ABCD"))   # 4 bytes -> overflow
    var c1 = _bytes_of(String("F"))
    var packed_opt = pack_2_byte_spans_u64(Span(c0), Span(c1))
    assert_false(Bool(packed_opt), "4-byte component overflows arity-2 scheme")

    var c2 = _bytes_of(String("A"))
    var c3 = _bytes_of(String("MNOPQ"))  # 5 bytes -> overflow
    var packed_opt2 = pack_2_byte_spans_u64(Span(c2), Span(c3))
    assert_false(Bool(packed_opt2), "5-byte 2nd component also overflows")


def test_pack2_empty_components() raises:
    """Empty components (zero-length) are valid."""
    var c0 = _bytes_of(String(""))
    var c1 = _bytes_of(String("F"))
    var packed_opt = pack_2_byte_spans_u64(Span(c0), Span(c1))
    assert_true(Bool(packed_opt), "empty c0 fits")
    var unpacked = unpack_2_byte_spans_u64(packed_opt.value())
    assert_equal(len(unpacked[0]), 0, "empty c0 round-trips to 0-len")
    assert_true(_bytes_eq(unpacked[1], c1), "c1 round-trips")


# =============================================================================
# §2 — CRITICAL: collision-safety across heterogeneous lengths
# =============================================================================


def test_pack2_collision_AB_vs_A_B() raises:
    """The adversarial pair from the dispatch brief:
       ('A', 'B') MUST hash to a different packed-i64 than ('AB', '').
       Without length-prefix encoding, a naive scheme `(c0_bytes << K | c1_bytes)`
       would conflate them. Our scheme encodes len0=1 vs len0=2 in the high
       byte, guaranteeing distinct packed values.
    """
    var c0a = _bytes_of(String("A"))
    var c1a = _bytes_of(String("B"))
    var c0b = _bytes_of(String("AB"))
    var c1b = _bytes_of(String(""))

    var pa = pack_2_byte_spans_u64(Span(c0a), Span(c1a))
    var pb = pack_2_byte_spans_u64(Span(c0b), Span(c1b))
    assert_true(Bool(pa), "('A','B') packs")
    assert_true(Bool(pb), "('AB','') packs")
    assert_true(
        pa.value() != pb.value(),
        "('A','B') and ('AB','') MUST pack to distinct i64",
    )

    # And vice versa — ('', 'AB') vs ('A', 'B') etc.
    var c0c = _bytes_of(String(""))
    var c1c = _bytes_of(String("AB"))
    var pc = pack_2_byte_spans_u64(Span(c0c), Span(c1c))
    assert_true(Bool(pc), "('', 'AB') packs")
    assert_true(
        pa.value() != pc.value(),
        "('A','B') and ('', 'AB') MUST pack to distinct i64",
    )
    assert_true(
        pb.value() != pc.value(),
        "('AB','') and ('', 'AB') MUST pack to distinct i64",
    )


def test_pack2_q1_groups_distinct() raises:
    """Q1's 6 actual groups (l_returnflag x l_linestatus) — each pair MUST
    map to a distinct packed-i64. With 4 distinct returnflags (A/N/R) x
    2 linestatus (F/O), we get up to 6 distinct groups."""
    var packed_set = List[Int64]()
    var flags = List[String]()
    flags.append(String("A"))
    flags.append(String("N"))
    flags.append(String("R"))
    var lstats = List[String]()
    lstats.append(String("F"))
    lstats.append(String("O"))

    var i = 0
    while i < len(flags):
        var j = 0
        while j < len(lstats):
            var c0 = _bytes_of(flags[i])
            var c1 = _bytes_of(lstats[j])
            var p = pack_2_byte_spans_u64(Span(c0), Span(c1))
            assert_true(Bool(p), "Q1 single-char keys pack")
            packed_set.append(p.value())
            j = j + 1
        i = i + 1
    assert_equal(len(packed_set), 6, "6 (flag, lstat) combos")
    # All distinct.
    for a in range(len(packed_set)):
        for b in range(a + 1, len(packed_set)):
            assert_true(
                packed_set[a] != packed_set[b],
                "Q1 groups must be pairwise distinct",
            )


def test_pack2_full_3byte_collision_audit() raises:
    """Brute-force check: for a curated set of (c0, c1) tuples spanning
    lengths 0..3 and several distinct byte patterns, every pair must pack
    to distinct i64. Catches off-by-one collisions in the length tag."""
    var s0 = List[String]()
    var s1 = List[String]()
    s0.append(String(""));    s1.append(String(""))
    s0.append(String("A"));   s1.append(String(""))
    s0.append(String(""));    s1.append(String("A"))
    s0.append(String("A"));   s1.append(String("A"))
    s0.append(String("AB"));  s1.append(String(""))
    s0.append(String(""));    s1.append(String("AB"))
    s0.append(String("A"));   s1.append(String("B"))
    s0.append(String("AB"));  s1.append(String("CD"))
    s0.append(String("ABC")); s1.append(String(""))
    s0.append(String(""));    s1.append(String("ABC"))
    s0.append(String("ABC")); s1.append(String("XYZ"))
    s0.append(String("A"));   s1.append(String("BC"))
    s0.append(String("AB"));  s1.append(String("C"))

    var packed = List[Int64]()
    for k in range(len(s0)):
        var c0 = _bytes_of(s0[k])
        var c1 = _bytes_of(s1[k])
        var p = pack_2_byte_spans_u64(Span(c0), Span(c1))
        assert_true(Bool(p), "sample fits the scheme")
        packed.append(p.value())

    for a in range(len(packed)):
        for b in range(a + 1, len(packed)):
            assert_true(
                packed[a] != packed[b],
                "samples must pack to pairwise-distinct i64",
            )


# =============================================================================
# §3 — Arity-3 packing
# =============================================================================


def test_pack3_roundtrip_1byte() raises:
    """Arity-3, 1-byte per component."""
    var c0 = _bytes_of(String("A"))
    var c1 = _bytes_of(String("B"))
    var c2 = _bytes_of(String("C"))
    var p = pack_3_byte_spans_u64(Span(c0), Span(c1), Span(c2))
    assert_true(Bool(p), "1-byte arity-3 fits")
    var u = unpack_3_byte_spans_u64(p.value())
    assert_true(_bytes_eq(u[0], c0), "arity-3 c0 round-trip")
    assert_true(_bytes_eq(u[1], c1), "arity-3 c1 round-trip")
    assert_true(_bytes_eq(u[2], c2), "arity-3 c2 round-trip")


def test_pack3_overflow_returns_none() raises:
    """3-byte component overflows arity-3 scheme (max 2 bytes per)."""
    var c0 = _bytes_of(String("ABC"))   # 3 bytes -> overflow
    var c1 = _bytes_of(String("X"))
    var c2 = _bytes_of(String("Y"))
    var p = pack_3_byte_spans_u64(Span(c0), Span(c1), Span(c2))
    assert_false(Bool(p), "3-byte component overflows arity-3 scheme")


def test_pack3_collision_safety() raises:
    """Arity-3 length-prefix prevents (A, B, C) vs (AB, _, C) collisions."""
    var s1_a = _bytes_of(String("A"))
    var s1_b = _bytes_of(String("B"))
    var s1_c = _bytes_of(String("C"))

    var s2_a = _bytes_of(String("AB"))
    var s2_b = _bytes_of(String(""))
    var s2_c = _bytes_of(String("C"))

    var p1 = pack_3_byte_spans_u64(Span(s1_a), Span(s1_b), Span(s1_c))
    var p2 = pack_3_byte_spans_u64(Span(s2_a), Span(s2_b), Span(s2_c))
    assert_true(Bool(p1), "p1 fits")
    assert_true(Bool(p2), "p2 fits")
    assert_true(
        p1.value() != p2.value(),
        "('A','B','C') and ('AB','','C') must pack distinct",
    )


def main() raises:
    var suite = TestSuite()
    suite.test[test_pack2_roundtrip_q1_shape]()
    suite.test[test_pack2_roundtrip_3_byte_max]()
    suite.test[test_pack2_overflow_returns_none]()
    suite.test[test_pack2_empty_components]()
    suite.test[test_pack2_collision_AB_vs_A_B]()
    suite.test[test_pack2_q1_groups_distinct]()
    suite.test[test_pack2_full_3byte_collision_audit]()
    suite.test[test_pack3_roundtrip_1byte]()
    suite.test[test_pack3_overflow_returns_none]()
    suite.test[test_pack3_collision_safety]()
    suite^.run()
