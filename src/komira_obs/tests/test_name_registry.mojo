# =============================================================================
# test_name_registry.mojo — FNV-1a hash + lazy registration
# =============================================================================
#
# Verifies:
#   1. fnv1a_hash[name]() is comptime-deterministic (same input → same digest).
#   2. fnv1a_hash_bytes(s) matches fnv1a_hash[name]() for the same string.
#   3. NameRegistry.try_register inserts on first call and returns False on
#      a second call with the same name.
#   4. NameRegistry.lookup returns the name for a registered name_id.
#   5. NameRegistry.lookup returns None for an unknown name_id.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_obs.name_registry import (
    NameRegistry,
    fnv1a_hash,
    fnv1a_hash_bytes,
    _fnv1a_compute,
)


def test_fnv1a_comptime_literal() raises:
    """fnv1a_hash[name]() returns a comptime-constant digest."""
    var h1 = fnv1a_hash["engine.segment.execute"]()
    var h2 = fnv1a_hash["engine.segment.execute"]()
    assert_equal(h1, h2, "comptime hash deterministic")
    var h3 = fnv1a_hash["different.name"]()
    assert_true(h1 != h3, "different literals → different digests")
    print("  test_fnv1a_comptime_literal PASS, h1=", h1)


def test_fnv1a_runtime_matches_comptime() raises:
    """fnv1a_hash_bytes matches the comptime digest for the same string."""
    var h_ct = fnv1a_hash["worker.run"]()
    var h_rt = fnv1a_hash_bytes(String("worker.run"))
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
    var nid = fnv1a_hash["my.custom.span"]()
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
    var ma = reg.lookup(fnv1a_hash["a"]())
    var mb = reg.lookup(fnv1a_hash["b"]())
    var mc = reg.lookup(fnv1a_hash["c"]())
    assert_equal(ma.value(), String("a"), "a round-trip")
    assert_equal(mb.value(), String("b"), "b round-trip")
    assert_equal(mc.value(), String("c"), "c round-trip")
    print("  test_registry_multiple_names PASS")


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
    print()
    print("ALL TESTS PASS")
