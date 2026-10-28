# =============================================================================
# MachineTopology — unified P/E-tier + L2 + NUMA CPU topology model
# (Runtime-Structure POC, design §D — an internal doc)
# =============================================================================
#
# THE PROBLEM (design §D.5)
# -------------------------
# The engine has THREE fragmented topology structs today:
#   * `cpu_topology.mojo::CpuTopology`     — cgroup/cpuset + HT-sibling split
#   * `hardware_topology.mojo::HardwareTopology` — macOS-only P/E via sysctl;
#       the Linux P/E path is STUBBED (`_detect_fallback` collapses every core
#       to a single P-tier — design §D.5 "closes the Linux P/E gap").
#   * `komira_host_profile.hardware.HardwareProfile`   — cpu0-biased cache sizing.
# None of them derives an Intel-hybrid P/E tier split on Linux, a per-tier L2
# divisor, or a NUMA victim ordering — the three inputs the POC schedulers
# (C2 tier weight, C3 E-gate, D.1 NUMA-local steal) need.
#
# THIS MODULE (design §D + §D.6)
# ------------------------------
# A NEW, ADDITIVE canonical topology model that the other three become views
# over post-POC (design §E.1 step 5). It is built as a set of PURE FUNCTIONS
# over injected fixtures (the `derive_pools`-style pattern already proven in
# `cpu_topology.mojo`) so EVERY arch — Intel-hybrid, ARM big.LITTLE, Apple
# Silicon, ≥2-socket NUMA — is unit-testable WITHOUT that arch's hardware
# (design §D.6, the six `test_topo_detect_*`). A thin `detect()` layer reads
# the real sysfs / sysctl and feeds the pure functions.
#
# Detection axes + their sources (design §D):
#   * Intel-hybrid P/E   — cluster `cpuN/cpufreq/cpuinfo_max_freq` (D.5).
#   * ARM big.LITTLE     — cluster `cpuN/cpu_capacity` (D.4, same clustering).
#   * Apple Silicon P/E  — `hw.perflevelN.physicalcpu` (D.4).
#   * L2 morsel divisor  — `cache/indexN/shared_cpu_list` length (D.5).
#   * NUMA node + victim  — `node/nodeN/cpulist` + `node/nodeN/distance` (D.1).
#   * SMT / no-HT        — `topology/thread_siblings_list` cardinality (D.2/D.3).
#   * cgroup/cpuset      — `sched_getaffinity` allowed set (D.6).
#
# Mojo safety (an internal doc):
#   * NO UnsafePointer crosses a module boundary — the public API exposes only
#     `Int` / `List[Int]` / `CpuTier` / `MachineTopology`. All FFI buffers are
#     confined to private helpers with `# SAFETY:` blocks (mirrors
#     cpu_topology.mojo / hardware_topology.mojo, kept local so the FFI surface
#     is auditable in one place).
#   * NO owning wildcard-origin FIELDS — every field is a plain value / List.
#   * All `alloc[UInt8]` FFI buffers are function-local and freed before return.
#   * Detection NEVER raises and NEVER returns < 1 tier — any probe failure
#     falls soft to `flat_topology()` (design §D.3 clean-degrade guarantee).
# =============================================================================

# =============================================================================
# FFI-BOUNDARY: libc sched_getaffinity(2) + fopen/fread/fclose (sysfs) +
#               darwin sysctlbyname(3). Same carve-out as cpu_topology.mojo /
#               hardware_topology.mojo — the only MutExternalOrigin is the
#               sysctl no-write NULL sentinel; per-site SAFETY inline.
# =============================================================================

from std.ffi import external_call, c_int
from std.memory import UnsafePointer, alloc
from std.sys.info import CompilationTarget

# The ONE process-wide CPU snapshot (). This module used to
# clone the `sched_getaffinity` probe — and with it the "pid 0 is the calling
# THREAD" defect. It now delegates; see `_read_allowed_cpus` below.
#
# `_process_physical_core_count` is that same snapshot's `num_physical_cores()`
# sample (): the stdlib call is affinity-aware on Linux, so
# the `flat_topology(...)` degrade paths below must NOT source their core count
# from a live call — a pinned thread would then degrade to a ONE-core machine
# and size the grain for it.
from komira_host.cpu_topology import (
    _read_allowed_cpus as _core_read_allowed_cpus,
    _process_physical_core_count,
)


# =============================================================================
# Constants
# =============================================================================

# The default tier-separation threshold: two cpufreq/capacity clusters are
# distinct tiers only when the SLOWER one is more than this percentage below
# the FASTER one's representative (design §D.5: ">15% ⇒ assign tier ranks by
# descending freq"). 5.5 GHz P vs 4.3 GHz E ⇒ 21.8% drop ⇒ 2 tiers; two P
# cores at 5.5/5.4 GHz ⇒ 1.8% drop ⇒ 1 tier (robust to per-core turbo jitter).
comptime TIER_SEP_PCT_DEFAULT: Int = 15

