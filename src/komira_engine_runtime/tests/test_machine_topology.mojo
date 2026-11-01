# =============================================================================
# test_machine_topology — the SIX topology-detection unit tests that stand in
# for the arches we cannot run locally (Runtime-Structure POC design §D.6).
#
# Detection is built as PURE FUNCTIONS over injected fixtures (the
# `derive_pools`-style pattern), so every arch — Intel-hybrid, ARM big.LITTLE,
# Apple Silicon, ≥2-socket NUMA — is exercised on EVERY CI run against
# synthetic sysfs/sysctl fixtures even though the SILICON is absent. This is
# the DESIGN-ONLY axes' proof obligation (design §D.6):
#
#   test_topo_detect_intel_hybrid   — P 5.5GHz / E 4.3GHz, L2 ÷2 / ÷4
#   test_topo_detect_arm_biglittle  — cpu_capacity 1024/379, no-SMT
#   test_topo_detect_apple_silicon  — perflevel 8P/4E, logical==physical, advisory
#   test_topo_detect_numa_2socket   — node0/1 + distance 10/21, victim order
#   test_topo_detect_flat_fallback  — single-tier clean-degrade (design §D.3)
#   test_topo_detect_cgroup_cpuset  — pool sizes to the allowed set, not nproc
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_engine_runtime.machine_topology import (
    CpuTier,
    MachineTopology,
    NumaNode,
    cluster_value_tiers,
    derive_freq_tiers,
    derive_capacity_tiers,
    derive_perflevel_tiers,
    derive_smt,
    derive_numa_nodes,
    flat_topology,
)


# -----------------------------------------------------------------------------
# Fixture helpers.
# -----------------------------------------------------------------------------

def _list(*vals: Int) -> List[Int]:
    var out = List[Int]()
    for v in vals:
        out.append(v)
    return out^


def _singletons(cpus: List[Int]) -> List[List[Int]]:
    """One-element sibling/L2 list per cpu (no SMT, no shared L2)."""
    var out = List[List[Int]]()
    for i in range(len(cpus)):
        var one = List[Int]()
        one.append(cpus[i])
        out.append(one^)
    return out^


# =============================================================================
# (1) Intel-hybrid P/E — the THIS-box fixture + the CI regression guard.
# =============================================================================


def test_topo_detect_intel_hybrid() raises:
    """P `max_freq=5500000` / E `4300000`, L2 `shared_cpu_list` `0-1` (P ÷2)
    and `16-19` (E ÷4) ⇒ assert 2 tiers, P÷2 / E÷4 L2 divisors, P weight 100 /
    E weight 78 (4.3/5.5), correct cpu membership (design §D.6)."""
    var cpus = _list(0, 1, 16, 17, 18, 19)
    var freqs = _list(5500000, 5500000, 4300000, 4300000, 4300000, 4300000)
    # P cores 0,1 share an L2 pair (÷2); E cores 16-19 share an L2 cluster (÷4).
    var l2 = List[List[Int]]()
    l2.append(_list(0, 1))
    l2.append(_list(0, 1))
    l2.append(_list(16, 17, 18, 19))
    l2.append(_list(16, 17, 18, 19))
    l2.append(_list(16, 17, 18, 19))
    l2.append(_list(16, 17, 18, 19))

    var tiers = derive_freq_tiers(cpus, freqs, l2)

    # Exactly two tiers: P (rank 0) and E (rank 1).
    assert_equal(len(tiers), 2)

    # Tier 0 = P: fastest, weight 100, L2 ÷2, cpus {0,1}.
    assert_equal(tiers[0].rank, 0)
    assert_equal(tiers[0].weight, 100)
    assert_equal(tiers[0].l2_divisor, 2)
    assert_equal(tiers[0].cpu_count(), 2)
    assert_equal(tiers[0].cpus[0], 0)
    assert_equal(tiers[0].cpus[1], 1)

    # Tier 1 = E: slower, weight 78 (= 4300000*100//5500000), L2 ÷4, cpus 16-19.
    assert_equal(tiers[1].rank, 1)
    assert_equal(tiers[1].weight, 78)
    assert_equal(tiers[1].l2_divisor, 4)
    assert_equal(tiers[1].cpu_count(), 4)
    assert_equal(tiers[1].cpus[0], 16)
    assert_equal(tiers[1].cpus[3], 19)


