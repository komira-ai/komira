# =============================================================================
# test_topology_derive.mojo — the pure topology derivations over synthetic
# machines: `derive_pools`, `derive_driver_reservation`, `derive_io_placement`.
# =============================================================================
#
# Every test here builds its machine from literal CPU lists and sibling lists
# and calls the pure functions directly: no syscall, no sysfs, no dependence on
# the worker that runs the build. So each machine shape the topology code
# claims to handle (hyperthreaded, no SMT, a hybrid of both, a tight cpuset, a
# cpuset that splits a sibling pair, 4-way SMT) is exercised on every host.
#
# The invariants asserted throughout are the ones `CpuTopology` documents:
#   * one compute CPU per physical core, and the compute lane is disjoint from
#     the IO lane;
#   * both lanes are subsets of the allowed set, which is never modified;
#   * a reserved driver CPU is never a compute CPU;
#   * applying a policy twice equals applying it once (the engine re-derives
#     on every call, so a non-idempotent policy would shrink the pool per call).
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_host.cpu_topology import (
    CpuTopology,
    IO_PLACEMENT_DEDICATED,
    IO_PLACEMENT_DRIVER_CORESIDENT,
    IO_PLACEMENT_INLINE,
    IO_PLACEMENT_SIBLING,
    IO_PLACEMENT_UNSET,
    derive_driver_reservation,
    derive_io_placement,
    derive_pools,
)


# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------


def _list(*xs: Int) -> List[Int]:
    var out = List[Int]()
    for i in range(len(xs)):
        out.append(xs[i])
    return out^


def _disjoint(a: List[Int], b: List[Int]) -> Bool:
    for i in range(len(a)):
        for j in range(len(b)):
            if a[i] == b[j]:
                return False
    return True


def _contains(xs: List[Int], v: Int) -> Bool:
    for i in range(len(xs)):
        if xs[i] == v:
            return True
    return False


def _subset(a: List[Int], b: List[Int]) -> Bool:
    """True iff every element of `a` is in `b`."""
    for i in range(len(a)):
        if not _contains(b, a[i]):
            return False
    return True


def _assert_cpus(got: List[Int], want: List[Int], what: String) raises:
    assert_equal(len(got), len(want), what + ": length")
    for i in range(len(want)):
        assert_equal(got[i], want[i], what + ": cpu at index " + String(i))


def _hybrid_8p_ht_12e() -> CpuTopology:
    """A hybrid desktop part: 8 performance cores with SMT (cpus 0..15,
    adjacent pairs) and 12 efficiency cores without (cpus 16..27).
    compute = [0,2,..,14,16..27] (20 CPUs), io = [1,3,..,15] (8)."""
    var allowed = List[Int]()
    var siblings_of = List[List[Int]]()
    for core in range(8):
        allowed.append(core * 2)
        allowed.append(core * 2 + 1)
    for e in range(12):
        allowed.append(16 + e)
    for core in range(8):
        siblings_of.append(_list(core * 2, core * 2 + 1))
        siblings_of.append(_list(core * 2, core * 2 + 1))
    for e in range(12):
        siblings_of.append(_list(16 + e))
    return derive_pools(allowed, siblings_of)


def _no_smt(n: Int) -> CpuTopology:
    """`n` physical cores, no siblings. compute = [0..n-1], io = []."""
    var allowed = List[Int]()
    var siblings_of = List[List[Int]]()
    for c in range(n):
        allowed.append(c)
        siblings_of.append(_list(c))
    return derive_pools(allowed, siblings_of)


# -----------------------------------------------------------------------------
# derive_pools: grouping allowed CPUs into cores and lanes
# -----------------------------------------------------------------------------


def test_derive_pools_22_core_smt_cpuset() raises:
    """Allowed = {0..21, 44..65} with cpu K paired to cpu K+44: 22 physical
    cores, compute = [0..21], io = [44..65]."""
    var allowed = List[Int]()
    var siblings_of = List[List[Int]]()
    for k in range(22):
        allowed.append(k)
    for k in range(22):
        allowed.append(k + 44)
    # `siblings_of` is parallel to `allowed`, in input order.
    for k in range(22):
        siblings_of.append(_list(k, k + 44))
    for k in range(22):
        siblings_of.append(_list(k, k + 44))

    var topo = derive_pools(allowed, siblings_of)
    assert_equal(topo.physical_core_count(), 22)
    var want_compute = List[Int]()
    var want_io = List[Int]()
    for k in range(22):
        want_compute.append(k)
        want_io.append(k + 44)
    _assert_cpus(topo.compute_cpus(), want_compute, "compute")
    _assert_cpus(topo.io_cpus(), want_io, "io")
    assert_true(_disjoint(topo.compute_cpus(), topo.io_cpus()))
    assert_true(_subset(topo.compute_cpus(), topo.allowed_cpus()))
    assert_true(_subset(topo.io_cpus(), topo.allowed_cpus()))
    assert_equal(topo.allowed_count(), 44)