# glibc cpu_set_t is 128 bytes = 1024 bits (matches CPU_SETSIZE).
comptime _CPU_SET_BYTES: Int = 128
comptime _CPU_SET_MAX: Int = _CPU_SET_BYTES * 8

# Max sysfs file we read (freq / cpulist / distance / siblings).
comptime _SYSFS_FILE_MAX: Int = 1024

# ASCII codepoints for the byte-level list parsers.
comptime _ASCII_ZERO: Int = 48
comptime _ASCII_NINE: Int = 57
comptime _ASCII_COMMA: Int = 44
comptime _ASCII_DASH: Int = 45
comptime _ASCII_NEWLINE: Int = 10
comptime _ASCII_SPACE: Int = 32


# =============================================================================
# CpuTier — one P/E (or big/LITTLE) performance tier.
# =============================================================================


struct CpuTier(Copyable, Movable, Writable):
    """A single CPU performance tier (design §D.5 tier rank).

    Fields:
      * `rank`: 0 == fastest tier (P / big / perflevel0). Higher == slower.
      * `weight`: relative throughput weight, normalized so the FASTEST tier
        is 100 (design §C: C2/C4 static prior ∝ freq ratio). E-tier on the
        14700K ≈ 78 (4.3/5.5). Uniform 100 on a flat machine.
      * `l2_divisor`: number of logical CPUs sharing this tier's L2 (design
        §D.5: P `0-1` ÷2; E-cluster `16-19` ÷4 ⇒ 1 MB/E-core morsel sizing).
        1 when unknown.
      * `cpus`: the tier's logical-CPU indices, ascending.
      * `rep_value`: the tier's representative raw value (max cpufreq / capacity
        / a synthetic weight for perflevel tiers) — kept for diagnostics.
    """

    var rank: Int
    var weight: Int
    var l2_divisor: Int
    var cpus: List[Int]
    var rep_value: Int

    def __init__(
        out self,
        rank: Int,
        weight: Int,
        l2_divisor: Int,
        var cpus: List[Int],
        rep_value: Int,
    ):
        self.rank = rank
        self.weight = weight
        self.l2_divisor = l2_divisor
        self.cpus = cpus^
        self.rep_value = rep_value

    @always_inline
    def cpu_count(self) -> Int:
        return len(self.cpus)

    def write_to[W: Writer](self, mut writer: W):
        writer.write(
            "CpuTier(rank=", self.rank,
            ", weight=", self.weight,
            ", l2_div=", self.l2_divisor,
            ", cpus=", len(self.cpus),
            ", rep=", self.rep_value,
            ")",
        )


# =============================================================================
# NumaNode — one NUMA node's cpu membership (design §D.1).
# =============================================================================


struct NumaNode(Copyable, Movable, Writable):
    """A NUMA node: its id + the logical CPUs local to it."""

    var node_id: Int
    var cpus: List[Int]

    def __init__(out self, node_id: Int, var cpus: List[Int]):
        self.node_id = node_id
        self.cpus = cpus^

    def write_to[W: Writer](self, mut writer: W):
        writer.write("NumaNode(id=", self.node_id, ", cpus=", len(self.cpus), ")")


# =============================================================================
# MachineTopology — the unified canonical model.
# =============================================================================


