# =============================================================================
# test_topology_numa.mojo — NUMA locality and where worker pins land, over
# synthetic node layouts: `derive_numa_locality`, `numa_nodes_spanned`,
# `numa_preferred_node`, `pinned_lane_prefix`, `numa_nodes_spanned_by_pin`,
# `numa_pin_node_histogram`.
# =============================================================================
#
# All pure: each test passes its node CPU lists in, so a two-socket layout is
# exercised on any build worker.
#
# The first group pins the no-op. The NUMA restriction cuts the worker count,
# so on a single-node host, or a host that publishes no node information, it
# must return its input unchanged, field by field. The empty-node-list case is
# the one a naive "always filter to the preferred node" implementation gets
# wrong: it would empty every lane and leave a zero-worker pool.
#
# The two-socket fixture below is 2 sockets x 22 cores x 2 threads, where the
# sibling of cpu i is cpu i+44: node 0 = 0-21,44-65 and node 1 = 22-43,66-87.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_host.cpu_topology import (
    CpuTopology,
    derive_numa_locality,
    derive_pools,
    numa_nodes_spanned,
    numa_nodes_spanned_by_pin,
    numa_pin_node_histogram,
    numa_preferred_node,
    pinned_lane_prefix,
)


# -----------------------------------------------------------------------------
# Helpers and fixtures
# -----------------------------------------------------------------------------


def _list(*xs: Int) -> List[Int]:
    var out = List[Int]()
    for i in range(len(xs)):
        out.append(xs[i])
    return out^


def _contains(xs: List[Int], v: Int) -> Bool:
    for i in range(len(xs)):
        if xs[i] == v:
            return True
    return False


def _disjoint(a: List[Int], b: List[Int]) -> Bool:
    for i in range(len(a)):
        if _contains(b, a[i]):
            return False
    return True


def _subset(a: List[Int], b: List[Int]) -> Bool:
    for i in range(len(a)):
        if not _contains(b, a[i]):
            return False
    return True


def _assert_cpus(got: List[Int], want: List[Int], what: String) raises:
    assert_equal(len(got), len(want), what + ": length")
    for i in range(len(want)):
        assert_equal(got[i], want[i], what + ": entry at index " + String(i))


def _two_socket_nodes() -> List[List[Int]]:
    """Node 0 = 0-21,44-65; node 1 = 22-43,66-87."""
    var node0 = List[Int]()
    var node1 = List[Int]()
    for i in range(22):
        node0.append(i)
        node0.append(i + 44)
    for i in range(22, 44):
        node1.append(i)
        node1.append(i + 44)
    var out = List[List[Int]]()
    out.append(node0^)
    out.append(node1^)
    return out^


def _two_socket_topology() -> CpuTopology:
    """`derive_pools` over all 88 CPUs: compute = 0..43 (one per core),
    io = 44..87 (each core's sibling). The compute lane straddles both
    sockets."""
    var allowed = List[Int]()
    var siblings_of = List[List[Int]]()
    for i in range(88):
        allowed.append(i)
        var core = i if i < 44 else i - 44
        siblings_of.append(_list(core, core + 44))
    return derive_pools(allowed, siblings_of)


def _assert_identity(got: CpuTopology, base: CpuTopology) raises:
    _assert_cpus(got.allowed_cpus(), base.allowed_cpus(), "allowed")
    _assert_cpus(got.compute_cpus(), base.compute_cpus(), "compute")
    _assert_cpus(got.io_cpus(), base.io_cpus(), "io")
    assert_equal(got.driver_cpu(), base.driver_cpu(), "driver")
    assert_equal(got.io_placement_mode(), base.io_placement_mode(), "io mode")


# -----------------------------------------------------------------------------
# derive_numa_locality: the no-op cases
# -----------------------------------------------------------------------------


def test_single_node_lane_is_unchanged() raises:
    """A host with two nodes whose compute lane sits entirely on node 0: the
    lane is not split, so every field comes back unchanged, including the
    driver CPU and the IO mode."""
    var nodes = List[List[Int]]()
    nodes.append(_list(0, 1, 2, 3))
    nodes.append(_list(4, 5, 6, 7))
    var base = CpuTopology(_list(0, 1, 2, 3), _list(0, 1), _list(2, 3), 3)
    assert_equal(numa_nodes_spanned(base.compute_cpus(), nodes), 1)
    _assert_identity(derive_numa_locality(base.copy(), nodes), base)


def test_no_node_information_is_unchanged() raises:
    """No node lists at all: spanned is 0, there is no preferred node, and the
    topology is returned unchanged rather than filtered to nothing."""
    var empty = List[List[Int]]()
    var base = CpuTopology(_list(0, 1, 2, 3), _list(0, 1), _list(2, 3))
    assert_equal(numa_nodes_spanned(base.compute_cpus(), empty), 0)
    assert_equal(numa_preferred_node(base.compute_cpus(), empty), -1)
    _assert_identity(derive_numa_locality(base.copy(), empty), base)