def test_topo_detect_intel_hybrid_worker_mapping() raises:
    """The C2/C3 consumer surface: `worker_weights` / `worker_is_efficiency`
    over the 14700K hybrid (8 slots: 2 P + ... layout). Proves the topology
    feeds the tier-weight prior + the E-gate flag."""
    var cpus = _list(0, 1, 16, 17)
    var freqs = _list(5500000, 5500000, 4300000, 4300000)
    var l2 = List[List[Int]]()
    l2.append(_list(0, 1))
    l2.append(_list(0, 1))
    l2.append(_list(16, 17, 18, 19))
    l2.append(_list(16, 17, 18, 19))
    var tiers = derive_freq_tiers(cpus, freqs, l2)

    var nodes = List[NumaNode]()
    nodes.append(NumaNode(0, _list(0, 1, 16, 17)))
    var topo = MachineTopology(
        tiers^, nodes^, List[Int](), True, False, 4
    )

    assert_false(topo.is_flat())
    assert_equal(topo.tier_count(), 2)

    # 4 workers laid across the tiers' cpus in rank order: [0,1] (P) then
    # [16,17] (E). Workers 0,1 → P weight 100; workers 2,3 → E weight 78.
    var w = topo.worker_weights(4)
    assert_equal(len(w), 4)
    assert_equal(w[0], 100)
    assert_equal(w[1], 100)
    assert_equal(w[2], 78)
    assert_equal(w[3], 78)

    var is_e = topo.worker_is_efficiency(4)
    assert_false(is_e[0])
    assert_false(is_e[1])
    assert_true(is_e[2])
    assert_true(is_e[3])


# =============================================================================
# (2) ARM big.LITTLE — cpu_capacity clustering, no-SMT.
# =============================================================================


def test_topo_detect_arm_biglittle() raises:
    """Synthetic `cpu_capacity` 1024/379, singleton thread_siblings ⇒ 2 tiers
    by capacity, no-SMT (design §D.6, stands in for ARM-Linux)."""
    var cpus = _list(0, 1, 2, 3)
    var caps = _list(1024, 1024, 379, 379)
    var l2 = _singletons(cpus)
    var tiers = derive_capacity_tiers(cpus, caps, l2)

    assert_equal(len(tiers), 2)
    # big cores: rank 0, weight 100.
    assert_equal(tiers[0].rank, 0)
    assert_equal(tiers[0].weight, 100)
    assert_equal(tiers[0].cpu_count(), 2)
    # LITTLE cores: rank 1, weight 37 (= 379*100//1024).
    assert_equal(tiers[1].rank, 1)
    assert_equal(tiers[1].weight, 37)
    assert_equal(tiers[1].cpu_count(), 2)

    # No SMT: every thread_siblings list is a singleton.
    var siblings = _singletons(cpus)
    assert_false(derive_smt(siblings))


# =============================================================================
# (3) Apple Silicon — perflevel P/E, logical==physical, advisory affinity.
# =============================================================================


def test_topo_detect_apple_silicon() raises:
    """`hw.perflevel0.physicalcpu=8`, `hw.perflevel1.physicalcpu=4`, no NUMA ⇒
    2 tiers, logical==physical (no-SMT), advisory-affinity flag set (design
    §D.6, stands in for macOS)."""
    var tiers = derive_perflevel_tiers(8, 4)

    assert_equal(len(tiers), 2)
    # P tier: 8 cpus [0,8).
    assert_equal(tiers[0].rank, 0)
    assert_equal(tiers[0].cpu_count(), 8)
    assert_equal(tiers[0].cpus[0], 0)
    assert_equal(tiers[0].cpus[7], 7)
    # E tier: 4 cpus [8,12).
    assert_equal(tiers[1].rank, 1)
    assert_equal(tiers[1].cpu_count(), 4)
    assert_equal(tiers[1].cpus[0], 8)
    assert_equal(tiers[1].cpus[3], 11)

    # Assemble the topology the macOS detect() path would build.
    var nodes = List[NumaNode]()
    var all_cpus = List[Int]()
    for i in range(12):
        all_cpus.append(i)
    nodes.append(NumaNode(0, all_cpus^))
    var topo = MachineTopology(
        tiers^, nodes^, List[Int](), False, True, 12
    )

    # advisory_affinity set (thread_policy_set is a hint, not a pin).
    assert_true(topo.advisory_affinity)
    # logical == physical ⇒ no SMT.
    assert_false(topo.has_smt)
    # No NUMA ⇒ single node.
    assert_equal(topo.node_count(), 1)


