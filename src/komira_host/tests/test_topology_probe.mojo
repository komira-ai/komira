# =============================================================================
# test_topology_probe.mojo — the probe half of `cpu_topology`: the cpu-list
# parser, the small-file reader, the frozen allowed-CPU mask, the fallback
# topology, the quota cap, and the engine policies the other files leave off
# (the NUMA restriction and the IO lane, alone and together).
# =============================================================================
#
# The parser, the mask and the cap are pure and asserted from literals. The
# reader is asserted against files written under `TEST_TMPDIR`. The engine
# policies read this host's topology, so their oracle is the documented
# composition of the pure derivations over `CpuTopology.detect()`.
# =============================================================================

from std.os import getenv
from std.sys import num_physical_cores
from std.sys.info import CompilationTarget
from std.testing import TestSuite, assert_equal, assert_true

from komira_host.cpu_topology import (
    CpuTopology,
    IO_PLACEMENT_SIBLING,
    _AllowedCpuSnapshot,
    _cap_compute,
    _parse_cpu_list,
    _read_numa_node_cpulists,
    _read_numa_node_ids,
    _read_small_file,
    _read_thread_siblings,
    _siblings_for,
    _sorted_unique,
    derive_driver_reservation,
    derive_io_placement,
    derive_numa_locality,
    engine_numa_node_id,
    engine_topology,
    numa_nodes_spanned,
    numa_preferred_node,
)
from komira_host.engine_placement import EnginePlacement


# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------


def _list(*xs: Int) -> List[Int]:
    var out = List[Int]()
    for i in range(len(xs)):
        out.append(xs[i])
    return out^


def _range(lo: Int, hi: Int) -> List[Int]:
    var out = List[Int]()
    for v in range(lo, hi + 1):
        out.append(v)
    return out^


def _same(got: List[Int], want: List[Int], what: String) raises:
    assert_equal(len(got), len(want), what + ": length")
    for i in range(len(want)):
        assert_equal(got[i], want[i], what + ": index " + String(i))


def _same_topology(got: CpuTopology, want: CpuTopology, what: String) raises:
    _same(got.allowed_cpus(), want.allowed_cpus(), what + " allowed")
    _same(got.compute_cpus(), want.compute_cpus(), what + " compute")
    _same(got.io_cpus(), want.io_cpus(), what + " io")
    assert_equal(got.driver_cpu(), want.driver_cpu(), what + " driver")
    assert_equal(
        Int(got.io_placement_mode()), Int(want.io_placement_mode()), what + " mode"
    )


def _scratch(name: String) raises -> String:
    var base = getenv("TEST_TMPDIR")
    if base.byte_length() == 0:
        raise Error("TEST_TMPDIR is not set")
    return base + String("/") + name


def _write(path: String, text: String) raises:
    with open(path, "w") as f:
        f.write_bytes(text.as_bytes())


def _repeat(c: String, n: Int) -> String:
    var out = String()
    for _ in range(n):
        out += c
    return out^


# -----------------------------------------------------------------------------
# _parse_cpu_list
# -----------------------------------------------------------------------------


def test_cpu_list_singles_and_ranges() raises:
    _same(_parse_cpu_list(""), List[Int](), "empty")
    _same(_parse_cpu_list("7\n"), _list(7), "single")
    _same(_parse_cpu_list("0,44\n"), _list(0, 44), "comma pair")
    _same(_parse_cpu_list("0-3"), _range(0, 3), "range")
    _same(_parse_cpu_list("128-130"), _range(128, 130), "multi-digit")
    var want = _range(0, 21)
    want.extend(_range(44, 65))
    _same(_parse_cpu_list("0-21,44-65\n"), want, "two ranges")
    _same(_parse_cpu_list("5-5"), _list(5), "one-wide range")


def test_cpu_list_odd_input() raises:
    # A dash with no digit after it is the single cpu before it.
    _same(_parse_cpu_list("5-"), _list(5), "dangling dash")
    _same(_parse_cpu_list("5-,9"), _list(5, 9), "dangling dash then more")
    # A descending range emits nothing.
    _same(_parse_cpu_list("3-1,8"), _list(8), "descending range")
    # Bytes that are no digit are separators.
    _same(_parse_cpu_list(" x7 ;9\t"), _list(7, 9), "junk separators")
    _same(_parse_cpu_list("abc"), List[Int](), "no digit at all")


# -----------------------------------------------------------------------------
# Pure helpers
# -----------------------------------------------------------------------------


def test_sorted_unique_drops_duplicates() raises:
    _same(_sorted_unique(_list(3, 1, 3, 2, 1, 0)), _list(0, 1, 2, 3), "sorted unique")
    _same(_sorted_unique(List[Int]()), List[Int](), "empty")


def test_siblings_for_an_unknown_cpu_is_the_cpu_alone() raises:
    var allowed = _list(0, 1)
    var sibs = List[List[Int]]()
    sibs.append(_list(0, 1))
    sibs.append(_list(0, 1))
    _same(_siblings_for(1, allowed, sibs), _list(0, 1), "known cpu")
    _same(_siblings_for(9, allowed, sibs), _list(9), "unknown cpu")