def test_unmapped_cpu_does_not_count_as_a_node() raises:
    """CPUs 2 and 3 appear in no node list (a partly unreadable sysfs). They
    must not count as a second node, or an ordinary single-node host would
    have its pool cut in half."""
    var nodes = List[List[Int]]()
    nodes.append(_list(0, 1))
    var base = CpuTopology(_list(0, 1, 2, 3), _list(0, 1, 2, 3), List[Int]())
    assert_equal(numa_nodes_spanned(base.compute_cpus(), nodes), 1)
    var out = derive_numa_locality(base.copy(), nodes)
    _assert_cpus(out.compute_cpus(), _list(0, 1, 2, 3), "compute kept")


# -----------------------------------------------------------------------------
# derive_numa_locality: restricting a straddling lane
# -----------------------------------------------------------------------------


def test_two_socket_lane_is_cut_to_one_node() raises:
    """The two-socket fixture: compute 0..43 -> 0..21, io 44..87 -> 44..65,
    allowed 88 -> node 0's 44 CPUs. Both nodes hold 22 compute CPUs, so this is
    also the tie, which goes to node 0."""
    var nodes = _two_socket_nodes()
    var base = _two_socket_topology()
    assert_equal(base.physical_core_count(), 44)
    assert_equal(len(base.io_cpus()), 44)
    assert_equal(numa_nodes_spanned(base.compute_cpus(), nodes), 2)

    var out = derive_numa_locality(base.copy(), nodes)
    assert_equal(out.physical_core_count(), 22)
    assert_equal(len(out.io_cpus()), 22)
    assert_equal(out.allowed_count(), 44)
    assert_equal(out.compute_cpus()[0], 0)
    assert_equal(out.compute_cpus()[21], 21)
    assert_equal(out.io_cpus()[0], 44)
    assert_equal(out.io_cpus()[21], 65)
    assert_equal(numa_nodes_spanned(out.compute_cpus(), nodes), 1)
    assert_equal(numa_preferred_node(out.compute_cpus(), nodes), 0)
    assert_true(_disjoint(out.compute_cpus(), out.io_cpus()))
    assert_true(_subset(out.compute_cpus(), out.allowed_cpus()))
    assert_true(_subset(out.io_cpus(), out.allowed_cpus()))


def test_the_node_with_most_compute_cpus_wins() raises:
    """2 compute CPUs on node 0 and 4 on node 1: keep node 1, not node 0."""
    var nodes = List[List[Int]]()
    nodes.append(_list(0, 1))
    nodes.append(_list(2, 3, 4, 5))
    var base = CpuTopology(
        _list(0, 1, 2, 3, 4, 5), _list(0, 1, 2, 3, 4, 5), List[Int]()
    )
    assert_equal(numa_preferred_node(base.compute_cpus(), nodes), 1)
    var out = derive_numa_locality(base.copy(), nodes)
    _assert_cpus(out.compute_cpus(), _list(2, 3, 4, 5), "compute")
    _assert_cpus(out.allowed_cpus(), _list(2, 3, 4, 5), "allowed")


def test_a_tie_goes_to_the_lowest_node() raises:
    """Equal counts: node 0, so two processes on one host choose the same
    socket."""
    var nodes = List[List[Int]]()
    nodes.append(_list(0, 1))
    nodes.append(_list(2, 3))
    var base = CpuTopology(_list(0, 1, 2, 3), _list(0, 1, 2, 3), List[Int]())
    assert_equal(numa_preferred_node(base.compute_cpus(), nodes), 0)
    var out = derive_numa_locality(base.copy(), nodes)
    _assert_cpus(out.compute_cpus(), _list(0, 1), "compute")


def test_numa_locality_is_idempotent() raises:
    var nodes = _two_socket_nodes()
    var once = derive_numa_locality(_two_socket_topology(), nodes)
    var twice = derive_numa_locality(once.copy(), nodes)
    _assert_cpus(twice.compute_cpus(), once.compute_cpus(), "compute")
    _assert_cpus(twice.io_cpus(), once.io_cpus(), "io")
    _assert_cpus(twice.allowed_cpus(), once.allowed_cpus(), "allowed")


def test_driver_cpu_is_kept_only_on_the_chosen_node() raises:
    """A driver CPU on the node being dropped is cleared (pinning the driver to
    the far socket's memory is worse than no reservation); one on the chosen
    node is kept."""
    var nodes = List[List[Int]]()
    nodes.append(_list(0, 1, 2, 3))
    nodes.append(_list(4, 5, 6, 7))
    var far = CpuTopology(_list(0, 1, 2, 4, 5), _list(0, 1, 2, 4), _list(5), 5)
    assert_equal(derive_numa_locality(far.copy(), nodes).driver_cpu(), -1)
    var near = CpuTopology(
        _list(0, 1, 2, 3, 4), _list(0, 1, 2, 4), _list(3), 3
    )
    assert_equal(derive_numa_locality(near.copy(), nodes).driver_cpu(), 3)