def test_derive_pools_distant_pairs() raises:
    """Allowed = {0,1,2,3}, pairs (0,2) (1,3): compute = [0,1], io = [2,3]."""
    var siblings_of = List[List[Int]]()
    siblings_of.append(_list(0, 2))
    siblings_of.append(_list(1, 3))
    siblings_of.append(_list(0, 2))
    siblings_of.append(_list(1, 3))
    var topo = derive_pools(_list(0, 1, 2, 3), siblings_of)
    assert_equal(topo.physical_core_count(), 2)
    _assert_cpus(topo.compute_cpus(), _list(0, 1), "compute")
    _assert_cpus(topo.io_cpus(), _list(2, 3), "io")


def test_derive_pools_adjacent_pairs() raises:
    """14 cores whose siblings are adjacent pairs (0,1) (2,3) ...: compute is
    the even CPUs, io the odd."""
    var allowed = List[Int]()
    var siblings_of = List[List[Int]]()
    for core in range(14):
        allowed.append(core * 2)
        allowed.append(core * 2 + 1)
        siblings_of.append(_list(core * 2, core * 2 + 1))
        siblings_of.append(_list(core * 2, core * 2 + 1))
    var topo = derive_pools(allowed, siblings_of)
    assert_equal(topo.physical_core_count(), 14)
    var compute = topo.compute_cpus()
    var io = topo.io_cpus()
    assert_equal(len(compute), 14)
    assert_equal(len(io), 14)
    for core in range(14):
        assert_equal(compute[core], core * 2)
        assert_equal(io[core], core * 2 + 1)


def test_derive_pools_no_smt_has_no_io_lane() raises:
    """One CPU per core: each CPU is its own core and the IO lane is empty."""
    var siblings_of = List[List[Int]]()
    for c in range(4):
        siblings_of.append(_list(c))
    var topo = derive_pools(_list(0, 1, 2, 3), siblings_of)
    assert_equal(topo.physical_core_count(), 4)
    _assert_cpus(topo.compute_cpus(), _list(0, 1, 2, 3), "compute")
    assert_equal(len(topo.io_cpus()), 0)


def test_derive_pools_cpuset_splitting_a_pair() raises:
    """Hardware pairs (0,4) (1,5) (2,6) (3,7), allowed = {0,4,1,2}. Core (0,4)
    has both siblings; cores (1,5) and (2,6) have one each; core (3,7) none.
    3 cores, compute = [0,1,2], io = [4]."""
    var siblings_of = List[List[Int]]()
    siblings_of.append(_list(0, 4))  # cpu0
    siblings_of.append(_list(0, 4))  # cpu4
    siblings_of.append(_list(1, 5))  # cpu1
    siblings_of.append(_list(2, 6))  # cpu2
    var topo = derive_pools(_list(0, 4, 1, 2), siblings_of)
    assert_equal(topo.physical_core_count(), 3)
    _assert_cpus(topo.compute_cpus(), _list(0, 1, 2), "compute")
    _assert_cpus(topo.io_cpus(), _list(4), "io")


def test_derive_pools_unsorted_non_contiguous_input() raises:
    """Allowed = {40, 3, 44, 7} (unsorted), pairs (3,7) (40,44). The allowed set
    comes back sorted, compute = [3,40], io = [7,44]."""
    var siblings_of = List[List[Int]]()
    siblings_of.append(_list(40, 44))  # 40
    siblings_of.append(_list(3, 7))  # 3
    siblings_of.append(_list(40, 44))  # 44
    siblings_of.append(_list(3, 7))  # 7
    var topo = derive_pools(_list(40, 3, 44, 7), siblings_of)
    assert_equal(topo.physical_core_count(), 2)
    _assert_cpus(topo.allowed_cpus(), _list(3, 7, 40, 44), "allowed")
    _assert_cpus(topo.compute_cpus(), _list(3, 40), "compute")
    _assert_cpus(topo.io_cpus(), _list(7, 44), "io")