struct MachineTopology(Copyable, Movable, Writable):
    """Unified P/E-tier + NUMA + SMT topology (design §D).

    Assembled from the pure `derive_*` functions (testable per §D.6) or
    probed via `detect()`. Consumers:
      * C2/C4 tier weighting → `worker_weights(n_workers)`.
      * C3 E-inclusion gate  → `worker_is_efficiency(n_workers)`.
      * D.1 NUMA-local steal  → `numa_victim_order(cpu)`.
      * D.3 clean-degrade     → `is_flat()` (uniform weights, no E-gate, no
        NUMA remotes — the topology-blind baseline).

    `distance` is a ROW-MAJOR n_nodes×n_nodes matrix (flat List[Int]) to keep
    the field a plain `List[Int]` rather than nested `List[List[Int]]`.
    """

    var tiers: List[CpuTier]
    var nodes: List[NumaNode]
    var distance: List[Int]  # row-major n_nodes×n_nodes; empty if <=1 node
    var has_smt: Bool
    var advisory_affinity: Bool  # macOS thread_policy_set is a HINT, not a pin
    var allowed_count: Int  # cgroup/cpuset-restricted allowed logical-CPU count

    def __init__(
        out self,
        var tiers: List[CpuTier],
        var nodes: List[NumaNode],
        var distance: List[Int],
        has_smt: Bool,
        advisory_affinity: Bool,
        allowed_count: Int,
    ):
        self.tiers = tiers^
        self.nodes = nodes^
        self.distance = distance^
        self.has_smt = has_smt
        self.advisory_affinity = advisory_affinity
        self.allowed_count = allowed_count

    # --- Derived views -------------------------------------------------------

    @always_inline
    def tier_count(self) -> Int:
        return len(self.tiers)

    @always_inline
    def node_count(self) -> Int:
        return len(self.nodes)

    @always_inline
    def is_flat(self) -> Bool:
        """True on single-tier / single-node / no-SMT (design §D.3): tier
        weighting is uniform, HT policy a no-op, NUMA steal local-only. The
        scheduler MUST be byte- and wall-identical to the topology-blind
        baseline here."""
        return len(self.tiers) <= 1

    def total_cpus(self) -> Int:
        """Sum of all tiers' cpu counts == the covered logical-CPU count
        (design §D.6 cgroup_cpuset: pool sizes to the allowed set)."""
        var n = 0
        for i in range(len(self.tiers)):
            n += len(self.tiers[i].cpus)
        return n

    def _flat_cpu_order(self) -> List[Int]:
        """The tiers' cpus concatenated in rank order (fastest first). Worker
        w (0-based) is mapped to the w-th cpu in this order for weighting; a
        POC simplification (the real engine pins worker→cpu via
        `engine_compute_cpus()`). Wraps if n_workers > total cpus."""
        var out = List[Int]()
        for i in range(len(self.tiers)):
            for j in range(len(self.tiers[i].cpus)):
                out.append(self.tiers[i].cpus[j])
        return out^

    def _tier_of_cpu(self, cpu: Int) -> Int:
        for i in range(len(self.tiers)):
            for j in range(len(self.tiers[i].cpus)):
                if self.tiers[i].cpus[j] == cpu:
                    return i
        return 0

    def worker_weights(self, n_workers: Int) -> List[Int]:
        """Per-worker throughput weight (design §C: C2/C4 static prior). Worker
        w maps to the w-th cpu in rank order; its weight is that cpu's tier
        weight (100 for fastest). Uniform 100 on a flat machine."""
        var weights = List[Int]()
        if len(self.tiers) == 0:
            for _ in range(n_workers):
                weights.append(100)
            return weights^
        var order = self._flat_cpu_order()
        var ncpu = len(order)
        for w in range(n_workers):
            if ncpu == 0:
                weights.append(100)
                continue
            var cpu = order[w % ncpu]
            var t = self._tier_of_cpu(cpu)
            weights.append(self.tiers[t].weight)
        return weights^

    def worker_is_efficiency(self, n_workers: Int) -> List[Bool]:
        """Per-worker E-core flag (design §C3 E-gate). True iff the worker maps
        to a NON-fastest tier (rank > 0). All-False on a flat machine."""
        var flags = List[Bool]()
        if len(self.tiers) <= 1:
            for _ in range(n_workers):
                flags.append(False)
            return flags^
        var order = self._flat_cpu_order()
        var ncpu = len(order)
        for w in range(n_workers):
            if ncpu == 0:
                flags.append(False)
                continue
            var cpu = order[w % ncpu]
            var t = self._tier_of_cpu(cpu)
            flags.append(t > 0)
        return flags^

    def _node_of_cpu(self, cpu: Int) -> Int:
        for i in range(len(self.nodes)):
            for j in range(len(self.nodes[i].cpus)):
                if self.nodes[i].cpus[j] == cpu:
                    return self.nodes[i].node_id
        return 0

    def numa_victim_order(self, this_node: Int) -> List[Int]:
        """NUMA-local-first victim node ordering for cross-node coarse steal
        (design §D.1): this node first, then remote nodes by ASCENDING
        `distance[this][remote]`, cross-socket last. Empty distance ⇒ just the
        node list in id order (single-node / no matrix)."""
        var order = List[Int]()
        var nn = len(self.nodes)
        if nn == 0:
            return order^
        # This node first.
        order.append(this_node)
        if len(self.distance) != nn * nn:
            # No distance matrix: append the rest in id order.
            for i in range(nn):
                var nid = self.nodes[i].node_id
                if nid != this_node:
                    order.append(nid)
            return order^
        # Remotes sorted by ascending distance[this][remote], tie-break by id.
        var remotes = List[Int]()
        for i in range(nn):
            var nid = self.nodes[i].node_id
            if nid != this_node:
                remotes.append(nid)
        # Insertion sort by distance.
        for i in range(1, len(remotes)):
            var key = remotes[i]
            var kd = self.distance[this_node * nn + key]
            var j = i - 1
            while j >= 0 and self.distance[this_node * nn + remotes[j]] > kd:
                remotes[j + 1] = remotes[j]
                j -= 1
            remotes[j + 1] = key
        for i in range(len(remotes)):
            order.append(remotes[i])
        return order^

    def write_to[W: Writer](self, mut writer: W):
        writer.write(
            "MachineTopology(tiers=", len(self.tiers),
            ", nodes=", len(self.nodes),
            ", has_smt=", self.has_smt,
            ", advisory=", self.advisory_affinity,
            ", allowed=", self.allowed_count,
            ", flat=", self.is_flat(),
            ")",
        )


