# =============================================================================
# test_name_registry.mojo -- name ids + registration
# =============================================================================
#
# Verifies:
#   1. name_id[name]() is comptime-deterministic (same input → same digest).
#   2. name_id_of(s) matches name_id[name]() for the same string.
#   3. NameRegistry.try_register inserts on first call and returns False on
#      a second call with the same name.
#   4. NameRegistry.lookup returns the name for a registered name_id.
#   5. NameRegistry.lookup returns None for an unknown name_id.
#   6. A name whose id is 0 (the empty-slot marker) is refused.
#   7. Names sharing a home slot probe to the next slot, wrapping 255 -> 0.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_hash import fnv1a_32
from komira_name_registry import (
    MAX_NAME_BYTES,
    NameRegistry,
    name_id,
    name_id_of,
)


def test_fnv1a_comptime_literal() raises:
    """name_id[name]() returns a comptime-constant digest."""
    var h1 = name_id["engine.segment.execute"]()
    var h2 = name_id["engine.segment.execute"]()
    assert_equal(h1, h2, "comptime hash deterministic")
    var h3 = name_id["different.name"]()
    assert_true(h1 != h3, "different literals → different digests")
    print("  test_fnv1a_comptime_literal PASS, h1=", h1)


def test_fnv1a_runtime_matches_comptime() raises:
    """name_id_bytes matches the comptime digest for the same string."""
    var h_ct = name_id["worker.run"]()
    var h_rt = name_id_of(String("worker.run"))
    assert_equal(h_ct, h_rt, "comptime == runtime hash")
    print("  test_fnv1a_runtime_matches_comptime PASS")


def test_registry_first_register_returns_true() raises:
    """First try_register for a fresh name returns True."""
    var reg = NameRegistry()
    var ok = reg.try_register["engine.segment.execute"]()
    assert_true(ok, "first registration succeeds")
    assert_equal(reg.count(), Int(1), "n_registered = 1 after first insert")
    print("  test_registry_first_register_returns_true PASS")


def test_registry_double_register_returns_false() raises:
    """Second try_register with the same name returns False."""
    var reg = NameRegistry()
    _ = reg.try_register["worker.consume_morsel"]()
    var second = reg.try_register["worker.consume_morsel"]()
    assert_false(second, "second registration is no-op")
    assert_equal(reg.count(), Int(1), "n_registered stays at 1")
    print("  test_registry_double_register_returns_false PASS")


def test_registry_lookup_round_trip() raises:
    """lookup returns the original name for a registered name_id."""
    var reg = NameRegistry()
    _ = reg.try_register["my.custom.span"]()
    var nid = name_id["my.custom.span"]()
    var maybe = reg.lookup(nid)
    assert_true(Bool(maybe), "lookup returns Some")
    assert_equal(maybe.value(), String("my.custom.span"), "round-trip name")
    print("  test_registry_lookup_round_trip PASS")


def test_registry_lookup_unknown_returns_none() raises:
    """Lookup of an un-registered name_id returns None."""
    var reg = NameRegistry()
    _ = reg.try_register["a.b"]()
    var maybe = reg.lookup(UInt32(0xDEADBEEF))
    assert_false(Bool(maybe), "unknown name_id returns None")
    print("  test_registry_lookup_unknown_returns_none PASS")


def test_registry_multiple_names() raises:
    """Multiple distinct names register independently."""
    var reg = NameRegistry()
    _ = reg.try_register["a"]()
    _ = reg.try_register["b"]()
    _ = reg.try_register["c"]()
    assert_equal(reg.count(), Int(3), "three names registered")
    var ma = reg.lookup(name_id["a"]())
    var mb = reg.lookup(name_id["b"]())
    var mc = reg.lookup(name_id["c"]())
    assert_equal(ma.value(), String("a"), "a round-trip")
    assert_equal(mb.value(), String("b"), "b round-trip")
    assert_equal(mc.value(), String("c"), "c round-trip")
    print("  test_registry_multiple_names PASS")


