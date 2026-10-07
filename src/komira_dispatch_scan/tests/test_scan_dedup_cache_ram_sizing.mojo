# =============================================================================
# tests/test_scan_dedup_cache_ram_sizing.mojo
#
# SCAN-DEDUP RAM-ADAPTIVE BUDGET — the guard for the RAM-sized byte budget.
#
# On a persistent EngineContext scan-dedup amortization drives TPC-H geomean
# 4.58 -> 2.14x, but ONLY when the cache byte budget holds the working set
# (TPC-H's 55 scans = 1.71 GiB). At a fixed 1 GiB cap the working set
# THRASHES the LRU -> full re-miss every rep -> ~zero benefit. So the budget is
# sized to AVAILABLE RAM at ctx init (`resolve_scan_dedup_max_bytes`),
# preserving host-OOM-safety by being free-RAM-relative + cgroup-aware +
# hard-capped.
#
# These cells lock the PURE policy core `_scan_dedup_budget_from_ram(basis,
# override)` — deterministic, no FFI — plus the override parser. The
# free-RAM / cgroup probing (`detect_scan_cache_ram_basis_bytes` in
# `komira_host.proc_probe`) is the untestable-in-unit FFI layer; it feeds this
# pure core, which is where the clamp / override / fallback correctness lives.
#
#   FAILS ON THE PRE-FIX CODE: there was no RAM sizing — the budget was the
#   fixed `SCAN_DEDUP_MAX_BYTES_DEFAULT` (1 GiB) unconditionally. The
#   `holds_tpch_working_set_under_cap` cell asserts a 16 GiB basis (the capped
#   verification scope) yields a budget >= 1.71 GiB, which the fixed 1 GiB cap
#   could never satisfy.
#
# Pointer rules: pure value API — no UnsafePointer, no
# wildcard origins, no take_pointee.
# =============================================================================

from std.testing import TestSuite, assert_true, assert_equal

from komira_dispatch_scan.scan_dedup_cache import (
    _scan_dedup_budget_from_ram,
    _parse_byte_size,
    SCAN_DEDUP_MAX_BYTES_DEFAULT,
    SCAN_DEDUP_MIN_BYTES,
    SCAN_DEDUP_MAX_BYTES_CEILING,
    SCAN_DEDUP_MEM_FRACTION_PCT,
)


comptime _GIB: Int = 1 << 30
comptime _MIB: Int = 1 << 20


def test_override_wins_over_ram() raises:
    """The explicit operator knob wins outright — even a large RAM basis is
    ignored when an override is supplied."""
    var got = _scan_dedup_budget_from_ram(64 * _GIB, 2 * _GIB)
    assert_equal(got, 2 * _GIB, "override beats the RAM-derived budget")


def test_unknown_ram_falls_back_to_fixed_default() raises:
    """A basis <= 0 (macOS / no procfs / unreadable) -> the fixed 1 GiB
    default, preserving the pre-fix behavior as the fallback."""
    assert_equal(
        _scan_dedup_budget_from_ram(0, 0),
        SCAN_DEDUP_MAX_BYTES_DEFAULT,
        "basis 0 -> 1 GiB default",
    )
    assert_equal(
        _scan_dedup_budget_from_ram(-1, 0),
        SCAN_DEDUP_MAX_BYTES_DEFAULT,
        "negative basis -> 1 GiB default",
    )


def test_fraction_of_basis_in_normal_range() raises:
    """A mid-range basis yields exactly the configured fraction, under the
    ceiling and over the floor."""
    var basis = 16 * _GIB
    var expect = basis * SCAN_DEDUP_MEM_FRACTION_PCT // 100
    var got = _scan_dedup_budget_from_ram(basis, 0)
    assert_equal(got, expect, "30% of a 16 GiB basis")
    assert_true(got < SCAN_DEDUP_MAX_BYTES_CEILING, "under the hard ceiling")
    assert_true(got > SCAN_DEDUP_MIN_BYTES, "over the floor")


def test_ceiling_clamps_ram_rich_basis() raises:
    """A RAM-rich basis is clamped to the 8 GiB hard ceiling — the guaranteed
    bound so even a huge box can't let the cache balloon."""
    var got = _scan_dedup_budget_from_ram(64 * _GIB, 0)  # 30% = 19.2 GiB
    assert_equal(got, SCAN_DEDUP_MAX_BYTES_CEILING, "clamped to 8 GiB ceiling")


def test_floor_clamps_constrained_basis() raises:
    """A very constrained basis is floored to 256 MiB — below the old fixed
    1 GiB default, so a RAM-scarce box shrinks BELOW today's cap (strictly
    safer), never a degenerate zero-cache."""
    var got = _scan_dedup_budget_from_ram(512 * _MIB, 0)  # 30% = 153.6 MiB
    assert_equal(got, SCAN_DEDUP_MIN_BYTES, "floored to 256 MiB")


def test_holds_tpch_working_set_under_cap() raises:
    """THE PERF FALSIFIER. Under the capped verification scope (a 16 GiB
    cgroup basis) the budget must hold TPC-H's 1.71 GiB scan working set so the
    cross-query amortization actually fires. A fixed 1 GiB cap could
    NOT satisfy this."""
    var tpch_working_set = 1_836_000_000  # ~1.71 GiB (55 scans)
    var budget = _scan_dedup_budget_from_ram(16 * _GIB, 0)
    assert_true(
        budget >= tpch_working_set,
        "16 GiB basis budget must hold the 1.71 GiB tpch working set",
    )
    # And it stays safely bounded under that same cap (not the whole 16 GiB).
    assert_true(
        budget <= 16 * _GIB // 2,
        "budget is a safe fraction of the cap, not the whole cap",
    )


def test_env_size_parser() raises:
    """The env-override parser: bytes, or 1024-based G/M/K suffix; 0 on
    empty / malformed (so an unset or garbage override is ignored)."""
    assert_equal(_parse_byte_size(String("8G")), 8 * _GIB, "8G -> 8 GiB")
    assert_equal(_parse_byte_size(String("512M")), 512 * _MIB, "512M -> 512 MiB")
    assert_equal(_parse_byte_size(String("1024K")), 1024 * 1024, "1024K -> 1 MiB")
    assert_equal(
        _parse_byte_size(String("1073741824")), _GIB, "bare bytes -> as-is"
    )
    assert_equal(_parse_byte_size(String("")), 0, "empty -> 0 (ignored)")
    assert_equal(_parse_byte_size(String("garbage")), 0, "non-numeric -> 0")
    assert_equal(_parse_byte_size(String("2g")), 2 * _GIB, "lowercase suffix ok")


def main() raises:
    var suite = TestSuite()
    suite.test[test_override_wins_over_ram]()
    suite.test[test_unknown_ram_falls_back_to_fixed_default]()
    suite.test[test_fraction_of_basis_in_normal_range]()
    suite.test[test_ceiling_clamps_ram_rich_basis]()
    suite.test[test_floor_clamps_constrained_basis]()
    suite.test[test_holds_tpch_working_set_under_cap]()
    suite.test[test_env_size_parser]()
    suite^.run()