# =============================================================================
# PURE LOGIC — unit-testable with synthetic inputs (design §D.6). NO syscalls,
# NO sysfs. These are the six `test_topo_detect_*` proof obligation.
# =============================================================================


def cluster_value_tiers(
    cpus: List[Int],
    values: List[Int],
    l2_lists: List[List[Int]],
    sep_pct: Int,
) -> List[CpuTier]:
    """Cluster `cpus` into performance tiers by `values` (higher == faster).

    THE HEART of P/E detection (design §D.5). Shared by both the Intel
    cpufreq path (`derive_freq_tiers`) and the ARM `cpu_capacity` path
    (`derive_capacity_tiers`) — they differ only in which sysfs value feeds
    it. Pure: no syscalls, no filesystem.

    Args:
        cpus: Logical-CPU indices.
        values: Parallel to `cpus`; the per-cpu freq / capacity (higher =
            faster).
        l2_lists: Parallel to `cpus`; each cpu's `shared_cpu_list` (for the
            per-tier L2 divisor). Pass singletons / empties when unknown.
        sep_pct: Two clusters are distinct tiers only when the slower is more
            than this percent below the faster's representative.

    Returns:
        Tiers ranked 0..k (0 == fastest / highest value), weight normalized so
        rank 0 == 100, cpus ascending, l2_divisor from the tier's first cpu.
    """
    var n = len(cpus)
    if n == 0:
        return List[CpuTier]()

    # 1. Distinct values, descending.
    var distinct = List[Int]()
    for i in range(n):
        var v = values[i] if i < len(values) else 0
        var seen = False
        for k in range(len(distinct)):
            if distinct[k] == v:
                seen = True
                break
        if not seen:
            distinct.append(v)
    # Insertion sort descending.
    for i in range(1, len(distinct)):
        var key = distinct[i]
        var j = i - 1
        while j >= 0 and distinct[j] < key:
            distinct[j + 1] = distinct[j]
            j -= 1
        distinct[j + 1] = key

    # 2. Assign each distinct value a tier index. Start tier 0 at the highest
    #    value; open a new tier when the next value drops >sep_pct below the
    #    CURRENT tier's representative (its highest value).
    var value_tier = List[Int]()  # parallel to `distinct`
    var cur_tier = 0
    var rep = distinct[0]
    for i in range(len(distinct)):
        var v = distinct[i]
        if rep > 0 and (rep - v) * 100 > sep_pct * rep:
            cur_tier += 1
            rep = v
        value_tier.append(cur_tier)
    var n_tiers = cur_tier + 1

    # 3. Fastest tier's representative value (for weight normalization).
    var fastest_rep = distinct[0]
    if fastest_rep <= 0:
        fastest_rep = 1

    # 4. Group cpus by tier; track per-tier max value + first-cpu l2 divisor.
    var tier_cpus = List[List[Int]]()
    var tier_maxval = List[Int]()
    var tier_l2 = List[Int]()
    for _ in range(n_tiers):
        tier_cpus.append(List[Int]())
        tier_maxval.append(0)
        tier_l2.append(1)
    for i in range(n):
        var v = values[i] if i < len(values) else 0
        # Look up v's tier.
        var t = 0
        for k in range(len(distinct)):
            if distinct[k] == v:
                t = value_tier[k]
                break
        tier_cpus[t].append(cpus[i])
        if v > tier_maxval[t]:
            tier_maxval[t] = v
        # L2 divisor from this cpu's shared list length (first non-trivial wins).
        if i < len(l2_lists):
            var l2n = len(l2_lists[i])
            if l2n > tier_l2[t]:
                tier_l2[t] = l2n

    # 5. Build the tiers, sorted cpus ascending, weight normalized to 100.
    var out = List[CpuTier]()
    for t in range(n_tiers):
        var sorted_cpus = _sorted_unique(tier_cpus[t])
        var w = (tier_maxval[t] * 100) // fastest_rep
        if w < 1:
            w = 1
        out.append(
            CpuTier(t, w, tier_l2[t], sorted_cpus^, tier_maxval[t])
        )
    return out^


def derive_freq_tiers(
    cpus: List[Int],
    max_freqs: List[Int],
    l2_lists: List[List[Int]],
    sep_pct: Int = TIER_SEP_PCT_DEFAULT,
) -> List[CpuTier]:
    """Intel-hybrid P/E tiers from `cpuinfo_max_freq` (design §D.5). Thin
    wrapper over `cluster_value_tiers` with the freq as the value."""
    return cluster_value_tiers(cpus, max_freqs, l2_lists, sep_pct)


