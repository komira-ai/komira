# =============================================================================
# l2_share.mojo -- the PER-WORKER L2 SHARE derivation (the grain's binding input)
# =============================================================================
#
# WHY THIS MODULE EXISTS
# ----------------------
# Every morsel/chunk grain in the engine is ultimately "how many rows fit in the
# slice of L2 that ONE compute worker actually owns". DuckDB answers that
# question with a hardcoded constant (`STANDARD_VECTOR_SIZE == 2048` rows, the
# same on every machine, chosen small enough to be safe everywhere). We answer it
# from the MEASURED cache hierarchy -- which is only an advantage if the
# measurement is right. On a hybrid (P-core + E-core) part it was not:
#
#   * `HardwareProfile._detect_linux_or_fallback` read cpu0's caches ONLY and
#     hardcoded a sharing divisor of 1. On this 14700K that is cpu0's PRIVATE
#     P-core L2: 2 MiB / 1 = 2 MiB per worker. The real binding share is the
#     E-cluster's 4 MiB / 4 cores = 1 MiB. TWO TIMES TOO LARGE -- the grain
#     overflows every E-core's L2 share, destroying the residency the sizing
#     exists to create.
#   * `komira_engine_v2/grain.mojo` tried to correct that with
#     `MachineTopology`'s E-tier `shared_cpu_list` divisor, but paired that
#     divisor with `HardwareProfile`'s cpu0 SIZE: 2 MiB (a P instance) / 4 (the
#     E instance's divisor) = 512 KiB. TWO TIMES TOO SMALL. A size from one tier
#     divided by a divisor from another is not a share of anything.
#
# The fix is not a better divisor. It is to stop treating "L2 size" and "how many
# workers share it" as two independently-detected scalars: they are two
# properties of ONE L2 INSTANCE and must be read together, per instance.
#
# =============================================================================
# THE FORMULA (and its derivation -- check it, do not trust it)
# =============================================================================
#
# Let `allowed` be the PROCESS-WIDE allowed logical-CPU set (the snapshot in
# `komira_host.cpu_topology`, NOT a live per-thread
# `sched_getaffinity` -- see THE AFFINITY CONTRACT below).
#
# For each distinct L2 INSTANCE `I` reachable by this process:
#
#     size(I)      = the instance's capacity, bytes         [cache/indexN/size]
#     shared(I)    = logical CPUs sharing it     [cache/indexN/shared_cpu_list]
#     core(c)      = min( thread_siblings_list(c) ∩ allowed )   -- canonical id
#     cores(I)     = | { core(c) : c ∈ shared(I) ∩ allowed } |
#     workers(I)   = cores(I)
#     share(I)     = size(I) / workers(I)
#
#     L2_PER_WORKER = min over all I with workers(I) >= 1 of share(I)
#
# and the grain the engine finally uses is
#
#     grain = quantize( clamp(
#                 (L2_PER_WORKER * BUDGET_NUM / BUDGET_DEN) / max(row_width, 1)
#                 * tier_multiplier,
#                 MIN_ROWS, MAX_ROWS) )
#
# where `row_width` is the summed byte width of the LIVE (post-projection)
# columns and `BUDGET_NUM/BUDGET_DEN = 1/2` (see WHY HALF, below).
#
# --- WHY `workers(I) == cores(I)` AND NOT `|shared(I)|` ----------------------
#
# `shared_cpu_list` counts LOGICAL CPUs. The engine's compute pool is sized
# `CpuTopology.physical_core_count()` and placed one worker per PHYSICAL core
# (`derive_pools` holds `len(_compute) == physical_core_count`, and
# `engine_worker_count()` returns exactly that). So the number of compute
# workers that can concurrently occupy an L2 instance is the number of physical
# cores behind it, not the number of hardware threads.
#
# This is load-bearing, not cosmetic. Using the logical-CPU count would halve
# the reported share on EVERY SMT machine: a Xeon with a private 1 MiB L2 and
# `shared_cpu_list = "0,44"` would report 512 KiB per worker while exactly one
# compute worker ever runs on that core. On this 14700K it would report the
# P-core instances at 1 MiB instead of 2 MiB.
#
# RESIDUAL, STATED: with `KOMIRA_ENGINE_PIN` OFF the OS may transiently
# co-schedule two compute workers onto one physical core, momentarily halving
# that core's share. The 1/2 budget fraction already reserves headroom for
# exactly this class of over-subscription (see WHY HALF); we do not double-count
# it by also dividing by the SMT width.
#
# --- WHY `min OVER INSTANCES` AND NOT "the slowest tier" ---------------------
#
# The grain is ONE number used by every worker on every tier (per maintainer decision
#: no per-tier specialization, no two code paths). A single value
# is safe only if it fits the SMALLEST per-worker share anywhere in the reachable
# machine -- that is precisely what "lowest common denominator" means.
#
# On a hybrid part that minimum IS the slowest tier, which is why this agrees
# with the "slowest tier" framing: on this 14700K the E instances give
# 4 MiB / 4 = 1 MiB and the P instances give 2 MiB / 1 = 2 MiB, so the minimum
# is the E tier. Computing the minimum directly is strictly better than
# computing it via tier labels, because it needs NO `cpuinfo_max_freq` /
# `cpu_capacity` probe to decide which tier is slower -- so it still produces
# the right number inside a VM or a container where those files are absent and
# P/E clustering silently collapses to one tier.
#
# --- WHY HALF (`BUDGET_NUM/BUDGET_DEN = 1/2`) --------------------------------
#
# The worker's L2 share holds more than the morsel: the hash-table heads /
# accumulator slots / dispatch structs of the operator consuming it, plus any
# transient SMT co-residency (above). Reserving half for that is the same
# constant the engine has used since v0.3 `optimal_agg_morsel_rows`; this module
# does not change it, it only fixes the number it multiplies.
#
# =============================================================================
# THE AFFINITY CONTRACT
# =============================================================================
# `allowed` MUST come from the process-wide snapshot
# (`komira_host.cpu_topology._read_allowed_cpus`), never from a live
# `sched_getaffinity(0, ...)`: on Linux `pid == 0` is the CALLING THREAD, so a
# probe issued from a pinned thread sees a one-CPU machine and derives a grain
# for it. That is the same defect class fixed for the worker-pool sizing in
# `` (). This module is PURE -- it takes `allowed`
# as an argument -- so the contract is discharged by its one caller
# (`HardwareProfile._linux_probe_binding_l2`), which reads the snapshot.
#
# =============================================================================
# PURITY / TESTABILITY
# =============================================================================
# Everything here is a PURE function over injected sysfs-shaped facts: no FFI,
# no filesystem, no syscalls, no platform branches. That is what lets
# `tests/unit/test_l2_share_hybrid.mojo` assert the derived share on a
# FABRICATED hybrid topology on any machine, including a non-hybrid CI box.
# The thin probe that reads real sysfs lives in `hardware.mojo` (which already
# owns those readers), so this module has no import cycle with it.
#
# Mojo safety: no `UnsafePointer` anywhere (public or private); every type is a
# POD `Int` / `List[Int]` / a two-Int struct. Nothing here can be a gap6 shape.
# =============================================================================