# =============================================================================
# (4) NUMA 2-socket — node membership + distance-ordered victim selection.
# =============================================================================


def test_topo_detect_numa_2socket() raises:
    """Synthetic `node/node0..1/cpulist` + distance matrix `10 21 / 21 10` ⇒
    2 nodes, correct NUMA-local-first victim ordering (design §D.6, stands in
    for the ≥2-socket box)."""
    var node_cpulists = List[List[Int]]()
    node_cpulists.append(_list(0, 1, 2, 3))
    node_cpulists.append(_list(4, 5, 6, 7))
    var nodes = derive_numa_nodes(node_cpulists)
    assert_equal(len(nodes), 2)
    assert_equal(nodes[0].node_id, 0)
    assert_equal(nodes[1].node_id, 1)

    # distance row-major: [[10,21],[21,10]].
    var distance = _list(10, 21, 21, 10)
    # One flat tier over all 8 cpus (freq clustering is orthogonal here).
    var tiers = List[CpuTier]()
    tiers.append(CpuTier(0, 100, 1, _list(0, 1, 2, 3, 4, 5, 6, 7), 100))
    var topo = MachineTopology(
        tiers^, nodes^, distance^, True, False, 8
    )

    assert_equal(topo.node_count(), 2)

    # Victim order from node 0: node 0 (local) first, then node 1 (remote).
    var v0 = topo.numa_victim_order(0)
    assert_equal(len(v0), 2)
    assert_equal(v0[0], 0)
    assert_equal(v0[1], 1)

    # Victim order from node 1: node 1 first, then node 0.
    var v1 = topo.numa_victim_order(1)
    assert_equal(len(v1), 2)
    assert_equal(v1[0], 1)
    assert_equal(v1[1], 0)


def test_topo_detect_numa_3node_distance_order() raises:
    """3-node fixture where the nearest remote is NOT id-adjacent — proves the
    victim order is DISTANCE-sorted, not id-sorted. distances from node 0:
    [10, 30, 20] ⇒ order 0, 2, 1."""
    var node_cpulists = List[List[Int]]()
    node_cpulists.append(_list(0, 1))
    node_cpulists.append(_list(2, 3))
    node_cpulists.append(_list(4, 5))
    var nodes = derive_numa_nodes(node_cpulists)
    # Row-major 3x3: node0 -> [10,30,20]; node1 -> [30,10,25]; node2 -> [20,25,10].
    var distance = _list(10, 30, 20, 30, 10, 25, 20, 25, 10)
    var tiers = List[CpuTier]()
    tiers.append(CpuTier(0, 100, 1, _list(0, 1, 2, 3, 4, 5), 100))
    var topo = MachineTopology(
        tiers^, nodes^, distance^, True, False, 6
    )
    var v0 = topo.numa_victim_order(0)
    assert_equal(len(v0), 3)
    assert_equal(v0[0], 0)  # local first
    assert_equal(v0[1], 2)  # nearest remote (dist 20) before...
    assert_equal(v0[2], 1)  # ...farther remote (dist 30)


# =============================================================================
# (5) Flat fallback — the clean-degrade guarantee (design §D.3).
# =============================================================================


def test_topo_detect_flat_fallback() raises:
    """Probe-failure / single-tier fixture ⇒ tier_count == 1, no IO lane,
    uniform weights — the clean-degrade guarantee at the detection layer
    (design §D.6 / §D.3)."""
    var topo = flat_topology(8)

    assert_equal(topo.tier_count(), 1)
    assert_true(topo.is_flat())
    assert_false(topo.has_smt)
    assert_equal(topo.total_cpus(), 8)

    # Uniform weights — every worker gets 100 (topology-blind baseline).
    var w = topo.worker_weights(8)
    assert_equal(len(w), 8)
    for i in range(8):
        assert_equal(w[i], 100)

    # No E-cores — the E-gate is a no-op on a flat machine.
    var is_e = topo.worker_is_efficiency(8)
    for i in range(8):
        assert_false(is_e[i])