def test_cap_compute_drops_the_highest_cores() raises:
    var topo = CpuTopology(
        _range(0, 7), _list(0, 1, 2, 3), _list(4, 5, 6, 7), 2, IO_PLACEMENT_SIBLING
    )
    var capped = _cap_compute(topo.copy(), 2)
    _same(capped.allowed_cpus(), _range(0, 7), "allowed is untouched")
    _same(capped.compute_cpus(), _list(0, 1), "compute")
    _same(capped.io_cpus(), _list(4, 5), "io keeps its pairing")
    assert_equal(capped.driver_cpu(), 2)
    assert_equal(Int(capped.io_placement_mode()), Int(IO_PLACEMENT_SIBLING))
    # A cap below one keeps one core rather than none.
    var one = _cap_compute(topo.copy(), 0)
    _same(one.compute_cpus(), _list(0), "cap 0 keeps one")
    _same(one.io_cpus(), _list(4), "cap 0 keeps one io")
    # Fewer IO cpus than the cap.
    var short = CpuTopology(_range(0, 3), _list(0, 1, 2), _list(3), -1)
    var s = _cap_compute(short^, 2)
    _same(s.compute_cpus(), _list(0, 1), "short compute")
    _same(s.io_cpus(), _list(3), "short io")


def test_allowed_snapshot_mask_round_trip() raises:
    # -1 and 1024 are out of range and dropped; 64 starts word 1; 1023 is the
    # last bit of the last word; words 2..14 stay zero.
    var snap = _AllowedCpuSnapshot(_list(-1, 1023, 5, 64, 0, 1024, 63), 6)
    assert_equal(snap.count, 5)
    assert_equal(snap.fallback_cores, 6)
    _same(snap.to_list(), _list(0, 5, 63, 64, 1023), "mask")
    var empty = _AllowedCpuSnapshot(List[Int](), 0)
    _same(empty.to_list(), List[Int](), "empty mask")


def test_fallback_is_every_core_as_compute() raises:
    var cores = num_physical_cores()
    var fb = CpuTopology._fallback()
    assert_true(len(fb.compute_cpus()) >= 1)
    _same(fb.allowed_cpus(), _range(0, len(fb.compute_cpus()) - 1), "allowed")
    _same(fb.compute_cpus(), fb.allowed_cpus(), "compute == allowed")
    _same(fb.io_cpus(), List[Int](), "no io")
    assert_equal(fb.driver_cpu(), -1)
    # Nothing in this process pinned a thread, so the frozen count is the live one.
    assert_equal(len(fb.compute_cpus()), max(cores, 1))


# -----------------------------------------------------------------------------
# File readers
# -----------------------------------------------------------------------------


def test_small_file_reader() raises:
    var empty = _scratch("ct_empty")
    var list = _scratch("ct_list")
    var at_cap = _scratch("ct_1024")
    var over = _scratch("ct_1500")
    _write(empty, "")
    _write(list, "0-3\n")
    _write(at_cap, _repeat("1", 1024))
    _write(over, _repeat("2", 1500))
    assert_equal(_read_small_file(_scratch("ct_missing")), "")
    assert_equal(_read_small_file(empty), "")
    comptime if CompilationTarget.is_linux():
        assert_equal(_read_small_file(list), "0-3\n", "no newline strip here")
        assert_equal(_read_small_file(at_cap).byte_length(), 1024)
        assert_equal(_read_small_file(over).byte_length(), 1024, "the cap")
    else:
        assert_equal(_read_small_file(list), "")


def test_unreadable_sysfs_entries_read_empty() raises:
    # No host has a cpu 1000000 or a NUMA node 1000000.
    _same(_read_thread_siblings(1000000), List[Int](), "siblings")
    var ids = _list(1000000)
    var lists = _read_numa_node_cpulists(ids)
    comptime if CompilationTarget.is_linux():
        assert_equal(len(lists), 1, "an unreadable node keeps its slot")
        _same(lists[0], List[Int](), "unreadable node")
    else:
        assert_equal(len(lists), 0)


# -----------------------------------------------------------------------------
# Engine policies on this host
# -----------------------------------------------------------------------------


def test_io_lane_policy_is_the_io_placement_of_the_probe() raises:
    var want = derive_io_placement(CpuTopology.detect())
    _same_topology(
        engine_topology(EnginePlacement(io_lane=True)), want, "io_lane"
    )


def test_numa_local_policy_is_the_restriction_of_the_probe() raises:
    var ids = _read_numa_node_ids()
    var lists = _read_numa_node_cpulists(ids)
    var detected = CpuTopology.detect()
    var want = derive_numa_locality(detected.copy(), lists)
    _same_topology(
        engine_topology(EnginePlacement(numa_local=True)), want, "numa_local"
    )
    var spanned = numa_nodes_spanned(detected.compute_cpus(), lists)
    var ordinal = numa_preferred_node(detected.compute_cpus(), lists)
    var want_id = -1
    if spanned > 1 and ordinal >= 0 and ordinal < len(ids):
        want_id = ids[ordinal]
    assert_equal(engine_numa_node_id(EnginePlacement(numa_local=True)), want_id)


def test_every_policy_composes_in_order() raises:
    var lists = _read_numa_node_cpulists(_read_numa_node_ids())
    var want = derive_io_placement(
        derive_driver_reservation(
            derive_numa_locality(CpuTopology.detect(), lists)
        )
    )
    var all_on = EnginePlacement(
        pin_workers=True, io_lane=True, numa_local=True, reserve_driver_cpu=True
    )
    _same_topology(engine_topology(all_on), want, "all policies")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