def derive_capacity_tiers(
    cpus: List[Int],
    capacities: List[Int],
    l2_lists: List[List[Int]],
    sep_pct: Int = TIER_SEP_PCT_DEFAULT,
) -> List[CpuTier]:
    """ARM big.LITTLE tiers from `cpu_capacity` (design §D.4). Same clustering
    as freq; capacity 1024/379 ⇒ 63% drop ⇒ 2 tiers."""
    return cluster_value_tiers(cpus, capacities, l2_lists, sep_pct)


def derive_perflevel_tiers(p_phys: Int, e_phys: Int) -> List[CpuTier]:
    """Apple-Silicon P/E tiers from `hw.perflevelN.physicalcpu` (design §D.4).

    perflevel0 → tier 0 (P) over cpus [0, p_phys); perflevel1 → tier 1 (E)
    over [p_phys, p_phys+e_phys). No SMT (logical == physical). The E weight
    is a nominal 65 (Apple E-cores run ~0.6-0.7× a P-core); the real ratio is
    measured per §C, not modeled — this is only the C2/C4 seed prior."""
    var out = List[CpuTier]()
    if p_phys <= 0:
        # Degenerate — treat everything as one tier.
        var all_cpus = List[Int]()
        var total = p_phys + e_phys
        if total < 1:
            total = 1
        for i in range(total):
            all_cpus.append(i)
        out.append(CpuTier(0, 100, 1, all_cpus^, 100))
        return out^
    var p_cpus = List[Int]()
    for i in range(p_phys):
        p_cpus.append(i)
    out.append(CpuTier(0, 100, 1, p_cpus^, 100))
    if e_phys > 0:
        var e_cpus = List[Int]()
        for i in range(p_phys, p_phys + e_phys):
            e_cpus.append(i)
        out.append(CpuTier(1, 65, 1, e_cpus^, 65))
    return out^


def derive_smt(thread_siblings_lists: List[List[Int]]) -> Bool:
    """True iff ANY cpu reports >1 thread sibling (design §D.2). Intel P-core
    `0-1` ⇒ SMT; ARM / Apple singletons ⇒ no-SMT."""
    for i in range(len(thread_siblings_lists)):
        if len(thread_siblings_lists[i]) > 1:
            return True
    return False


def derive_numa_nodes(node_cpulists: List[List[Int]]) -> List[NumaNode]:
    """NUMA nodes from `node/nodeN/cpulist` (design §D.1). `node_cpulists[k]`
    is node k's cpu list."""
    var out = List[NumaNode]()
    for k in range(len(node_cpulists)):
        out.append(NumaNode(k, node_cpulists[k].copy()))
    return out^


def flat_topology(n_cpus: Int) -> MachineTopology:
    """Single-tier, single-node, no-SMT fallback (design §D.3 clean-degrade).
    All `n_cpus` in one uniform tier (weight 100). tier_count == 1 ⇒
    `is_flat()`."""
    var n = n_cpus
    if n < 1:
        n = 1
    var cpus = List[Int]()
    for i in range(n):
        cpus.append(i)
    var tiers = List[CpuTier]()
    tiers.append(CpuTier(0, 100, 1, cpus^, 100))
    var nodes = List[NumaNode]()
    var all_cpus = List[Int]()
    for i in range(n):
        all_cpus.append(i)
    nodes.append(NumaNode(0, all_cpus^))
    return MachineTopology(
        tiers^, nodes^, List[Int](), False, False, n
    )


# =============================================================================
# Pure helpers
# =============================================================================


def _sorted_unique(xs: List[Int]) -> List[Int]:
    """`xs` sorted ascending, duplicates removed. O(n^2) insertion — n is the
    logical-CPU count (O(100) at most)."""
    var out = List[Int]()
    for i in range(len(xs)):
        var v = xs[i]
        var dup = False
        for j in range(len(out)):
            if out[j] == v:
                dup = True
                break
        if dup:
            continue
        var pos = len(out)
        for j in range(len(out)):
            if out[j] > v:
                pos = j
                break
        out.insert(pos, v)
    return out^


# =============================================================================
# DETECTION — thin sysfs / sysctl layer feeding the pure functions.
# Fails soft to `flat_topology()` at every step (design §D.3). NEVER raises.
# =============================================================================