# =============================================================================
# L2Instance -- one L2 cache instance and the workers behind it
# =============================================================================


struct L2Instance(Copyable, ImplicitlyCopyable, Movable, Writable):
    """One L2 cache instance, plus how many COMPUTE WORKERS share it.

    Fields:
      * `size_bytes`: the instance's capacity. 0 == "unknown / no instance".
      * `workers`: distinct physical cores (== compute workers, see the module
        header) behind this instance, restricted to the allowed CPU set.
        0 == "unknown / no instance".

    `L2Instance(0, 0)` is the UNKNOWN sentinel returned when no usable instance
    could be derived; callers must treat it as "fall back conservatively" and
    never as "a zero-byte cache".
    """

    var size_bytes: Int
    var workers: Int

    def __init__(out self, size_bytes: Int, workers: Int):
        self.size_bytes = size_bytes
        self.workers = workers

    @always_inline
    def is_known(self) -> Bool:
        """True iff both the size and the worker count were derivable."""
        return self.size_bytes > 0 and self.workers > 0

    @always_inline
    def share_bytes(self) -> Int:
        """This instance's per-worker share in bytes (`size / workers`).

        Returns 0 for the UNKNOWN sentinel, so a caller that forgets to check
        `is_known()` gets a falsy value rather than a divide-by-zero.
        """
        if not self.is_known():
            return 0
        return self.size_bytes // self.workers

    def write_to[W: Writer](self, mut writer: W):
        writer.write(
            "L2Instance(size=", self.size_bytes,
            ", workers=", self.workers,
            ", share=", self.share_bytes(),
            ")",
        )


