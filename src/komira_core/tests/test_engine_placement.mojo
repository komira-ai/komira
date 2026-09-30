# =============================================================================
# test_engine_placement.mojo — `EnginePlacement` and the placement-driven
# topology functions
# =============================================================================
#
# Placement is a plain value the embedding program passes in; nothing reads it
# from the process environment. These tests pin the two things that matter
# about that value:
#
#   1. THE DEFAULT IS EVERY POLICY OFF, and with it the effective topology is
#      exactly the probed one: `engine_topology(EnginePlacement())` equals
#      `CpuTopology.detect()` lane for lane, no driver CPU is reserved and no
#      NUMA node is chosen.
#   2. THE COMPOSED POLICY. A driver-CPU reservation only means something when
#      workers are pinned (an unpinned pool can be scheduled onto the
#      "reserved" CPU anyway), so `reserve_driver_cpu` alone must NOT reserve
#      a CPU. Asserting the field alone would not catch a reservation that
#      leaks through without pinning.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_core.runtime.cpu_topology import (
    CpuTopology,
    engine_compute_cpus,
    engine_driver_cpu,
    engine_io_cpus,
    engine_numa_node_id,
    engine_topology,
)
from komira_core.runtime.engine_placement import EnginePlacement


def _assert_same_cpus(got: List[Int], want: List[Int], what: String) raises:
    assert_equal(len(got), len(want), what + ": lane length")
    for i in range(len(want)):
        assert_equal(got[i], want[i], what + ": cpu at index " + String(i))


def test_default_placement_is_every_policy_off() raises:
    var p = EnginePlacement()
    assert_false(p.pin_workers, "default: workers are not pinned")
    assert_false(p.io_lane, "default: no separate IO lane")
    assert_false(p.numa_local, "default: no NUMA restriction")
    assert_false(p.reserve_driver_cpu, "default: no driver reservation asked")
    assert_false(p.driver_reserved(), "default: no driver CPU reserved")


def test_default_topology_is_the_probed_topology() raises:
    """With every policy off the effective topology IS `CpuTopology.detect()`."""
    var probed = CpuTopology.detect()
    var effective = engine_topology(EnginePlacement())
    _assert_same_cpus(
        effective.compute_cpus(), probed.compute_cpus(), "compute lane"
    )
    _assert_same_cpus(effective.io_cpus(), probed.io_cpus(), "io lane")
    assert_equal(effective.driver_cpu(), probed.driver_cpu(), "driver cpu")
    _assert_same_cpus(
        engine_compute_cpus(EnginePlacement()),
        probed.compute_cpus(),
        "engine_compute_cpus",
    )
    _assert_same_cpus(
        engine_io_cpus(EnginePlacement()), probed.io_cpus(), "engine_io_cpus"
    )


def test_reservation_without_pinning_reserves_nothing() raises:
    """`reserve_driver_cpu` alone is not a reservation: it needs `pin_workers`."""
    var p = EnginePlacement(reserve_driver_cpu=True)
    assert_false(p.driver_reserved(), "reserve without pin must not reserve")
    assert_equal(
        engine_driver_cpu(p), -1, "no driver CPU unless driver_reserved()"
    )
    assert_equal(
        engine_driver_cpu(EnginePlacement()), -1, "default: no driver CPU"
    )


def test_pinned_reservation_keeps_the_driver_off_the_compute_lane() raises:
    """With pin + reserve, a reserved driver CPU (when the host has one to
    spare) is never also a compute CPU. A host too small to reserve answers
    -1, which is also correct."""
    var p = EnginePlacement(pin_workers=True, reserve_driver_cpu=True)
    assert_true(p.driver_reserved(), "pin + reserve is a reservation")
    var driver = engine_driver_cpu(p)
    if driver >= 0:
        var compute = engine_compute_cpus(p)
        for i in range(len(compute)):
            assert_true(
                compute[i] != driver,
                "the reserved driver CPU must not be in the compute lane",
            )


def test_default_placement_chooses_no_numa_node() raises:
    assert_equal(
        engine_numa_node_id(EnginePlacement()),
        -1,
        "no NUMA node is chosen when numa_local is off",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