struct MachineTopologyProbe:
    """Namespace for the platform `detect()` entry (kept a struct so the
    public surface is `MachineTopologyProbe.detect()`, mirroring
    `CpuTopology.detect()` / `HardwareTopology.detect()`)."""

    @staticmethod
    def detect() -> MachineTopology:
        """Probe the current machine. Linux: cpufreq P/E clustering + L2 +
        NUMA. macOS: perflevels. Other / probe-failure: `flat_topology()`.
        NEVER raises."""
        comptime if CompilationTarget.is_linux():
            return MachineTopologyProbe._detect_linux()
        elif CompilationTarget.is_macos():
            return MachineTopologyProbe._detect_macos()
        else:
            return flat_topology(_process_physical_core_count())

    @staticmethod
    def _detect_linux() -> MachineTopology:
        """Linux arm: allowed set → per-cpu cpufreq max + L2 shared list +
        thread siblings → tiers; node/ NUMA. Fails soft to flat."""
        var allowed = _read_allowed_cpus()
        if len(allowed) == 0:
            return flat_topology(_process_physical_core_count())

        var freqs = List[Int]()
        var l2_lists = List[List[Int]]()
        var sib_lists = List[List[Int]]()
        var any_freq = False
        for i in range(len(allowed)):
            var cpu = allowed[i]
            var f = _read_cpu_int(cpu, String("cpufreq/cpuinfo_max_freq"))
            if f > 0:
                any_freq = True
            freqs.append(f)
            l2_lists.append(_read_cpu_list_file(cpu, String("cache/index2/shared_cpu_list")))
            sib_lists.append(_read_cpu_list_file(cpu, String("topology/thread_siblings_list")))

        var tiers: List[CpuTier]
        if any_freq:
            tiers = derive_freq_tiers(allowed, freqs, l2_lists)
        else:
            # No cpufreq (VM / hardened): try cpu_capacity (ARM-Linux), else flat.
            var caps = List[Int]()
            var any_cap = False
            for i in range(len(allowed)):
                var c = _read_cpu_int(allowed[i], String("cpu_capacity"))
                if c > 0:
                    any_cap = True
                caps.append(c)
            if any_cap:
                tiers = derive_capacity_tiers(allowed, caps, l2_lists)
            else:
                return flat_topology(len(allowed))

        var has_smt = derive_smt(sib_lists)
        var nodes = _read_numa_nodes(allowed)
        var distance = _read_numa_distance(len(nodes))
        return MachineTopology(
            tiers^, nodes^, distance^, has_smt, False, len(allowed)
        )

    @staticmethod
    def _detect_macos() -> MachineTopology:
        """macOS arm: `hw.perflevelN.physicalcpu`. advisory_affinity=True
        (thread_policy_set is a hint, not a pin — design §D.4)."""
        var p = _sysctl_u64(String("hw.perflevel0.physicalcpu"))
        var e = _sysctl_u64(String("hw.perflevel1.physicalcpu"))
        if p <= 0:
            var total = _sysctl_u64(String("hw.physicalcpu"))
            if total <= 0:
                return flat_topology(_process_physical_core_count())
            return flat_topology(Int(total))
        var tiers = derive_perflevel_tiers(Int(p), Int(e) if e > 0 else 0)
        var total = Int(p) + (Int(e) if e > 0 else 0)
        var nodes = List[NumaNode]()
        var all_cpus = List[Int]()
        for i in range(total):
            all_cpus.append(i)
        nodes.append(NumaNode(0, all_cpus^))
        return MachineTopology(
            tiers^, nodes^, List[Int](), False, True, total
        )


# =============================================================================
# Internal sysfs / sysctl readers (FFI fully confined; mirrors the proven
# patterns in cpu_topology.mojo / hardware_topology.mojo).
# =============================================================================


def _read_allowed_cpus() -> List[Int]:
    """Allowed logical-CPU set — the PROCESS-WIDE one, sampled once.

    : this used to carry its own inline
    `sched_getaffinity(0, ...)` probe, a byte-for-byte clone of the one in
    `cpu_topology.mojo`. It therefore carried the identical defect: on Linux
    `pid == 0` is the CALLING THREAD, so a `MachineTopologyProbe.detect()`
    issued from a thread that had pinned itself derived tiers over a ONE-CPU
    allowed set and collapsed to `flat_topology(1)` — silently wrong morsel
    grain for the whole engine.

    It now DELEGATES to `komira_host.cpu_topology`'s process-wide
    snapshot, which is taken once (and always before any in-tree thread pin
    narrows a mask). One probe, one answer, one place to reason about it —
    the duplicate FFI is gone rather than fixed twice.

    Returns:
        The allowed set as a sorted List[Int]; EMPTY on any probe failure or
        on non-Linux (callers fall soft to `flat_topology`).
    """
    return _core_read_allowed_cpus()