def test_derive_pools_four_way_smt_uses_one_pair() raises:
    """One core with 4 SMT threads: compute = [0], io = [1]; threads 2 and 3
    are dropped (the model is a compute + IO pair per core)."""
    var siblings_of = List[List[Int]]()
    for _ in range(4):
        siblings_of.append(_list(0, 1, 2, 3))
    var topo = derive_pools(_list(0, 1, 2, 3), siblings_of)
    assert_equal(topo.physical_core_count(), 1)
    _assert_cpus(topo.compute_cpus(), _list(0), "compute")
    _assert_cpus(topo.io_cpus(), _list(1), "io")


def test_fields_constructor_keeps_the_pools() raises:
    var topo = CpuTopology(_list(0, 1, 2, 3), _list(0, 1), _list(2, 3))
    assert_equal(topo.physical_core_count(), 2)
    assert_equal(topo.allowed_count(), 4)
    _assert_cpus(topo.compute_cpus(), _list(0, 1), "compute")
    _assert_cpus(topo.io_cpus(), _list(2, 3), "io")
    assert_equal(topo.driver_cpu(), -1, "no reservation by default")
    assert_equal(topo.io_placement_mode(), IO_PLACEMENT_UNSET)


# -----------------------------------------------------------------------------
# derive_driver_reservation
# -----------------------------------------------------------------------------


def test_driver_reservation_takes_a_free_sibling_on_a_hybrid() raises:
    """On the hybrid shape the lowest non-compute allowed CPU is cpu 1, the
    sibling of compute worker 0's core. Taking it costs no compute CPU, and it
    stays in the IO lane (IO-bound work may share the driver's CPU)."""
    var base = _hybrid_8p_ht_12e()
    assert_equal(base.physical_core_count(), 20)
    assert_equal(base.driver_cpu(), -1)
    assert_equal(len(base.io_cpus()), 8)

    var topo = derive_driver_reservation(base.copy())
    assert_equal(topo.driver_cpu(), 1)
    assert_false(_contains(topo.compute_cpus(), topo.driver_cpu()))
    assert_equal(topo.physical_core_count(), 20, "no compute cost")
    _assert_cpus(topo.compute_cpus(), base.compute_cpus(), "compute kept")
    _assert_cpus(topo.io_cpus(), base.io_cpus(), "io kept")
    assert_true(_contains(topo.io_cpus(), topo.driver_cpu()))
    _assert_cpus(topo.allowed_cpus(), base.allowed_cpus(), "allowed kept")


def test_driver_reservation_without_smt_costs_one_core() raises:
    """8 cores, no siblings: no free CPU exists, so the driver takes the
    highest compute CPU (7) and the pool shrinks to 7. Every surviving worker
    k keeps its CPU. The cost is asserted so it cannot become silent."""
    var base = _no_smt(8)
    var topo = derive_driver_reservation(base.copy())
    assert_equal(topo.driver_cpu(), 7)
    assert_equal(topo.physical_core_count(), 7)
    _assert_cpus(topo.compute_cpus(), _list(0, 1, 2, 3, 4, 5, 6), "compute")
    assert_equal(len(topo.io_cpus()), 0)
    _assert_cpus(topo.allowed_cpus(), base.allowed_cpus(), "allowed kept")


def test_driver_reservation_4cpu_cpuset_with_pairs_is_free() raises:
    """Allowed = {0,1,2,3}, pairs (0,2) (1,3): a free sibling exists, so the
    driver takes cpu 2 and both workers stay."""
    var siblings_of = List[List[Int]]()
    siblings_of.append(_list(0, 2))
    siblings_of.append(_list(1, 3))
    siblings_of.append(_list(0, 2))
    siblings_of.append(_list(1, 3))
    var topo = derive_driver_reservation(
        derive_pools(_list(0, 1, 2, 3), siblings_of)
    )
    assert_equal(topo.driver_cpu(), 2)
    assert_equal(topo.physical_core_count(), 2)
    _assert_cpus(topo.compute_cpus(), _list(0, 1), "compute")
    assert_true(_contains(topo.io_cpus(), 2))


def test_driver_reservation_4cpu_cpuset_without_smt() raises:
    """4 cores, no siblings: the driver takes cpu 3, workers 4 -> 3 (above the
    floor of 2)."""
    var topo = derive_driver_reservation(_no_smt(4))
    assert_equal(topo.driver_cpu(), 3)
    assert_equal(topo.physical_core_count(), 3)
    _assert_cpus(topo.compute_cpus(), _list(0, 1, 2), "compute")


def test_driver_reservation_refuses_on_1_and_2_cores() raises:
    """Halving or zeroing the pool to buy a driver core is never worth it:
    the topology comes back unchanged with no driver CPU."""
    var one = derive_driver_reservation(_no_smt(1))
    assert_equal(one.driver_cpu(), -1)
    assert_equal(one.physical_core_count(), 1)
    var two = derive_driver_reservation(_no_smt(2))
    assert_equal(two.driver_cpu(), -1)
    assert_equal(two.physical_core_count(), 2)
    _assert_cpus(two.compute_cpus(), _list(0, 1), "compute")