# =============================================================================
# THE DERIVATION (pure)
# =============================================================================


def derive_binding_l2_instance(
    cpus: List[Int],
    l2_sizes: List[Int],
    l2_shared_lists: List[List[Int]],
    sibling_lists: List[List[Int]],
) -> L2Instance:
    """The L2 instance with the SMALLEST per-worker share -- the one the grain
    must fit (the module header's `L2_PER_WORKER`).

    PURE. No syscalls, no sysfs; every input is a fact a caller read (or a test
    fabricated). The four lists are PARALLEL: entry `i` describes `cpus[i]`.

    Args:
        cpus: The allowed logical-CPU indices (the process-wide snapshot -- see
            THE AFFINITY CONTRACT in the module header). Any order; deduped
            internally.
        l2_sizes: `cpus[i]`'s L2 instance capacity in bytes, or <= 0 when the
            `size` file was unreadable.
        l2_shared_lists: `cpus[i]`'s `shared_cpu_list`, expanded. EMPTY means
            the file was unreadable.
        sibling_lists: `cpus[i]`'s `thread_siblings_list`, expanded. EMPTY means
            unreadable -- the CPU is then treated as its own physical core,
            which is the no-SMT shape and the only safe reading (assuming a
            sibling we cannot see would INFLATE the share).

    Returns:
        The minimum-share `L2Instance`, or the UNKNOWN sentinel
        `L2Instance(0, 0)` when no instance had BOTH a readable size and a
        readable sharing set. We never guess a share we cannot compute: an
        instance missing either fact is SKIPPED, and if that leaves nothing the
        caller falls back to its own conservative default.

    Shapes this handles with no special case:
        * hybrid P+E  -> the E cluster wins the min (verified in the tests).
        * non-hybrid  -> every instance is identical; the min is that value.
        * no-SMT      -> singleton sibling lists; workers == |shared|.
        * cpuset pin  -> `cpus` is the restricted set, so instances outside it
                         contribute nothing and partially-visible instances
                         count only their visible cores.
        * 4-core box  -> 4 single-core instances; the min is one core's L2.
        * unreadable  -> UNKNOWN sentinel (see above).
    """
    var allowed = _sorted_unique(cpus)
    var n = len(cpus)
    if n == 0 or len(allowed) == 0:
        return L2Instance(0, 0)

    # `covered[i]` == this cpu's L2 instance has already been accounted for
    # (some earlier cpu's `shared_cpu_list` contained it). Walking cpus in
    # ascending order and skipping covered ones visits each INSTANCE exactly
    # once, which is what makes the min a min over instances and not over cpus.
    var covered = List[Bool]()
    for _ in range(n):
        covered.append(False)

    var best = L2Instance(0, 0)
    var best_share = 0

    for i in range(n):
        if covered[i]:
            continue

        # --- the instance's sharing set, restricted to what we may run on ----
        if i >= len(l2_shared_lists) or len(l2_shared_lists[i]) == 0:
            # No `shared_cpu_list`: we cannot know how many workers contend for
            # this instance. Mark the cpu covered so we do not re-examine it,
            # and SKIP -- guessing 1 here would silently inflate the share on
            # exactly the hardened-container shape we are trying to be safe on.
            covered[i] = True
            continue
        var shared = _intersect_sorted(l2_shared_lists[i], allowed)
        # Mark every member covered (including this cpu) so the instance is
        # counted once. Do this BEFORE the size check so an instance with an
        # unreadable size does not get re-derived through a sibling cpu.
        for k in range(len(shared)):
            var idx = _index_of(cpus, shared[k])
            if idx >= 0:
                covered[idx] = True
        covered[i] = True
        if len(shared) == 0:
            continue

        # --- the instance's capacity -----------------------------------------
        var size = l2_sizes[i] if i < len(l2_sizes) else 0
        if size <= 0:
            continue

        # --- workers == distinct physical cores behind the instance ----------
        var workers = _distinct_core_count(shared, allowed, cpus, sibling_lists)
        if workers < 1:
            continue

        var share = size // workers
        if share <= 0:
            continue
        if best_share == 0 or share < best_share:
            best_share = share
            best = L2Instance(size, workers)

    return best