def _read_cpu_int(cpu: Int, var rel: String) -> Int:
    """Read `/sys/devices/system/cpu/cpu<cpu>/<rel>` as a single integer.
    Returns 0 on any failure."""
    var path = String("/sys/devices/system/cpu/cpu")
    path += String(cpu)
    path += String("/")
    path += rel^
    var contents = _read_small_file(path^)
    if contents.byte_length() == 0:
        return 0
    var bs = contents.as_bytes()
    var n = contents.byte_length()
    var val = 0
    var i = 0
    while i < n:
        var d = Int(bs[i])
        if d >= _ASCII_ZERO and d <= _ASCII_NINE:
            val = val * 10 + (d - _ASCII_ZERO)
            i += 1
        else:
            break
    return val


def _read_cpu_list_file(cpu: Int, var rel: String) -> List[Int]:
    """Read + parse a cpu-list file under
    `/sys/devices/system/cpu/cpu<cpu>/<rel>` (e.g. `topology/thread_siblings_list`
    or `cache/index2/shared_cpu_list`). Empty on failure."""
    var path = String("/sys/devices/system/cpu/cpu")
    path += String(cpu)
    path += String("/")
    path += rel^
    var contents = _read_small_file(path^)
    if contents.byte_length() == 0:
        return List[Int]()
    return _parse_cpu_list(contents)


def _read_numa_nodes(allowed: List[Int]) -> List[NumaNode]:
    """Read `/sys/devices/system/node/node<k>/cpulist` for k=0.. until the
    first missing node, intersecting with `allowed`. On failure returns one
    node holding all allowed cpus (single-node fallback)."""
    var nodes = List[NumaNode]()
    var k = 0
    while k < 4096:
        var path = String("/sys/devices/system/node/node")
        path += String(k)
        path += String("/cpulist")
        var contents = _read_small_file(path^)
        if contents.byte_length() == 0:
            break
        var cpus = _parse_cpu_list(contents)
        # Intersect with allowed.
        var local = List[Int]()
        for i in range(len(cpus)):
            for j in range(len(allowed)):
                if allowed[j] == cpus[i]:
                    local.append(cpus[i])
                    break
        nodes.append(NumaNode(k, local^))
        k += 1
    if len(nodes) == 0:
        var all_cpus = List[Int]()
        for i in range(len(allowed)):
            all_cpus.append(allowed[i])
        nodes.append(NumaNode(0, all_cpus^))
    return nodes^


def _read_numa_distance(n_nodes: Int) -> List[Int]:
    """Read `/sys/devices/system/node/node<i>/distance` into a row-major
    n×n matrix. Empty (no matrix) when <2 nodes or any row unreadable."""
    var out = List[Int]()
    if n_nodes < 2:
        return out^
    for i in range(n_nodes):
        var path = String("/sys/devices/system/node/node")
        path += String(i)
        path += String("/distance")
        var contents = _read_small_file(path^)
        if contents.byte_length() == 0:
            return List[Int]()
        var row = _parse_int_row(contents)
        if len(row) != n_nodes:
            return List[Int]()
        for j in range(n_nodes):
            out.append(row[j])
    return out^


def _parse_cpu_list(s: String) -> List[Int]:
    """Parse a Linux cpu-list ("0,44" / "0-1" / "0-21,44-65") into the
    expanded index list. Mirrors cpu_topology.mojo `_parse_cpu_list`."""
    var out = List[Int]()
    var n = s.byte_length()
    if n == 0:
        return out^
    var bs = s.as_bytes()
    var i = 0
    while i < n:
        var c = Int(bs[i])
        if (
            c == _ASCII_COMMA
            or c == _ASCII_SPACE
            or c == _ASCII_NEWLINE
            or c < _ASCII_ZERO
            or c > _ASCII_NINE
        ):
            i += 1
            continue
        var lo = 0
        while i < n:
            var d = Int(bs[i])
            if d >= _ASCII_ZERO and d <= _ASCII_NINE:
                lo = lo * 10 + (d - _ASCII_ZERO)
                i += 1
            else:
                break
        var hi = lo
        if i < n and Int(bs[i]) == _ASCII_DASH:
            i += 1
            var h = 0
            var saw_digit = False
            while i < n:
                var d = Int(bs[i])
                if d >= _ASCII_ZERO and d <= _ASCII_NINE:
                    h = h * 10 + (d - _ASCII_ZERO)
                    saw_digit = True
                    i += 1
                else:
                    break
            if saw_digit:
                hi = h
        if hi >= lo:
            var v = lo
            while v <= hi:
                out.append(v)
                v += 1
    return out^


def _parse_int_row(s: String) -> List[Int]:
    """Parse a whitespace-separated integer row (NUMA distance line
    "10 21")."""
    var out = List[Int]()
    var n = s.byte_length()
    if n == 0:
        return out^
    var bs = s.as_bytes()
    var i = 0
    while i < n:
        var d = Int(bs[i])
        if d < _ASCII_ZERO or d > _ASCII_NINE:
            i += 1
            continue
        var v = 0
        while i < n:
            var e = Int(bs[i])
            if e >= _ASCII_ZERO and e <= _ASCII_NINE:
                v = v * 10 + (e - _ASCII_ZERO)
                i += 1
            else:
                break
        out.append(v)
    return out^