def test_driver_reservation_is_idempotent() raises:
    """A second application must not steal a second core."""
    var once = derive_driver_reservation(_no_smt(8))
    var twice = derive_driver_reservation(once.copy())
    assert_equal(twice.driver_cpu(), once.driver_cpu())
    assert_equal(twice.physical_core_count(), once.physical_core_count())
    _assert_cpus(twice.compute_cpus(), once.compute_cpus(), "compute")


def test_driver_reservation_with_a_split_pair_picks_a_real_sibling() raises:
    """Pairs (0,4) (1,5) (2,6), allowed = {0,1,2,5,6}: core 0's sibling is not
    allowed. compute = [0,1,2], io = [5,6]; the driver takes 5 (a real sibling,
    no compute cost) rather than stealing a core."""
    var siblings_of = List[List[Int]]()
    siblings_of.append(_list(0, 4))  # cpu0
    siblings_of.append(_list(1, 5))  # cpu1
    siblings_of.append(_list(2, 6))  # cpu2
    siblings_of.append(_list(1, 5))  # cpu5
    siblings_of.append(_list(2, 6))  # cpu6
    var base = derive_pools(_list(0, 1, 2, 5, 6), siblings_of)
    _assert_cpus(base.compute_cpus(), _list(0, 1, 2), "compute before")
    var topo = derive_driver_reservation(base^)
    assert_equal(topo.driver_cpu(), 5)
    assert_equal(topo.physical_core_count(), 3)
    assert_false(_contains(topo.compute_cpus(), topo.driver_cpu()))


# -----------------------------------------------------------------------------
# derive_io_placement: SIBLING, DEDICATED, DRIVER_CORESIDENT or INLINE
# -----------------------------------------------------------------------------


def test_io_placement_uses_siblings_when_smt_is_available() raises:
    """Hybrid shape: the 8 siblings become the IO lane at no compute cost."""
    var base = _hybrid_8p_ht_12e()
    assert_equal(base.io_placement_mode(), IO_PLACEMENT_UNSET)
    var topo = derive_io_placement(base.copy())
    assert_equal(topo.io_placement_mode(), IO_PLACEMENT_SIBLING)
    assert_equal(topo.physical_core_count(), 20)
    _assert_cpus(topo.compute_cpus(), base.compute_cpus(), "compute kept")
    _assert_cpus(
        topo.io_cpus(), _list(1, 3, 5, 7, 9, 11, 13, 15), "io = siblings"
    )
    assert_true(_disjoint(topo.compute_cpus(), topo.io_cpus()))
    assert_true(_subset(topo.io_cpus(), topo.allowed_cpus()))


def test_io_placement_dedicates_one_core_on_a_large_no_smt_host() raises:
    """64 cores without SMT: one dedicated IO core is cheap (1/63 of the pool),
    so the highest core (63) is taken and workers go 64 -> 63. Exactly one IO
    CPU; every surviving worker keeps its CPU."""
    var topo = derive_io_placement(_no_smt(64))
    assert_equal(topo.io_placement_mode(), IO_PLACEMENT_DEDICATED)
    assert_equal(topo.physical_core_count(), 63)
    _assert_cpus(topo.io_cpus(), _list(63), "io")
    assert_equal(topo.compute_cpus()[0], 0)
    assert_equal(topo.compute_cpus()[62], 62)
    assert_true(_disjoint(topo.compute_cpus(), topo.io_cpus()))


def test_io_placement_stays_inline_on_8_cores() raises:
    """8 cores without SMT and no driver reservation: a dedicated core would
    cost 1/7 of the pool, more than the blocking it hides. INLINE, no lane,
    no worker lost."""
    var topo = derive_io_placement(_no_smt(8))
    assert_equal(topo.io_placement_mode(), IO_PLACEMENT_INLINE)
    assert_equal(len(topo.io_cpus()), 0)
    assert_equal(topo.physical_core_count(), 8)


def test_io_placement_threshold_is_17_cores() raises:
    """The dedicate rule `1/(P-1) <= 1/16` first holds at P = 17: 16 cores stay
    inline, 17 dedicate core 16. Pinned so the constant cannot drift."""
    var at_16 = derive_io_placement(_no_smt(16))
    assert_equal(at_16.io_placement_mode(), IO_PLACEMENT_INLINE)
    assert_equal(at_16.physical_core_count(), 16)
    var at_17 = derive_io_placement(_no_smt(17))
    assert_equal(at_17.io_placement_mode(), IO_PLACEMENT_DEDICATED)
    assert_equal(at_17.physical_core_count(), 16)
    _assert_cpus(at_17.io_cpus(), _list(16), "io at 17")