def test_registry_lookup_non_ascii_is_byte_identical() raises:
    """A multi-byte name comes back as the identical bytes (`chr` per byte
    would re-encode every byte >= 0x80 as two)."""
    var reg = NameRegistry()
    _ = reg.try_register["span-é中😀"]()
    var nid = name_id["span-é中😀"]()
    var maybe = reg.lookup(nid)
    assert_true(Bool(maybe), "lookup returns Some")
    var got = maybe.value()
    var want = String("span-é中😀")
    assert_equal(len(got.as_bytes()), len(want.as_bytes()), "same byte length")
    assert_equal(got, want, "identical bytes")
    print("  test_registry_lookup_non_ascii_is_byte_identical PASS")


def test_registry_long_multibyte_name_truncates_on_a_boundary() raises:
    """A name over MAX_NAME_BYTES is cut, but never inside a code point."""
    # 40 two-byte code points = 80 bytes > 64; a cut at byte 64 is on a boundary
    # here, so use one leading ASCII byte to force a mid-sequence cut at 64.
    comptime NAME = "aééééééééééééééééééééééééééééééééééééééé"
    var reg = NameRegistry()
    _ = reg.try_register[NAME]()
    var maybe = reg.lookup(name_id[NAME]())
    assert_true(Bool(maybe), "lookup returns Some")
    var got = maybe.value()
    var n = len(got.as_bytes())
    assert_true(n <= 64, "stored name is within MAX_NAME_BYTES")
    assert_equal(n, 63, "cut backed up to the code-point boundary (1 + 31*2)")
    # Every code point is whole: the stored text is a prefix of the original.
    assert_true(String(NAME).startswith(got), "stored name is a prefix")
    print("  test_registry_long_multibyte_name_truncates_on_a_boundary PASS")


def test_name_id_is_the_shared_fnv1a_digest() raises:
    """The registry id is exactly komira_hash's FNV-1a 32-bit digest."""
    var s = String("engine.segment.execute")
    assert_equal(name_id["engine.segment.execute"](), fnv1a_32(s.as_bytes()))
    # Published FNV-1a 32-bit vectors: "" is the offset basis, "a" is 0xE40C292C.
    assert_equal(name_id[""](), UInt32(2166136261))
    assert_equal(name_id["a"](), UInt32(0xE40C292C))
    print("  test_name_id_is_the_shared_fnv1a_digest PASS")


def test_registry_empty_literal_registers_and_contains() raises:
    """The empty name hashes to the (non-zero) offset basis, so it is a real
    entry; `contains` is true only for registered ids and false for 0."""
    var reg = NameRegistry()
    assert_false(reg.contains(name_id["a"]()), "unregistered id absent")
    assert_true(reg.try_register[""](), "empty literal registers")
    assert_true(reg.contains(name_id[""]()), "empty literal present")
    assert_false(reg.contains(UInt32(0)), "id 0 is never present")
    assert_equal(reg.lookup(name_id[""]()).value(), String(""), "empty round-trip")
    assert_equal(reg.count(), Int(1))
    print("  test_registry_empty_literal_registers_and_contains PASS")


def test_registry_owns_independent_state() raises:
    """Two registries do not share slots or counters."""
    var a = NameRegistry()
    var b = NameRegistry()
    _ = a.try_register["only.in.a"]()
    assert_true(a.contains(name_id["only.in.a"]()), "a has it")
    assert_false(b.contains(name_id["only.in.a"]()), "b does not")
    assert_equal(a.count(), Int(1))
    assert_equal(b.count(), Int(0))
    assert_true(MAX_NAME_BYTES == 64, "documented name cap")
    print("  test_registry_owns_independent_state PASS")