def _read_small_file(var path: String) -> String:
    """fopen + fread + fclose of a small sysfs file, capped at
    `_SYSFS_FILE_MAX`. "" on any error. Mirrors cpu_topology.mojo
    `_read_small_file`.

    SAFETY: `buf` heap-allocated + freed before return; `fp` null-checked;
    `path` by-value so `.as_c_string_slice()` may NUL-append."""
    comptime if CompilationTarget.is_linux():
        var c_path = path.as_c_string_slice().unsafe_ptr()
        var mode_str = String("rb")
        var c_mode = mode_str.as_c_string_slice().unsafe_ptr()
        # FFI-BOUNDARY: libc fopen. Library: libc.so.6.
        var fp = external_call["fopen", Int64](c_path, c_mode)
        if fp == 0:
            return String("")
        var buf = alloc[UInt8](_SYSFS_FILE_MAX)
        # FFI-BOUNDARY: fread(ptr, size, nmemb, FILE*) -> size_t.
        var n_read = external_call["fread", Int64](
            buf, Int64(1), Int64(_SYSFS_FILE_MAX), fp
        )
        _ = external_call["fclose", Int32](fp)
        if n_read <= 0:
            buf.free()
            return String("")
        var n_int = Int(n_read)
        # ⛔ DO NOT REWRITE THIS AS `s += chr(Int(buf[i]))` PER BYTE. That was
        # this body until 2026-09-07 and it is the repo-wide `chr(Int(byte))`
        # defect: `chr` maps a CODE POINT to its UTF-8 ENCODING, so any byte
        # >= 0x80 is re-encoded into two rather than reproduced.
        #
        # ⚠ NO OBSERVABLE BEHAVIOUR CHANGED HERE, AND THAT IS ESTABLISHED,
        # NOT ASSUMED. All four callers read sysfs files whose contents the
        # kernel ABI fixes to ASCII digits / `,` / `-` / `\n`
        # (`cpu<N>/topology/*`, `cpu<N>/cache/index*/shared_cpu_list`,
        # `node<K>/cpulist`, `node<K>/distance`), and each consumer
        # (`_read_cpu_int`, `_parse_cpu_list`, `_parse_int_row`) stops at the
        # first non-digit anyway. So this is the defect SHAPE with no
        # reachable non-ASCII input — fixed to stop the shape propagating by
        # copy, which is exactly how it reached four other sites in this
        # package family. There is consequently NO test that can distinguish
        # this arm; do not go looking for one.
        #
        # SAFETY: `buf` is this frame's heap allocation, `n_int <= n_read <=
        # _SYSFS_FILE_MAX`, the Span is length-explicit and the String
        # constructor copies before `buf.free()`. Pointer arithmetic does not
        # leave this function.
        var s = String(
            StringSlice(unsafe_from_utf8=Span(unsafe_ptr=buf, length=n_int))
        )
        buf.free()
        return s
    else:
        return String("")


def _sysctl_u64(var name: String) -> Int:
    """Read a sysctl key as u64 (darwin). 0 on failure. Mirrors
    hardware_topology.mojo `_sysctl_u64`.

    SAFETY: `val_buf`/`len_buf` heap-allocated + freed before return; result
    read little-endian byte-by-byte (no aliasing cast)."""
    var val_buf = alloc[UInt8](8)
    var len_buf = alloc[UInt8](8)
    for i in range(8):
        val_buf[i] = 0
    len_buf[0] = 8
    for i in range(1, 8):
        len_buf[i] = 0

    var result: Int = 0
    comptime if CompilationTarget.is_macos():
        var name_ptr = name.as_c_string_slice().unsafe_ptr()
        # FFI-BOUNDARY: darwin sysctlbyname(). The (newp,newlen)=(NULL,0)
        # no-write sentinel is passed as an Optional[UnsafePointer] None
        # (all-zero NULL bit pattern), avoiding the banned MutExternalOrigin.
        var none: Optional[UnsafePointer[UInt8, ImmStaticOrigin]] = None
        var null_ptr = UnsafePointer(to=none).bitcast[
            UnsafePointer[UInt8, ImmStaticOrigin]
        ]()[]
        var ret = external_call["sysctlbyname", c_int](
            name_ptr, val_buf, len_buf, null_ptr, UInt64(0)
        )
        if ret == 0:
            var acc: UInt64 = 0
            for i in range(8):
                acc = acc | (UInt64(val_buf[i]) << (UInt64(i) * 8))
            result = Int(acc)
    else:
        result = 0
    val_buf.free()
    len_buf.free()
    return result