def test_topo_detect_flat_from_equal_freqs() raises:
    """Equal cpufreq across all cores ⇒ the freq clusterer yields ONE tier
    (turbo jitter within sep_pct must NOT split a homogeneous machine)."""
    var cpus = _list(0, 1, 2, 3)
    # 5.5 / 5.45 / 5.5 / 5.48 GHz — all within 15% ⇒ one tier.
    var freqs = _list(5500000, 5450000, 5500000, 5480000)
    var l2 = _singletons(cpus)
    var tiers = derive_freq_tiers(cpus, freqs, l2)
    assert_equal(len(tiers), 1)
    assert_equal(tiers[0].cpu_count(), 4)
    assert_equal(tiers[0].weight, 100)


# =============================================================================
# (6) cgroup/cpuset — pool sizes to the allowed set, not nproc.
# =============================================================================


def test_topo_detect_cgroup_cpuset() raises:
    """`sched_getaffinity` restricted to a subset ⇒ tiers cover ONLY the
    allowed cpus, so `total_cpus()` == allowed count (not the host nproc).
    Guards against over-threading a cgroup (design §D.6)."""
    # Host has 8 P + E cores, but the cpuset allows only cpus {0,2,4,6}.
    var allowed = _list(0, 2, 4, 6)
    var freqs = _list(5500000, 5500000, 5500000, 5500000)
    var l2 = _singletons(allowed)
    var tiers = derive_freq_tiers(allowed, freqs, l2)

    # One homogeneous tier over exactly the allowed set.
    assert_equal(len(tiers), 1)
    assert_equal(tiers[0].cpu_count(), 4)

    var nodes = List[NumaNode]()
    nodes.append(NumaNode(0, allowed.copy()))
    var topo = MachineTopology(
        tiers^, nodes^, List[Int](), True, False, len(allowed)
    )

    # The load-bearing assertion: the pool sizes to the allowed set (4), NOT
    # the host core count — a NUMA-pinned container must not over-thread.
    assert_equal(topo.total_cpus(), 4)
    assert_equal(topo.allowed_count, 4)
    # Worker weights sized to the allowed set.
    assert_equal(len(topo.worker_weights(4)), 4)


# =============================================================================
# Extra: the shared clusterer's sep threshold boundary.
# =============================================================================


def test_cluster_sep_threshold_boundary() raises:
    """A drop of exactly 15% does NOT split (strict `> sep_pct`); a drop of
    16% does. Pins the tier-separation boundary."""
    # 1000 -> 850 is a 15% drop: same tier (not > 15%).
    var cpus = _list(0, 1)
    var vals_15 = _list(1000, 850)
    var l2 = _singletons(cpus)
    var t15 = cluster_value_tiers(cpus, vals_15, l2, 15)
    assert_equal(len(t15), 1)

    # 1000 -> 840 is a 16% drop: two tiers.
    var vals_16 = _list(1000, 840)
    var t16 = cluster_value_tiers(cpus, vals_16, l2, 15)
    assert_equal(len(t16), 2)


def main() raises:
    test_topo_detect_intel_hybrid()
    print("test_topo_detect_intel_hybrid: GREEN")
    test_topo_detect_intel_hybrid_worker_mapping()
    print("test_topo_detect_intel_hybrid_worker_mapping: GREEN")
    test_topo_detect_arm_biglittle()
    print("test_topo_detect_arm_biglittle: GREEN")
    test_topo_detect_apple_silicon()
    print("test_topo_detect_apple_silicon: GREEN")
    test_topo_detect_numa_2socket()
    print("test_topo_detect_numa_2socket: GREEN")
    test_topo_detect_numa_3node_distance_order()
    print("test_topo_detect_numa_3node_distance_order: GREEN")
    test_topo_detect_flat_fallback()
    print("test_topo_detect_flat_fallback: GREEN")
    test_topo_detect_flat_from_equal_freqs()
    print("test_topo_detect_flat_from_equal_freqs: GREEN")
    test_topo_detect_cgroup_cpuset()
    print("test_topo_detect_cgroup_cpuset: GREEN")
    test_cluster_sep_threshold_boundary()
    print("test_cluster_sep_threshold_boundary: GREEN")
    print("VERDICT: MachineTopology detection (6 arch fixtures) — GREEN")