def test_the_filter_keeps_lane_order() raises:
    """Lanes `compute[k]` and `io[k]` are paired by position, so the filter must keep the
    lanes' order; a re-sorting intersection would re-pair cores. Compute is
    deliberately descending and the node lists unsorted."""
    var nodes = List[List[Int]]()
    nodes.append(_list(9, 7, 5))
    nodes.append(_list(8, 6, 4))
    var base = CpuTopology(
        _list(9, 8, 7, 6, 5, 4), _list(9, 8, 7, 6), _list(5, 4)
    )
    var out = derive_numa_locality(base.copy(), nodes)
    _assert_cpus(out.compute_cpus(), _list(9, 7), "compute")
    _assert_cpus(out.io_cpus(), _list(5), "io")
    _assert_cpus(out.allowed_cpus(), _list(9, 7, 5), "allowed")


# -----------------------------------------------------------------------------
# Where a 1:1 pin of N workers lands
# -----------------------------------------------------------------------------


def test_pin_prefix_caps_at_the_lane() raises:
    """Worker k is pinned to lane[k] only while k < len(lane): a larger pool
    leaves its tail unpinned, so the prefix is capped, never wrapped."""
    var lane = _list(0, 1, 2, 3)
    _assert_cpus(pinned_lane_prefix(lane, 2), _list(0, 1), "2 workers")
    _assert_cpus(pinned_lane_prefix(lane, 4), _list(0, 1, 2, 3), "4 workers")
    _assert_cpus(pinned_lane_prefix(lane, 99), _list(0, 1, 2, 3), "capped")
    assert_equal(len(pinned_lane_prefix(lane, 0)), 0)
    assert_equal(len(pinned_lane_prefix(lane, -3)), 0)
    assert_equal(len(pinned_lane_prefix(List[Int](), 8)), 0)


def test_pin_of_20_workers_on_two_sockets_stays_on_node_0() raises:
    """20 workers on the two-socket lane occupy cpus 0..19, all on node 0.
    Checked a second way, CPU by CPU against the node lists, so the histogram
    cannot be right for the wrong reason."""
    var nodes = _two_socket_nodes()
    var lane = _two_socket_topology().compute_cpus()
    assert_equal(numa_nodes_spanned_by_pin(lane, 20, nodes), 1)
    _assert_cpus(numa_pin_node_histogram(lane, 20, nodes), _list(20, 0), "hist")
    var pinned = pinned_lane_prefix(lane, 20)
    assert_equal(len(pinned), 20)
    for k in range(len(pinned)):
        assert_true(_contains(nodes[0], pinned[k]))
        assert_false(_contains(nodes[1], pinned[k]))


def test_pin_of_44_workers_spans_both_sockets() raises:
    """Same lane, 44 workers: both sockets, 22 each. 22 still fits node 0;
    23 crosses onto node 1."""
    var nodes = _two_socket_nodes()
    var lane = _two_socket_topology().compute_cpus()
    assert_equal(numa_nodes_spanned_by_pin(lane, 44, nodes), 2)
    _assert_cpus(numa_pin_node_histogram(lane, 44, nodes), _list(22, 22), "44")
    assert_equal(numa_nodes_spanned_by_pin(lane, 22, nodes), 1)
    assert_equal(numa_nodes_spanned_by_pin(lane, 23, nodes), 2)
    _assert_cpus(numa_pin_node_histogram(lane, 23, nodes), _list(22, 1), "23")


def test_pin_span_differs_from_the_lane_span() raises:
    """The lane spans 2 nodes whatever the worker count; the pin span moves
    with it (1 at 20, 2 at 44). If the two agreed everywhere the pin form would
    say nothing new. At the whole lane they must agree."""
    var nodes = _two_socket_nodes()
    var lane = _two_socket_topology().compute_cpus()
    assert_equal(numa_nodes_spanned(lane, nodes), 2)
    assert_equal(numa_nodes_spanned_by_pin(lane, 20, nodes), 1)
    assert_equal(numa_nodes_spanned_by_pin(lane, 44, nodes), 2)
    assert_equal(
        numa_nodes_spanned_by_pin(lane, len(lane), nodes),
        numa_nodes_spanned(lane, nodes),
    )


def test_pin_histogram_is_empty_without_node_information() raises:
    """No node lists: span 0 and an empty histogram, never a made-up
    single-node answer."""
    var empty = List[List[Int]]()
    var lane = _list(0, 1, 2, 3)
    assert_equal(numa_nodes_spanned_by_pin(lane, 4, empty), 0)
    assert_equal(len(numa_pin_node_histogram(lane, 4, empty)), 0)


def test_pin_histogram_drops_unmapped_cpus() raises:
    """CPU 3 is on no node: it lands in no bucket, so the histogram sums to 3
    for 4 pinned workers. The histogram always has one entry per node, so an
    untouched node reads 0."""
    var nodes = List[List[Int]]()
    nodes.append(_list(0, 1))
    nodes.append(_list(2))
    var lane = _list(0, 1, 2, 3)
    var hist = numa_pin_node_histogram(lane, 4, nodes)
    _assert_cpus(hist, _list(2, 1), "4 workers")
    var total = 0
    for i in range(len(hist)):
        total += hist[i]
    assert_equal(total, 3)
    assert_equal(len(pinned_lane_prefix(lane, 4)), 4)
    _assert_cpus(numa_pin_node_histogram(lane, 2, nodes), _list(2, 0), "2")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