def test_io_placement_shares_the_driver_cpu_on_a_small_host() raises:
    """8 cores without SMT after a driver reservation (driver = 7, compute 7):
    the IO lane goes on the driver's CPU, the only CPU that is not a pinned
    compute CPU. The IO placement itself takes no further core."""
    var reserved = derive_driver_reservation(_no_smt(8))
    assert_equal(reserved.driver_cpu(), 7)
    assert_equal(reserved.physical_core_count(), 7)
    var topo = derive_io_placement(reserved.copy())
    assert_equal(topo.io_placement_mode(), IO_PLACEMENT_DRIVER_CORESIDENT)
    assert_equal(topo.physical_core_count(), 7)
    _assert_cpus(topo.io_cpus(), _list(7), "io")
    assert_equal(topo.io_cpus()[0], topo.driver_cpu())
    assert_true(_disjoint(topo.compute_cpus(), topo.io_cpus()))


def test_io_placement_4cpu_cpuset_with_pairs_uses_siblings() raises:
    """A 4-CPU cpuset exposing both siblings of 2 cores: SIBLING, lane [1,3].
    A cpuset is just a smaller machine to the rule."""
    var siblings_of = List[List[Int]]()
    siblings_of.append(_list(0, 1))
    siblings_of.append(_list(0, 1))
    siblings_of.append(_list(2, 3))
    siblings_of.append(_list(2, 3))
    var topo = derive_io_placement(derive_pools(_list(0, 1, 2, 3), siblings_of))
    assert_equal(topo.io_placement_mode(), IO_PLACEMENT_SIBLING)
    assert_equal(topo.physical_core_count(), 2)
    _assert_cpus(topo.io_cpus(), _list(1, 3), "io")


def test_io_placement_4_cores_without_smt_is_inline() raises:
    var topo = derive_io_placement(_no_smt(4))
    assert_equal(topo.io_placement_mode(), IO_PLACEMENT_INLINE)
    assert_equal(len(topo.io_cpus()), 0)
    assert_equal(topo.physical_core_count(), 4)


def test_io_placement_1_and_2_cores_are_inline() raises:
    """The tiniest cpusets never lose a worker to the IO lane."""
    var one = derive_io_placement(_no_smt(1))
    assert_equal(one.io_placement_mode(), IO_PLACEMENT_INLINE)
    assert_equal(one.physical_core_count(), 1)
    assert_equal(len(one.io_cpus()), 0)
    var two = derive_io_placement(_no_smt(2))
    assert_equal(two.io_placement_mode(), IO_PLACEMENT_INLINE)
    assert_equal(two.physical_core_count(), 2)
    assert_equal(len(two.io_cpus()), 0)


def test_io_placement_is_idempotent() raises:
    """Twice equals once, for the DEDICATED arm (which would otherwise steal
    a second core) and the SIBLING arm."""
    var once = derive_io_placement(_no_smt(64))
    var twice = derive_io_placement(once.copy())
    assert_equal(twice.io_placement_mode(), once.io_placement_mode())
    assert_equal(twice.physical_core_count(), once.physical_core_count())
    _assert_cpus(twice.compute_cpus(), once.compute_cpus(), "dedicated compute")
    _assert_cpus(twice.io_cpus(), once.io_cpus(), "dedicated io")
    var s1 = derive_io_placement(_hybrid_8p_ht_12e())
    var s2 = derive_io_placement(s1.copy())
    _assert_cpus(s2.compute_cpus(), s1.compute_cpus(), "sibling compute")
    _assert_cpus(s2.io_cpus(), s1.io_cpus(), "sibling io")


def test_io_placement_composes_with_the_driver_reservation() raises:
    """Driver reservation then IO placement (the order the engine applies them)
    on the hybrid: the driver takes sibling 1 at no compute cost, the IO lane
    keeps every sibling including 1, and compute is disjoint from both."""
    var topo = derive_io_placement(
        derive_driver_reservation(_hybrid_8p_ht_12e())
    )
    assert_equal(topo.io_placement_mode(), IO_PLACEMENT_SIBLING)
    assert_equal(topo.driver_cpu(), 1)
    assert_equal(topo.physical_core_count(), 20)
    assert_true(_contains(topo.io_cpus(), 1))
    assert_false(_contains(topo.compute_cpus(), 1))
    assert_true(_disjoint(topo.compute_cpus(), topo.io_cpus()))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