def test_registry_rejects_a_name_whose_id_is_zero() raises:
    """Id 0 is the empty-slot marker, so a name hashing to 0 is refused and
    never becomes visible. "qzs0UD" is an FNV-1a 32-bit preimage of 0."""
    assert_equal(name_id["qzs0UD"](), UInt32(0), "comptime digest is 0")
    var zero = name_id_of(String("qzs0UD"))
    assert_equal(zero, UInt32(0), "runtime digest is 0")
    var reg = NameRegistry()
    assert_false(reg.try_register["qzs0UD"](), "id-0 name is refused")
    assert_equal(reg.count(), Int(0), "nothing counted")
    assert_false(reg.contains(zero), "id 0 not contained")
    assert_false(Bool(reg.lookup(zero)), "id 0 has no name")
    # A real name in the table does not make id 0 visible either.
    assert_true(reg.try_register["a"]())
    assert_false(reg.contains(zero), "id 0 still not contained")
    assert_false(Bool(reg.lookup(zero)), "id 0 still has no name")
    assert_equal(reg.count(), Int(1))
    print("  test_registry_rejects_a_name_whose_id_is_zero PASS")


def test_registry_probe_wraps_past_the_last_slot() raises:
    """Names sharing a home slot take the next free slot, wrapping from the
    last slot (255) to slot 0, and read back from a table that is not full
    (an empty slot ends the probe, so the chain must be the +1 chain).

    Fixture ids (FNV-1a 32): w443 0xA83F62FF and w757 0x37B95BFF share home
    slot 255, w902 0x314FB2FF too (never registered); w6 0x09472D00 has home
    slot 0, w311 0x794A0A01 home slot 1 (never registered)."""
    assert_equal(Int(name_id["w443"]()) & 255, 255)
    assert_equal(Int(name_id["w757"]()) & 255, 255)
    assert_equal(Int(name_id["w902"]()) & 255, 255)
    assert_equal(Int(name_id["w6"]()) & 255, 0)
    assert_equal(Int(name_id["w311"]()) & 255, 1)
    var reg = NameRegistry()
    assert_true(reg.try_register["w443"](), "w443 takes slot 255")
    assert_true(reg.try_register["w757"](), "w757 wraps to slot 0")
    # Slot 1 is still empty: w757 is found only if it sits right after 255.
    assert_true(reg.contains(name_id["w757"]()), "w757 found after the wrap")
    assert_equal(reg.lookup(name_id["w757"]()).value(), String("w757"))
    assert_false(reg.contains(name_id["w902"]()), "w902 absent (stops at 1)")
    assert_false(Bool(reg.lookup(name_id["w902"]())), "w902 has no name")
    assert_true(reg.try_register["w6"](), "w6 finds home 0 taken, takes 1")
    assert_false(reg.try_register["w757"](), "w757 again is a no-op")
    assert_equal(reg.count(), Int(3))
    assert_equal(reg.lookup(name_id["w443"]()).value(), String("w443"))
    assert_equal(reg.lookup(name_id["w757"]()).value(), String("w757"))
    assert_equal(reg.lookup(name_id["w6"]()).value(), String("w6"))
    assert_true(reg.contains(name_id["w6"]()), "w6 found one past home")
    assert_false(reg.contains(name_id["w311"]()), "w311 absent (stops at 2)")
    assert_false(Bool(reg.lookup(name_id["w311"]())), "w311 has no name")
    assert_false(reg.contains(name_id["w902"]()), "w902 absent (stops at 2)")
    print("  test_registry_probe_wraps_past_the_last_slot PASS")


def main() raises:
    print("test_name_registry")
    print("==================")
    test_fnv1a_comptime_literal()
    test_fnv1a_runtime_matches_comptime()
    test_registry_first_register_returns_true()
    test_registry_double_register_returns_false()
    test_registry_lookup_round_trip()
    test_registry_lookup_unknown_returns_none()
    test_registry_multiple_names()
    test_registry_lookup_non_ascii_is_byte_identical()
    test_registry_long_multibyte_name_truncates_on_a_boundary()
    test_name_id_is_the_shared_fnv1a_digest()
    test_registry_empty_literal_registers_and_contains()
    test_registry_owns_independent_state()
    test_registry_rejects_a_name_whose_id_is_zero()
    test_registry_probe_wraps_past_the_last_slot()
    print()
    print("ALL TESTS PASS")