def derive_l2_bytes_per_worker(
    cpus: List[Int],
    l2_sizes: List[Int],
    l2_shared_lists: List[List[Int]],
    sibling_lists: List[List[Int]],
) -> Int:
    """`derive_binding_l2_instance(...).share_bytes()` -- the single number the
    grain formula multiplies. 0 when unknown (caller falls back)."""
    return derive_binding_l2_instance(
        cpus, l2_sizes, l2_shared_lists, sibling_lists
    ).share_bytes()


# =============================================================================
# Pure helpers
# =============================================================================


def _distinct_core_count(
    shared: List[Int],
    allowed: List[Int],
    cpus: List[Int],
    sibling_lists: List[List[Int]],
) -> Int:
    """Number of distinct PHYSICAL cores among `shared`.

    A cpu's canonical core id is the lowest-numbered ALLOWED member of its
    `thread_siblings_list` (the same canonicalization `derive_pools` uses to
    build the compute lane, so the count here is exactly the number of compute
    workers that lane will place on this L2 instance). A cpu with no readable
    sibling list is its own core.
    """
    var seen = List[Int]()
    for i in range(len(shared)):
        var canon = _canonical_core_id(shared[i], allowed, cpus, sibling_lists)
        var dup = False
        for j in range(len(seen)):
            if seen[j] == canon:
                dup = True
                break
        if not dup:
            seen.append(canon)
    return len(seen)


def _canonical_core_id(
    cpu: Int,
    allowed: List[Int],
    cpus: List[Int],
    sibling_lists: List[List[Int]],
) -> Int:
    """`min(thread_siblings_list(cpu) ∩ allowed)`, or `cpu` when the sibling
    list is unreadable / contains no allowed member."""
    var idx = _index_of(cpus, cpu)
    if idx < 0 or idx >= len(sibling_lists):
        return cpu
    var best = cpu
    for i in range(len(sibling_lists[idx])):
        var s = sibling_lists[idx][i]
        if s < best and _contains(allowed, s):
            best = s
    return best


def _intersect_sorted(xs: List[Int], allowed: List[Int]) -> List[Int]:
    """`xs ∩ allowed`, sorted ascending, deduped."""
    var hits = List[Int]()
    for i in range(len(xs)):
        if _contains(allowed, xs[i]):
            hits.append(xs[i])
    return _sorted_unique(hits)


def _index_of(xs: List[Int], v: Int) -> Int:
    for i in range(len(xs)):
        if xs[i] == v:
            return i
    return -1


def _contains(xs: List[Int], v: Int) -> Bool:
    for i in range(len(xs)):
        if xs[i] == v:
            return True
    return False


def _sorted_unique(xs: List[Int]) -> List[Int]:
    """`xs` sorted ascending, duplicates removed. O(n^2) insertion -- n is the
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
# sysfs cpu-list parsing (pure)
# =============================================================================
#
# CONSOLIDATION NOTE: `komira_host/cpu_topology.mojo` and
# `komira_engine_runtime/machine_topology.mojo` each carry a PRIVATE copy of
# this parser. This one is PUBLIC because the probe that feeds this module lives
# in another file (`hardware.mojo`) and must not duplicate it a fourth time.
# Folding the two private copies onto this one is a mechanical follow-up; it is
# deliberately NOT done here so this change does not churn the scheduler POC's
# topology module.
# =============================================================================

comptime _ASCII_ZERO: Int = 48
comptime _ASCII_NINE: Int = 57
comptime _ASCII_DASH: Int = 45


def parse_cpu_list(s: String) -> List[Int]:
    """Parse a Linux cpu-list ("0,44" / "0-1" / "0-21,44-65") into the expanded
    index list. Empty input / no digits -> empty list."""
    var out = List[Int]()
    var n = s.byte_length()
    if n == 0:
        return out^
    var bs = s.as_bytes()
    var i = 0
    while i < n:
        var c = Int(bs[i])
        if c < _ASCII_ZERO or c > _ASCII_NINE:
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
