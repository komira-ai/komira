# =============================================================================
# CpuTopology -- cgroup/cpuset-aware CPU resource model with HT-sibling split
# =============================================================================
#
# THE PROBLEM (the empirical motivation)
# --------------------------------------
# A container NUMA-pinned (cpuset) to one socket still reports `nproc=88` (the
# HOST's full logical-thread count) -- so a runtime that sizes its thread pool
# to `nproc` over-threads a 22-physical-core pin. Two failures result:
#   (1) Over-threading past the cpuset triggers contention stalls in the
#       Mojo async runtime.
#   (2) Hyperthreads get wasted: a runtime that treats every logical CPU as a
#       compute lane thrashes the shared ALUs of each physical core.
#
# THE MODEL
# ---------
# We answer "what can THIS process actually run on, and how should it split
# compute vs IO work across the physical-core / hyperthread topology?" by:
#
#   1. ALLOWED CPU SET via `sched_getaffinity(0, ...)` -- this reflects the
#      cpuset/container pin, UNLIKE raw `nproc`. This is authoritative.
#      CAUTION: `pid == 0` there means the CALLING THREAD, so this probe is
#      taken ONCE per process and frozen (`_read_allowed_cpus`); a thread that
#      pins itself must not be able to shrink the engine's idea of the machine.
#   2. PHYSICAL-CORE GROUPING via
#      `/sys/devices/system/cpu/cpu<N>/topology/thread_siblings_list` -- each
#      allowed logical CPU is grouped into its physical core (its sibling set).
#   3. The HYPERTHREAD SPLIT (HT physics): a compute thread saturates a core's
#      ALUs while its IO/blocking sibling mostly stalls on syscalls -- so the
#      pair does NOT contend. Two compute threads on a pair thrash. Therefore:
#        * COMPUTE pool = one logical CPU per physical core (the primary
#          sibling) -- this is the right COMPUTE parallelism.
#        * IO pool = the OTHER sibling of each core -- the blocking/IO lane.
#   4. (best-effort) cgroup `cpu.max` (v2) quota cap -- a CPU-QUOTA-limited
#      container (quota, not cpuset) ALSO needs a correct count; the effective
#      compute count is the MIN of the cpuset-derived count and the quota cap.
#
# DESIGN FOR TESTABILITY + SAFETY
# -------------------------------
# The PURE grouping logic (`derive_pools`) is separated from all syscall/sysfs
# IO. `derive_pools` takes synthetic inputs (an allowed list + a per-cpu
# sibling-group lookup) and is fully unit-testable with no host dependency.
# A thin `CpuTopology.detect()` layer reads the real affinity + /sys and feeds
# the pure function.
#
# Mojo safety:
#   * NO UnsafePointer crosses a module boundary -- the public API exposes only
#     `Int` / `List[Int]` / `CpuTopology`. The cpu_set_t bit-mask handling and
#     all FFI buffers are confined to private helpers with `# SAFETY:` blocks.
#   * NO owning wildcard-origin FIELDS. The only untracked origin is the
#     POSIX null-sentinel passed to a no-write FFI arg, per-site SAFETY
#     inline.
#   * Allocations stay function-local (`alloc[UInt8]` for the FFI mask buffer,
#     freed before return). No raw `alloc` escapes.
#
# GRACEFUL FALLBACK
# -----------------
# If `sched_getaffinity` fails or /sys is unreadable (hardened K8s with
# read_only_root_filesystem, non-Linux), `detect()` falls back to a sane
# all-allowed-as-compute layout (`io` empty) sized by `num_physical_cores()`.
# It NEVER raises and NEVER crashes.
#
# PLATFORM
# --------
# The affinity + sysfs probe is Linux-only (gated `comptime if is_linux()`).
# On macOS / other, `detect()` returns the `num_physical_cores()` fallback
# (Darwin has no `sched_getaffinity`; `thread_policy_set` affinity is advisory
# and out of scope here).
# =============================================================================

# =============================================================================
# FFI-BOUNDARY: libc sched_getaffinity(2) / sched_setaffinity(2) +
#               fopen/fread/fclose for sysfs reads.
# =============================================================================
# The cpu_set_t bit mask is a kernel-defined array of unsigned long; the glibc
# `cpu_set_t` is 128 bytes (1024 bits / 1024 CPUs). We pass a heap-allocated
# 128-byte UInt8 buffer as the mask. The null sentinel does not appear here (no no-write arg); all pointers are concrete-origin heap
# allocations freed before return. Per-site SAFETY inline.
# =============================================================================

from std.ffi import external_call, c_int, _Global
from std.memory import OwnedPointer, UnsafePointer, alloc
from std.sys import num_physical_cores
from std.sys.info import CompilationTarget

from komira_host.engine_placement import EnginePlacement


# =============================================================================
# Constants
# =============================================================================

# glibc cpu_set_t is 128 bytes = 1024 bits = up to 1024 CPUs. Matches
# CPU_SETSIZE. sched_getaffinity fails EINVAL if the kernel affinity mask is
# larger than the buffer, so 128 is the safe ceiling for any realistic host.
comptime _CPU_SET_BYTES: Int = 128
comptime _CPU_SET_MAX: Int = _CPU_SET_BYTES * 8  # 1024

# The same 1024-bit set expressed as UInt64 words — the snapshot's storage.
comptime _CPU_SET_WORDS: Int = _CPU_SET_BYTES // 8  # 16

# Max sysfs file we read for a thread_siblings_list (e.g. "0-21,44-65\n").
comptime _SIBLINGS_FILE_MAX: Int = 1024

# ASCII codepoints for the byte-level sibling-list parser.
comptime _ASCII_ZERO: Int = 48      # '0'
comptime _ASCII_NINE: Int = 57      # '9'
comptime _ASCII_COMMA: Int = 44     # ','
comptime _ASCII_DASH: Int = 45      # '-'
comptime _ASCII_NEWLINE: Int = 10   # '\n'
comptime _ASCII_SPACE: Int = 32     # ' '


# =============================================================================
# CpuTopology -- the public primitive
# =============================================================================


struct CpuTopology(Copyable, Movable, Writable):
    """The cgroup/cpuset-aware CPU resource model with a compute/IO hyperthread
    split.

    Construct via `CpuTopology.detect()` (the real probe) or via the
    fields-ctor for tests. Consumers read only the safe accessors -- the raw
    cpu_set_t handling never escapes this module.

    Fields (all derived; all in terms of LOGICAL-CPU index lists / counts):
      * `_allowed`: the full set of logical CPUs this process may run on
        (sorted ascending). Authoritative (respects cpuset/container).
      * `_compute`: one logical CPU per physical core -- the COMPUTE lane.
        `len(_compute) == physical_core_count`.
      * `_io`: the OTHER sibling of each physical core -- the IO/blocking lane.
        May be EMPTY when HT is disabled or only one sibling per core is
        allowed. Disjoint from `_compute` by construction.
      * `_driver`: the RESERVED driver/main-thread CPU, or -1 for "no
        reservation" (the default and the shape `derive_pools` always
        produces). Set only by `derive_driver_reservation`. When
        `>= 0` it is guaranteed NOT to be in `_compute`; it MAY be in `_io`
        (that overlap is deliberate -- see `derive_driver_reservation`).

    INVARIANTS (held by `derive_pools`):
      * `len(_compute) == physical_core_count`.
      * set(_compute) ∩ set(_io) == ∅  (a logical CPU is never both lanes).
      * set(_compute) ∪ set(_io) ⊆ set(_allowed).
      * `len(_io) <= len(_compute)`  (at most one IO sibling per core).
    ADDITIONAL INVARIANT (held by `derive_driver_reservation`):
      * `_driver == -1` OR (`_driver` ∈ `_allowed` AND `_driver` ∉ `_compute`).
    """

    var _allowed: List[Int]
    var _compute: List[Int]
    var _io: List[Int]
    var _driver: Int
    var _io_mode: UInt8

    # --- Constructors --------------------------------------------------------

    def __init__(
        out self,
        var allowed: List[Int],
        var compute: List[Int],
        var io: List[Int],
        driver: Int = -1,
        io_mode: UInt8 = IO_PLACEMENT_UNSET,
    ):
        """Construct directly from pre-derived pools (test / forced path).

        Args:
            allowed: Allowed logical-CPU indices.
            compute: Compute-lane logical CPUs (one per physical core).
            io: IO-lane logical CPUs (the sibling of each core; may be empty).
            driver: The reserved driver/main-thread CPU, or -1 (default) for
                "no reservation".
            io_mode: Which IO placement produced `io`, or
                `IO_PLACEMENT_UNSET` (default) for "raw probe, no placement
                policy applied".
        """
        self._allowed = allowed^
        self._compute = compute^
        self._io = io^
        self._driver = driver
        self._io_mode = io_mode

    # --- Safe accessors (no pointers escape) ---------------------------------

    @always_inline
    def physical_core_count(self) -> Int:
        """Number of physical cores with >= 1 allowed sibling.

        This is the right COMPUTE parallelism: one busy compute thread per
        physical core. Equals `len(compute_cpus())`.
        """
        return len(self._compute)

    def compute_cpus(self) -> List[Int]:
        """One logical CPU per physical core -- the compute-bound lane.

        Place compute workers here (e.g. the engine WorkerPool's parallel
        scan/agg/join threads). Length == `physical_core_count()`.
        """
        return self._compute.copy()

    def io_cpus(self) -> List[Int]:
        """The OTHER sibling of each physical core -- the IO/blocking lane.

        Place IO / blocking / syscall-heavy workers here so they share a
        physical core with a compute worker without contending for ALUs.
        EMPTY when HT is disabled or only one sibling per core is allowed.
        """
        return self._io.copy()

    def allowed_cpus(self) -> List[Int]:
        """The full set of logical CPUs this process may run on (sorted).

        Authoritative -- reflects the cpuset/container pin via
        `sched_getaffinity`, NOT raw `nproc`.
        """
        return self._allowed.copy()

    @always_inline
    def allowed_count(self) -> Int:
        """Count of allowed logical CPUs (== `len(allowed_cpus())`)."""
        return len(self._allowed)

    @always_inline
    def driver_cpu(self) -> Int:
        """The RESERVED driver/main-thread CPU, or -1 when no reservation is
        in effect.

        `-1` is what every `derive_pools` / `detect()` result carries: the
        reservation is a POLICY applied on top by `derive_driver_reservation`,
        never by the raw topology probe. When `>= 0`, the CPU is
        guaranteed disjoint from `compute_cpus()`.
        """
        return self._driver

    @always_inline
    def io_placement_mode(self) -> UInt8:
        """Which IO placement produced `io_cpus()`.

        `IO_PLACEMENT_UNSET` on every raw probe (`detect()` / `derive_pools`) —
        the placement is a POLICY applied on top by `derive_io_placement`, never
        part of the probe. After that policy runs it is one of
        `IO_PLACEMENT_{SIBLING,DEDICATED,DRIVER_CORESIDENT,INLINE}`.
        `IO_PLACEMENT_INLINE` <=> `len(io_cpus()) == 0` <=> no IO lane.
        """
        return self._io_mode

    # --- Detection -----------------------------------------------------------

    @staticmethod
    def detect() -> CpuTopology:
        """Probe the current process's CPU topology, cpuset-aware.

        Linux: reads `sched_getaffinity(0, ...)` for the allowed set, then
        each allowed CPU's `thread_siblings_list` from sysfs, groups by
        physical core, and derives the compute/IO split. If the cgroup v2
        `cpu.max` quota is tighter than the cpuset, the compute count is
        capped to the quota (effective = min).

        macOS / other / probe-failure: returns a single-lane fallback sized
        by `num_physical_cores()` (all allowed as compute, IO empty). NEVER
        raises.

        The RESULT is frozen once per process, not re-derived per call. Every
        input to the derivation is a process-lifetime constant:

          * the allowed set — frozen (`_read_allowed_cpus`): re-reading it per
            call would let a thread that pinned itself shrink the engine's
            idea of the machine.
          * `thread_siblings_list` — the machine's physical wiring.
          * the cgroup v2 `cpu.max` quota — frozen for the same reason the
            allowed set is: a PROCESS-WIDE question must not be able to answer
            differently at two moments inside one query.

        Not freezing it is expensive: the sysfs sibling walk is one
        open+read+close per allowed CPU (on the order of 100 us for a
        22-CPU pin), and `engine_worker_count()` reaches here once per
        materialize dispatch — i.e. once per query, ON THE DRIVER, inside
        the serial region.

        `topology_probe_count()` counts UNCACHED derivations, so a second
        `detect()` that re-probes makes it 2 and the guard test goes red.

        THE FREEZE IS UNCONDITIONAL, on every platform. On non-Linux the
        derivation is `_fallback()`, whose only input
        (`_process_physical_core_count()`) is already process-frozen in
        `_AllowedCpuSnapshot`, so the frozen answer is identical to a live
        one. Routing every platform through the snapshot keeps
        `topology_probe_count()` meaningful everywhere; a platform-specific
        unfrozen arm would bypass the counter and make its guard blind.
        """
        return _frozen_detected_topology()

    @staticmethod
    def detect_uncached() -> CpuTopology:
        """`detect()` WITHOUT the process-lifetime freeze — the probe itself.

        The frozen snapshot is derived from this, and a test proving the
        freeze IS a freeze needs the unfrozen arm to compare against.
        """
        comptime if CompilationTarget.is_linux():
            return CpuTopology._detect_linux()
        else:
            return CpuTopology._fallback()

    @staticmethod
    def _detect_linux() -> CpuTopology:
        """Linux probe arm. Fails soft to `_fallback()` at every step."""
        var allowed = _read_allowed_cpus()
        if len(allowed) == 0:
            # sched_getaffinity failed (or empty mask) -- fall back.
            return CpuTopology._fallback()

        # Build the per-allowed-cpu sibling-group lookup from sysfs. If the
        # sibling file is unreadable for a cpu (hardened container), that cpu
        # is treated as a singleton core (no IO sibling).
        var siblings_of = List[List[Int]]()
        for i in range(len(allowed)):
            var sibs = _read_thread_siblings(allowed[i])
            if len(sibs) == 0:
                # No sysfs topology -- treat as a lone core.
                var lone = List[Int]()
                lone.append(allowed[i])
                siblings_of.append(lone^)
            else:
                siblings_of.append(sibs^)

        var pools = derive_pools(allowed, siblings_of)

        # Best-effort cgroup v2 quota cap: if a CPU quota is tighter than the
        # cpuset-derived physical-core count, cap the compute pool to it.
        var quota = _read_cgroup_v2_quota_cores()
        if quota > 0 and quota < len(pools._compute):
            pools = _cap_compute(pools^, quota)

        return pools^

    @staticmethod
    def _fallback() -> CpuTopology:
        """Single-lane fallback: all physical cores as compute, IO empty. Used
        on macOS / other and on any Linux probe failure.

        Sources the count from `_process_physical_core_count()` (the snapshot),
        NOT a live `num_physical_cores()` — the latter is affinity-aware on
        Linux and would re-introduce the thread-pin collapse on this path."""
        var n = _process_physical_core_count()
        if n < 1:
            n = 1
        var allowed = List[Int]()
        var compute = List[Int]()
        for i in range(n):
            allowed.append(i)
            compute.append(i)
        var io = List[Int]()
        return CpuTopology(allowed^, compute^, io^)

    # --- Writable ------------------------------------------------------------

    def write_to[W: Writer](self, mut writer: W):
        writer.write(
            "CpuTopology(physical_cores=", len(self._compute),
            ", allowed=", len(self._allowed),
            ", io_lanes=", len(self._io),
            ", driver_cpu=", self._driver,
            ", io_mode=", self._io_mode,
            ")",
        )


# =============================================================================
# PURE LOGIC -- unit-testable with synthetic inputs (NO syscalls / NO sysfs)
# =============================================================================


def derive_pools(
    allowed: List[Int], siblings_of: List[List[Int]]
) -> CpuTopology:
    """Group allowed logical CPUs into physical cores and split into a
    compute lane (one CPU per core) + an IO lane (the sibling).

    This is the PURE heart of the primitive -- no syscalls, no filesystem.
    `allowed[i]`'s full hardware sibling set is `siblings_of[i]` (as read from
    `thread_siblings_list`; siblings NOT in `allowed` are ignored).

    Algorithm:
      * For each allowed cpu in ascending order, find the lowest-numbered
        ALLOWED sibling -> that's the core's canonical id. The first allowed
        cpu we see for a core becomes its COMPUTE lane (the primary sibling);
        the next allowed sibling of that same core becomes its IO lane. Any
        further siblings (>2-way SMT) are dropped -- we use at most a
        compute+IO pair per core.

    Args:
        allowed: Allowed logical-CPU indices (any order; deduped internally).
        siblings_of: Parallel to `allowed`; `siblings_of[i]` is the hardware
            thread-sibling list for `allowed[i]`.

    Returns:
        A `CpuTopology` with the derived compute/IO/allowed pools.

    Invariants on the result (see `CpuTopology` docstring):
        len(compute) == physical_core_count; compute ∩ io == ∅;
        compute ∪ io ⊆ allowed; len(io) <= len(compute).
    """
    # 1. Sort + dedup the allowed set so output ordering is deterministic and
    #    "lowest allowed sibling" is well-defined.
    var sorted_allowed = _sorted_unique(allowed)
    var n = len(sorted_allowed)

    # Map each allowed cpu -> the index of its entry in `siblings_of`, so we
    # can recover its hardware sibling list after sorting. We match by value.
    # (allowed[i] <-> siblings_of[i] in the INPUT ordering.)

    # 2. Build a fast membership check for "is cpu allowed".
    #    Linear over a small set (cores are O(100) at most) -- simple + safe.

    # 3. Walk allowed cpus ascending. For each, compute its canonical core id =
    #    the lowest allowed cpu among its hardware siblings (including itself).
    #    Group cpus by canonical core id, preserving ascending order within a
    #    group.
    var core_ids = List[Int]()          # canonical id per core (first-seen)
    var core_members = List[List[Int]]()  # allowed members per core, ascending

    for ci in range(n):
        var cpu = sorted_allowed[ci]
        var sibs = _siblings_for(cpu, allowed, siblings_of)
        var canon = _lowest_allowed_sibling(cpu, sibs, sorted_allowed)
        # Find (or create) this core's bucket.
        var slot = -1
        for k in range(len(core_ids)):
            if core_ids[k] == canon:
                slot = k
                break
        if slot < 0:
            core_ids.append(canon)
            var fresh = List[Int]()
            fresh.append(cpu)
            core_members.append(fresh^)
        else:
            core_members[slot].append(cpu)

    # 4. For each core: lowest allowed member -> compute lane; next allowed
    #    member (if any) -> IO lane.
    var compute = List[Int]()
    var io = List[Int]()
    for k in range(len(core_members)):
        # members are appended in ascending cpu order already (we walk
        # sorted_allowed ascending), but sort defensively. Pass by ref into
        # `_sorted_unique` (read-borrow) -- no implicit copy of the inner list.
        var sm = _sorted_unique(core_members[k])
        if len(sm) >= 1:
            compute.append(sm[0])
        if len(sm) >= 2:
            io.append(sm[1])

    var compute_sorted = _sorted_unique(compute)
    var io_sorted = _sorted_unique(io)
    return CpuTopology(sorted_allowed^, compute_sorted^, io_sorted^)


# =============================================================================
# Driver/main-thread CPU reservation (PURE; unit-testable)
# =============================================================================
#
# THE PROBLEM
# -----------
# In a fork-join engine the pinned compute workers are PARKED while the ONE
# driver thread runs the serial parts of a query, so the driver is the
# critical path. With workers pinned one-per-physical-core and the driver
# pinned to NOTHING, CFS puts the driver wherever it likes, INCLUDING on top
# of a pinned worker's core: the thread on the critical path is the only one
# with no placement guarantee, and it periodically preempts a worker that is
# about to be woken.
#
# THE RULE (topology-derived, in strict preference order)
# -------------------------------------------------------
# CASE 1 — a FREE logical CPU exists (`allowed \ compute` non-empty).
#   Reserve the LOWEST-numbered allowed CPU that is NOT in the compute lane.
#   COST: ZERO compute capacity. The compute lane is unchanged, worker count
#   is unchanged.
#   WHY the lowest: by `derive_pools`' construction the compute lane takes the
#   LOWEST allowed sibling of each physical core, so the lowest non-compute
#   allowed CPU is the SIBLING of the lowest-numbered core that has one. Three
#   things follow, all of which we want:
#     (a) It is an SMT sibling, so it costs no physical core.
#     (b) On x86 hybrid parts the low-numbered logical CPUs are the P-cores,
#         and the lowest P-cores are the favored / Turbo-Boost-Max-preferred
#         cores. A single-threaded critical path (which is exactly what the
#         driver is) belongs on the fastest core in the machine.
#     (c) The physical core it shares hosts compute worker 0 — and the
#         driver-serial phase is PRECISELY when the workers are parked. The
#         two phases are anti-correlated by construction, so the driver gets
#         that core's full ALU issue width while it runs, and yields it back
#         at the barrier.
#   Example (P-cores with HT, E-cores without): compute = [0,2,...,14, 16..27],
#   siblings = [1,3,...,15] -> driver = cpu 1.
#
# CASE 2 — NO free logical CPU (ARM / no-HT / HT-disabled x86, or a cpuset in
#   which every allowed CPU is already a compute lane).
#   Reserve a WHOLE PHYSICAL CORE: drop the HIGHEST-numbered compute CPU out of
#   the compute lane and give it to the driver.
#   COST — STATE IT PLAINLY: the compute pool shrinks to N-1. On ARM there are
#   no hyperthread siblings, so a driver reservation is NOT free: you buy the
#   driver a private core by giving up one worker. Whether that trade wins is
#   an empirical question per machine, which is exactly why the reservation
#   is off in the default `EnginePlacement`.
#   WHY the highest: `derive_pools` emits the compute lane ascending, and the
#   engine's fork-join driver hands out shards in worker-index order, so the
#   highest-index worker is the last to be handed work — dropping it perturbs
#   the least. It also keeps `compute_cpus()[k]` stable for every surviving k.
#
# CASE 3 — the reservation would leave too few workers.
#   `_MIN_COMPUTE_AFTER_DRIVER_RESERVE` (= 2) floors CASE 2: on a 1- or 2-CPU
#   cpuset (or a 2-core no-HT box) we do NOT steal a core — halving or zeroing
#   the compute pool to buy a driver core is never the right trade. The result
#   is `driver_cpu() == -1` and an unchanged topology; the driver simply runs
#   unpinned. CASE 1 has no such floor because it costs no capacity.
#
# THE IO LANE AND THE RESERVED CPU
# --------------------------------
# `_io` is left COMPLETELY UNTOUCHED by this function. In CASE 1 that means the
# reserved CPU normally REMAINS in `io_cpus()` — deliberately: IO-bound work
# belongs on the main thread's CPU rather than preempting a pinned compute
# core. Blocking/syscall-heavy work and a mostly-stalled driver share a core
# well; that is the same HT-physics argument that created the IO lane in the
# first place. In CASE 2 there is no IO lane to speak of (`allowed == compute`
# implies `_io` is empty), so nothing changes there either. The ONE lane the
# driver CPU is guaranteed disjoint from is COMPUTE.
# =============================================================================

# CASE 3 floor: never steal a physical core (CASE 2) if doing so would leave
# fewer than this many compute workers.
comptime _MIN_COMPUTE_AFTER_DRIVER_RESERVE: Int = 2


def derive_driver_reservation(var topo: CpuTopology) -> CpuTopology:
    """Apply the driver/main-thread CPU reservation to `topo`.

    PURE — no syscalls, no sysfs, fully unit-testable from a fields-ctor
    `CpuTopology`. The three cases + their justification are documented in the
    block comment above this function.

    Args:
        topo: The probed (or synthetic) topology to apply the policy to.

    Returns:
        A `CpuTopology` whose `driver_cpu()` is the reserved CPU (or -1 when no
        reservation is possible/worthwhile). The compute lane is unchanged in
        CASE 1 and shortened by one in CASE 2. `io_cpus()` and `allowed_cpus()`
        are NEVER modified.

    Post-conditions:
        * `driver_cpu() == -1` OR `driver_cpu()` ∈ `allowed_cpus()`.
        * `driver_cpu()` ∉ `compute_cpus()`  (the DISJOINTNESS guarantee).
        * `len(compute_cpus()) >= 1` always.
        * Idempotent: applying it twice is the same as applying it once.
    """
    # Idempotence: a topology that already carries a reservation is returned
    # verbatim (re-running CASE 2 would steal a second core).
    if topo._driver >= 0:
        return topo^

    # --- CASE 1: a free (non-compute) allowed CPU exists -> zero-cost. -------
    # `_allowed` is sorted ascending by `derive_pools` / `_sorted_unique`, so
    # the first non-compute hit IS the lowest-numbered candidate.
    for i in range(len(topo._allowed)):
        var cpu = topo._allowed[i]
        if not _contains(topo._compute, cpu):
            return CpuTopology(
                topo._allowed.copy(),
                topo._compute.copy(),
                topo._io.copy(),
                cpu,
                topo._io_mode,
            )

    # --- CASE 3 floor: refuse to shrink the compute pool below the floor. ----
    if len(topo._compute) - 1 < _MIN_COMPUTE_AFTER_DRIVER_RESERVE:
        return topo^

    # --- CASE 2: no free CPU -> buy a whole physical core, workers N-1. ------
    var n = len(topo._compute)
    var driver = topo._compute[n - 1]
    var new_compute = List[Int]()
    for i in range(n - 1):
        new_compute.append(topo._compute[i])
    return CpuTopology(
        topo._allowed.copy(),
        new_compute^,
        topo._io.copy(),
        driver,
        topo._io_mode,
    )


# =============================================================================
# The IO-LANE PLACEMENT RULE (PURE; unit-testable)
# =============================================================================
#
# With HT available, the primary sibling of each core should be maxed out with
# compute and the HT pair used for work known to block. On ARM (no SMT) the
# choice is more nuanced: time-slice IO with the driver, or keep IO on a
# separate core. This function is ONE rule that produces a sensible IO
# placement on every machine shape (x86 hybrid w/ HT, HT-disabled x86, ARM /
# Apple silicon, a 4-CPU cpuset, a 1-CPU container).
#
# THE FOUR MODES
# --------------
#   SIBLING           IO threads on the HT siblings (one per core that has one).
#                     Compute lane UNCHANGED. Cost ~= zero.
#   DEDICATED         No siblings, but enough cores that buying the IO lane a
#                     WHOLE physical core is cheap. Compute lane shrinks to P-1.
#   DRIVER_CORESIDENT No siblings, too few cores to give one up -> ONE IO thread
#                     co-resident on the driver's already-reserved CPU.
#   INLINE            No IO lane at all. Blocking IO runs inline on the thread
#                     that submits it (the behaviour without an IO lane).
#
# ── RULE 1: HT AVAILABLE -> SIBLING (and WHY it is nearly free) ──────────────
#
# A thread that is BLOCKED in a syscall (`epoll_wait`, `read`, `fsync`, a futex
# wait) is HALTED: it holds no reservation station, issues no uops, and retires
# nothing. On SMT x86 parts, when one logical thread of a core is halted the
# core's front-end + back-end revert to single-thread mode and the RUNNING
# sibling gets the FULL issue width, the full ROB, the full store buffer —
# i.e. the partitioned-resource penalty of SMT disappears while the partner is
# blocked. So an IO thread that spends its life blocked costs its compute
# partner essentially nothing but the syscall entry/exit and the completion
# handling either side of the block.
#
# THE CONTRACT THAT MAKES THAT TRUE — and it is a REAL constraint, not a
#   footnote. The argument above holds ONLY for genuinely BLOCKING work. A
#   thread that POLLS (a reactor spin loop, a `sched_yield` retry loop, a
#   busy-wait on a Pending future) is RUNNING, and a running SMT sibling DOES
#   take issue slots from its compute partner — on an ALU-saturated kernel that
#   is a direct throughput loss, not a free ride. So: the IO lane admits
#   BLOCKING work (read/pread/fsync/page-fault-prefault/connect) and MUST NOT
#   admit POLLING work. An object-store client that spins on `Pending` is NOT
#   an IO-lane candidate as written.
#
# ── RULE 2: NO SIBLING -> the real choice, and the THRESHOLD ─────────────────
#
# With no HT sibling there is no free CPU, so the lane must be paid for. Three
# options and their costs, all expressed against the PARALLEL region's wall:
#
#   (i)  INLINE (no lane). The blocking op runs on the compute worker that
#        submitted it. Under a FORK-JOIN barrier this is the expensive option
#        and the reason a lane is worth anything at all: a barrier's wall is the
#        MAX shard, so blocking on ONE worker stalls ALL P workers for the
#        blocked duration. Inline blocking of fraction `f` of a shard's work
#        costs ~`f` of the whole parallel region, not `f/P` of it.
#   (ii) DEDICATED core. Compute drops P -> P-1, so the parallel region
#        stretches by `P/(P-1)`, i.e. a cost of `1/(P-1)`.
#   (iii)DRIVER_CORESIDENT. Costs the DRIVER cycles. The driver's serial
#        windows are mostly on-CPU — the driver is NOT a low-duty-cycle thread
#        while it is on the critical path, and it IS the critical path. So
#        co-residency with the driver is NOT free either; it is merely the
#        least-bad option when we refuse to give up a core.
#
# THE THRESHOLD, DERIVED (the answer to "based on the number of cores"):
#
#        DEDICATE  iff  1/(P-1)  <  f        <=>       P  >  1 + 1/f
#
# where `f` is the fraction of a compute shard's wall spent blocked on IO. The
# threshold is therefore NOT a bare core count — it is a core count GIVEN an
# assumed blocking load, and that is exactly why a hardcoded magic number would
# be wrong. We must still choose an `f` to get a runnable constant, so we choose
# it EXPLICITLY and name it:
#
#   f = 1/16 (`_IO_ASSUMED_BLOCKING_FRACTION_INV`) — 6.25% of a shard's wall
#   blocked. That is roughly a cold-page-cache local scan (a real but
#   unexceptional blocking load), and it is deliberately CONSERVATIVE: a warm
#   local Parquet scan runs at f ~= 0 (the local read path is mmap page-faults
#   into RESIDENT pages, not syscalls), so assuming a large `f` would steal
#   cores for blocking that does not exist. A small `f` makes the rule REFUSE
#   to steal unless the machine is big enough that the steal is noise.
#
#        =>  DEDICATE when  1/(P-1) <= f,  i.e.  P >= 1 + 1/f = 17 cores.
#
# THE BOUNDARY (P == 17, where 1/(P-1) == f exactly) BREAKS TOWARD DEDICATE, on
# purpose: the `1/(P-1)` vs `f` comparison UNDERSTATES the inline cost, because
# it prices inline blocking at `f` of the parallel region while the fork-join
# barrier actually amplifies a single blocked shard toward the barrier's whole
# window. A tie in a model that is biased against the lane should be resolved in
# the lane's favour.
#
# Sanity check ("1/8 of an 8-core machine is a lot; 1/64 of a 64-core one is
# not"):
#     P=8   -> 1/(P-1) = 14.3%  >> 6.25%  -> DO NOT steal.
#     P=16  -> 1/15    =  6.7%   > 6.25%  -> DO NOT steal.
#     P=17  -> 1/16    =  6.25% == 6.25%  -> steal (the tie, see above).
#     P=64  -> 1/63    =  1.6%   < 6.25%  -> steal.
#
# WHY ONLY ONE dedicated core / one co-resident thread: each additional IO
# thread on a no-HT box costs another `1/(P-1)` (DEDICATED) or another slice of
# the critical-path driver (CORESIDENT), while the SECOND concurrent blocking op
# is worth much less than the first (the first one already removed the barrier
# stall). So the no-HT lane is size 1 by construction. The SIBLING lane is
# free, so it takes every sibling it is given.
#
# ── ORDERING, AND WHY DEDICATED IS TRIED BEFORE CORESIDENT ──────────────────
# On a big no-HT box a private core is strictly better than time-slicing the
# single-threaded critical path. On a small box we refuse to steal, and then
# co-residency with the driver is preferred over INLINE because the driver's
# CPU is the only CPU in the machine that is NOT a pinned compute core — putting
# IO anywhere else would preempt a compute worker, which is the exact failure
# INLINE already has, plus a context switch.
#
# ── THE DEGENERATE SHAPES (all handled, no special cases) ───────────────────
#   * HT-DISABLED x86 / ARM / Apple silicon: `io_cpus()` is empty -> RULE 2.
#   * cpuset that exposes only primary siblings: same, and `P` is the CPUSET's
#     core count, not the host's (everything here is derived from `_allowed`).
#   * cpuset WITH both siblings of 2 cores (a 4-CPU pin): siblings non-empty ->
#     SIBLING with a 2-thread IO lane. Correct with no carve-out.
#   * 4-core no-HT: P=4 < 17 -> CORESIDENT if a driver CPU is reserved, else
#     INLINE.
#   * 1-2 CPU container: the `_MIN_COMPUTE_AFTER_IO_DEDICATE` floor blocks the
#     steal and there is no free CPU -> INLINE.
#   * NO driver reservation (the default `EnginePlacement`): CORESIDENT is
#     unavailable (there is no non-compute CPU to be co-resident ON), so a
#     small no-HT box lands on INLINE. That is the honest answer: on that
#     shape the IO lane cannot be paid for.
# =============================================================================

# IO-lane placement modes. `UNSET` is what the raw probe (`derive_pools` /
# `detect()`) carries — the placement is a POLICY applied on top, never part of
# the probe (same separation as `_driver == -1`).
comptime IO_PLACEMENT_UNSET: UInt8 = UInt8(0)
comptime IO_PLACEMENT_INLINE: UInt8 = UInt8(1)
comptime IO_PLACEMENT_SIBLING: UInt8 = UInt8(2)
comptime IO_PLACEMENT_DEDICATED: UInt8 = UInt8(3)
comptime IO_PLACEMENT_DRIVER_CORESIDENT: UInt8 = UInt8(4)

# The assumed per-shard blocking fraction `f`, as its reciprocal, from which the
# DEDICATED threshold is derived (see the block comment above). f = 1/16.
comptime _IO_ASSUMED_BLOCKING_FRACTION_INV: Int = 16

# DEDICATE iff 1/(P-1) <= f, i.e. P >= 1 + 1/f. Derived, not hardcoded: change
# the assumed blocking fraction above and the threshold moves with it. The `<=`
# (tie -> dedicate) is justified in the block comment above.
comptime _IO_DEDICATE_MIN_COMPUTE: Int = 1 + _IO_ASSUMED_BLOCKING_FRACTION_INV

# Floor mirroring `_MIN_COMPUTE_AFTER_DRIVER_RESERVE`: never let the IO steal
# drop the compute pool below this. (Subsumed by the threshold above on any
# realistic host; kept as an independent guard so the two policies cannot
# compose into a pathological pool size.)
comptime _MIN_COMPUTE_AFTER_IO_DEDICATE: Int = 2


def derive_io_placement(var topo: CpuTopology) -> CpuTopology:
    """Apply the IO-lane placement rule to `topo`.

    PURE — no syscalls, no sysfs, fully unit-testable from a fields-ctor
    `CpuTopology`. The rule, its threshold, and the threshold's derivation are
    documented in the block comment above this function.

    Args:
        topo: The probed (or synthetic) topology, with any driver reservation
            already applied (`derive_driver_reservation` runs FIRST — the
            CORESIDENT arm needs to see `driver_cpu()`).

    Returns:
        A `CpuTopology` whose `io_cpus()` is the PLACED IO lane and whose
        `io_placement_mode()` names which arm fired. `compute_cpus()` is
        unchanged except in the DEDICATED arm, where it is one shorter.
        `allowed_cpus()` is never modified.

    Post-conditions:
        * `io_placement_mode() != IO_PLACEMENT_UNSET`.
        * `set(io_cpus()) ∩ set(compute_cpus()) == ∅` — the IO lane NEVER
          overlaps a pinned compute worker, in any mode. This is the one
          invariant the whole lane rests on.
        * `set(io_cpus()) ⊆ set(allowed_cpus())`.
        * `len(compute_cpus()) >= 1`.
        * INLINE <=> `len(io_cpus()) == 0`.
        * Idempotent: applying it twice equals applying it once.
    """
    # Idempotence: a topology that already carries a placement is returned
    # verbatim (re-running the DEDICATED arm would steal a second core).
    if topo._io_mode != IO_PLACEMENT_UNSET:
        return topo^

    # --- RULE 1: HT siblings exist -> SIBLING (zero-cost). -------------------
    # `derive_pools` guarantees `_io ∩ _compute == ∅`, so the disjointness
    # post-condition holds for free here.
    if len(topo._io) > 0:
        return CpuTopology(
            topo._allowed.copy(),
            topo._compute.copy(),
            topo._io.copy(),
            topo._driver,
            IO_PLACEMENT_SIBLING,
        )

    # --- RULE 2a: no sibling, but the machine is big -> DEDICATED. -----------
    var n_compute = len(topo._compute)
    if (
        n_compute >= _IO_DEDICATE_MIN_COMPUTE
        and n_compute - 1 >= _MIN_COMPUTE_AFTER_IO_DEDICATE
    ):
        # Steal the HIGHEST-numbered compute CPU, for the same reason
        # `derive_driver_reservation` CASE 2 does: the fork-join driver hands
        # shards out in worker-index order, so the highest index is the last to
        # be fed and perturbs the least, AND `compute_cpus()[k]` stays stable
        # for every surviving k.
        var stolen = topo._compute[n_compute - 1]
        var new_compute = List[Int]()
        for i in range(n_compute - 1):
            new_compute.append(topo._compute[i])
        var new_io = List[Int]()
        new_io.append(stolen)
        return CpuTopology(
            topo._allowed.copy(),
            new_compute^,
            new_io^,
            topo._driver,
            IO_PLACEMENT_DEDICATED,
        )

    # --- RULE 2b: small no-HT box with a reserved driver CPU -> CORESIDENT. --
    # `derive_driver_reservation` guarantees `_driver ∉ _compute`, so the
    # disjointness post-condition holds. ONE IO thread only.
    if topo._driver >= 0:
        var co_io = List[Int]()
        co_io.append(topo._driver)
        return CpuTopology(
            topo._allowed.copy(),
            topo._compute.copy(),
            co_io^,
            topo._driver,
            IO_PLACEMENT_DRIVER_CORESIDENT,
        )

    # --- RULE 2c: nothing to pay with -> INLINE. ------------------------------
    return CpuTopology(
        topo._allowed.copy(),
        topo._compute.copy(),
        List[Int](),
        topo._driver,
        IO_PLACEMENT_INLINE,
    )


# =============================================================================
# NUMA-NODE LOCALITY (PURE; unit-testable)
# =============================================================================
#
# Off in the default `EnginePlacement`, and deliberately so. Confining the
# whole engine to one NUMA node removes nearly all remote-node DRAM loads, but
# on a two-socket host it is a net LOSS for most analytical queries, and the
# loss has two real halves:
#
#   * the core count: one socket has half the physical cores;
#   * the placement itself: the scattered layout harvests BOTH sockets' L3
#     and DRAM bandwidth. For a hash aggregation, remote LATENCY on many loads
#     is cheaper than losing half the cache and bandwidth CAPACITY, so the
#     memory-bound aggregations lose hardest.
#
# Latency-bound queries that do not scale past one socket's cores (a
# high-cardinality join probe, for example) are the case where the placement
# can pay. Sharding the engine ACROSS nodes (a sub-pool per socket with
# node-local build tables and a node-affine morsel queue) keeps all the cores,
# all the L3 and all the bandwidth AND gets locality; that is a subsystem, not
# a placement policy, and it is not implemented here.
#
# The policy is kept so a multi-socket host can A/B it: `numa_local` isolates
# the placement term, and an explicit worker count isolates the core-count
# term. On a single-socket host it is an identity no-op (below).
#
# WHY THIS IS A *CONFINEMENT*, NOT A PIN
# --------------------------------------
# `pin_workers` pins worker k to ONE logical CPU. `numactl --cpunodebind` does
# something strictly weaker: it hands every thread the SAME multi-CPU mask
# (one node's CPUs) and lets CFS balance freely INSIDE it. That is what this
# policy reproduces, and it is why `numa_local` is INDEPENDENT of
# `pin_workers` rather than an extension of it. The two compose (a pin under
# an active restriction pins into the chosen node, because the compute lane
# has already been filtered), but neither requires the other.
#
# What predicts the cost of a placement is how much of the machine the
# resident worker set covers: half the cores is half the L3 and half the DRAM
# bandwidth. A 1:1 pin covering ALL cores gives up neither and is neutral; a
# pin NARROWER than the machine costs, and its width is whatever
# `engine_worker_count()` returns. A thread-placement result is therefore
# scoped to the WORKER COUNT it was measured at.
#
# WHY NO `libnuma` / `mbind` — FIRST-TOUCH DOES THE MEMORY HALF
# ------------------------------------------------------------
# `--membind=0` is the memory half of the bracket, but Linux's DEFAULT policy is
# already first-touch-local: a page is placed on the node of the CPU that first
# WRITES it. Once every engine thread (the workers AND the driver) is confined
# to one node's CPUs, every first touch happens on that node — so the allocation
# follows the threads with no `set_mempolicy`, no `mbind`, and no new library
# dependency. `--membind` differs only under node-local memory PRESSURE, where
# it fails/OOMs rather than spilling to the far node; for a query engine that is
# a worse failure mode, not a better one.
#
# THE NO-OP CONTRACT (the part that matters on every OTHER machine)
# -----------------------------------------------------------------
# On a machine whose compute lane spans <= 1 NUMA node — every laptop, every
# single-socket server, every container already pinned to one node, and every
# host where `/sys/devices/system/node` is unreadable or absent —
# `derive_numa_locality` returns its input BY IDENTITY (`return topo^`). Not "an
# equivalent topology": the SAME allowed / compute / io lanes, the same driver,
# the same io_mode, no list rebuilt. That is the only shape in which "safe on
# single-socket" is a property of the CODE rather than of a measurement, and it
# is what the single-node identity test asserts field-by-field.
#
# THE CHOICE RULE
# ---------------
# Pick the node holding the MOST compute-lane CPUs; ties break to the LOWEST
# node ordinal. Most-CPUs (rather than "always node 0") is what stops a cpuset
# that straddles nodes UNEVENLY from collapsing onto the smaller half — a
# 40-CPU/4-CPU straddle would otherwise lose 90% of the pool. The tie-break is
# lowest-ordinal for determinism, and because a process's early allocations
# already live near node 0.
#
# "Confine to one node but keep every worker" is not a configuration: one
# socket's other CPUs are SMT siblings of its physical cores, and two compute
# workers on one core thrash the shared ALUs (the premise the whole
# compute/IO split in this file is built on).
# =============================================================================


def numa_nodes_spanned(cpus: List[Int], node_cpulists: List[List[Int]]) -> Int:
    """How many distinct NUMA nodes `cpus` is spread across.

    PURE — no syscalls, no sysfs.

    Args:
        cpus: Logical-CPU indices (typically a topology's compute lane).
        node_cpulists: `node_cpulists[i]` is the CPU list of the i-th ONLINE
            NUMA node, in ascending node-id order. `i` is the node's ORDINAL,
            not necessarily its kernel id (a host with node0+node2 online yields
            ordinals 0 and 1) — `_read_numa_node_ids` carries the kernel ids.

    Returns:
        The number of distinct ordinals holding at least one member of `cpus`.
        ZERO when nothing maps, which every caller must read as "no NUMA
        information available" — i.e. the no-op path.
    """
    # A CPU present in NO node list is IGNORED rather than counted as a node of
    # its own: an unmappable CPU means missing topology data, and inventing a
    # node for it would manufacture a multi-node verdict on a host with none.
    var n = 0
    for i in range(len(node_cpulists)):
        var hit = False
        for k in range(len(cpus)):
            if _contains(node_cpulists[i], cpus[k]):
                hit = True
                break
        if hit:
            n += 1
    return n


def numa_preferred_node(cpus: List[Int], node_cpulists: List[List[Int]]) -> Int:
    """The ORDINAL of the node holding the most of `cpus`; ties -> lowest.

    PURE. Returns -1 when no member of `cpus` maps to any node (the same "no
    NUMA information" signal as `numa_nodes_spanned() == 0`).
    """
    var best = -1
    var best_count = 0
    for i in range(len(node_cpulists)):
        var c = 0
        for k in range(len(cpus)):
            if _contains(node_cpulists[i], cpus[k]):
                c += 1
        # Strict `>` is the lowest-ordinal tie-break.
        if c > best_count:
            best_count = c
            best = i
    return best


# =============================================================================
# WHERE DOES A 1:1 PIN ACTUALLY LAND? — the pin-placement diagnostic (PURE)
# =============================================================================
#
# `pin_workers` pins compute worker k to `engine_compute_cpus(p)[k]`. That lane
# is ONE CPU PER PHYSICAL CORE in ascending core order, so on a two-socket host
# (for example node0 = `0-21,44-65`, node1 = `22-43,66-87`) it is
# `[0, 1, ..., 43]` — a list that STRADDLES both sockets.
#
# BUT WHICH SOCKETS A PIN OCCUPIES IS A FUNCTION OF THE **WORKER COUNT**, NOT
# OF THE LANE. A pin of `nw` workers occupies only the lane's FIRST `nw`
# entries:
#
#     nw = 44  ->  cpus 0..43   ->  BOTH nodes (22 on node0, 22 on node1)
#     nw = 20  ->  cpus 0..19   ->  node0 ONLY (20 on node0, 0 on node1)
#
# `engine_numa_spanned_nodes()` reports the span of the DETECTED COMPUTE LANE
# (constant in the worker count), not the span of the PINNED PREFIX. These
# three pure functions answer "given this lane and this worker count, where do
# the pinned workers actually sit", host-independently and with no syscalls,
# so a harness can print it per arm instead of reconstructing it afterwards
# from `/proc/<pid>/task/*/status`.
#
# THESE DESCRIBE A PIN, NOT THE DEFAULT. Without `pin_workers` no worker is
# pinned at all and CFS may run any worker anywhere; the histogram then
# describes the placement the pin WOULD produce, which is exactly what an A/B
# needs to state about its treatment arm.
# =============================================================================


def pinned_lane_prefix(compute_cpus: List[Int], num_workers: Int) -> List[Int]:
    """The CPUs a 1:1 pin of `num_workers` workers actually occupies.

    PURE. Mirrors `_worker_pthread_entry`'s pin rule exactly: worker k takes
    `compute_cpus[k]`, and a worker whose index is past the end of the lane is
    left UNPINNED (the `lane_index < len(cpus)` guard there), so the prefix is
    capped at the lane length rather than wrapping or extending.

    Args:
        compute_cpus: The compute lane, `engine_compute_cpus()`-shaped.
        num_workers: The pool's compute-worker count.

    Returns:
        `compute_cpus[0 : min(num_workers, len(compute_cpus))]`, order
        preserved. EMPTY when `num_workers <= 0` or the lane is empty.
    """
    var out = List[Int]()
    if num_workers <= 0:
        return out^
    var n = num_workers
    if n > len(compute_cpus):
        n = len(compute_cpus)
    for i in range(n):
        out.append(compute_cpus[i])
    return out^


def numa_nodes_spanned_by_pin(
    compute_cpus: List[Int],
    num_workers: Int,
    node_cpulists: List[List[Int]],
) -> Int:
    """How many NUMA nodes a 1:1 pin of `num_workers` workers actually spans.

    PURE. This is the number the pin A/B needs and `engine_numa_spanned_nodes()`
    does NOT give: the latter spans the whole DETECTED lane and is therefore
    constant in `num_workers`, while this one is 1 at `nw=20` and 2 at `nw=44`
    on the same host. Returns 0 on the same "no NUMA information" signal as
    `numa_nodes_spanned`.
    """
    return numa_nodes_spanned(
        pinned_lane_prefix(compute_cpus, num_workers), node_cpulists
    )


def numa_pin_node_histogram(
    compute_cpus: List[Int],
    num_workers: Int,
    node_cpulists: List[List[Int]],
) -> List[Int]:
    """Workers-per-NUMA-node for a 1:1 pin of `num_workers` workers.

    PURE. `out[i]` is how many pinned workers land on node ORDINAL `i` (same
    ordinal convention as `numa_nodes_spanned`). Length is always
    `len(node_cpulists)`, so an all-zero entry is a node the pin does not touch
    and is reported rather than omitted.

    A pinned worker whose CPU maps to NO node is counted in no bucket — the sum
    of the histogram is therefore `<= len(pinned_lane_prefix(...))`, and the
    shortfall is exactly the unmappable-CPU case `numa_nodes_spanned` ignores
    for the same reason.

    On a two-socket host with 22 cores per socket this is `[20, 0]` at
    `nw=20` and `[22, 22]` at `nw=44` — the two readings the block comment
    above exists to keep apart.
    """
    var out = List[Int]()
    for _ in range(len(node_cpulists)):
        out.append(0)
    var pinned = pinned_lane_prefix(compute_cpus, num_workers)
    for k in range(len(pinned)):
        for i in range(len(node_cpulists)):
            if _contains(node_cpulists[i], pinned[k]):
                out[i] += 1
                break
    return out^


def derive_numa_locality(
    var topo: CpuTopology, node_cpulists: List[List[Int]]
) -> CpuTopology:
    """Apply the NUMA-node restriction to `topo`.

    PURE — no syscalls, no sysfs, fully unit-testable from a fields-ctor
    `CpuTopology` plus synthetic node lists. The rule and its justification are
    in the block comment above.

    Args:
        topo: The probed (or synthetic) topology. Run this BEFORE
            `derive_driver_reservation` / `derive_io_placement` — those two
            derive their picks from `_allowed` / `_compute`, and they must see
            the already-restricted lanes so every lane lands on ONE node.
        node_cpulists: Per-ONLINE-node CPU lists in ascending node-id order (see
            `numa_nodes_spanned`).

    Returns:
        On a host whose compute lane spans <= 1 node, or where no node
        information maps, or where the restriction would empty the compute lane:
        `topo` ITSELF, unmodified (the identity no-op).
        Otherwise a `CpuTopology` whose `allowed` / `compute` / `io` lanes are
        `topo`'s filtered down to the chosen node, ORDER PRESERVED, and whose
        `driver_cpu()` is kept only if it is on that node (else -1).

    Post-conditions when the restriction fires:
        * every CPU in allowed / compute / io belongs to ONE NUMA node.
        * `len(compute_cpus()) >= 1`.
        * compute ∩ io == ∅ and compute ∪ io ⊆ allowed are preserved (filtering
          by a common set cannot break either).
        * Idempotent: the result spans one node, so re-applying takes the
          identity arm.
    """
    var spanned = numa_nodes_spanned(topo._compute, node_cpulists)
    if spanned <= 1:
        # ⭐ THE NO-OP. Single-socket, single-node cpuset, or no sysfs NUMA
        # information at all. Returned by IDENTITY — nothing is rebuilt.
        return topo^

    var node = numa_preferred_node(topo._compute, node_cpulists)
    if node < 0 or node >= len(node_cpulists):
        return topo^  # cov: unreachable spanned >= 2 means some node holds a compute CPU, so the preferred ordinal is in range

    var members = node_cpulists[node].copy()
    var new_compute = _intersect_preserving_order(topo._compute, members)
    if len(new_compute) == 0:
        # Cannot happen given `spanned >= 2` (the preferred node holds at least
        # one compute CPU), but a zero-worker pool is catastrophic enough that
        # the guard is cheaper than the reasoning.
        return topo^  # cov: unreachable the preferred node holds at least one compute CPU when spanned >= 2

    var new_allowed = _intersect_preserving_order(topo._allowed, members)
    var new_io = _intersect_preserving_order(topo._io, members)
    var new_driver = -1
    if topo._driver >= 0 and _contains(members, topo._driver):
        new_driver = topo._driver
    return CpuTopology(
        new_allowed^, new_compute^, new_io^, new_driver, topo._io_mode
    )


# =============================================================================
# Pure helpers
# =============================================================================


def _intersect_preserving_order(xs: List[Int], ys: List[Int]) -> List[Int]:
    """`xs` filtered to the members it shares with `ys`, in `xs`'s ORDER.

    Order preservation is load-bearing: `derive_pools` emits `compute` and `io`
    in core order and the worker-pin site pairs `compute[k]` with `io[k]`
    positionally, so a set-shaped intersection that re-sorted would silently
    re-pair the lanes (the same reason `_TopologySnapshot` refuses a bitmask
    round-trip).
    """
    var out = List[Int]()
    for i in range(len(xs)):
        if _contains(ys, xs[i]):
            out.append(xs[i])
    return out^


def _sorted_unique(xs: List[Int]) -> List[Int]:
    """Return `xs` sorted ascending with duplicates removed. O(n^2) insertion
    sort -- n is the logical-CPU count (O(100) at most), so this is fine and
    avoids pulling in a generic sort dependency."""
    var out = List[Int]()
    for i in range(len(xs)):
        var v = xs[i]
        # Skip if already present.
        var dup = False
        for j in range(len(out)):
            if out[j] == v:
                dup = True
                break
        if dup:
            continue
        # Insert in sorted position.
        var pos = len(out)
        for j in range(len(out)):
            if out[j] > v:
                pos = j
                break
        out.insert(pos, v)
    return out^


def _siblings_for(
    cpu: Int, allowed: List[Int], siblings_of: List[List[Int]]
) -> List[Int]:
    """Look up `cpu`'s hardware sibling list from the parallel
    (allowed, siblings_of) input arrays. Returns `[cpu]` if not found."""
    for i in range(len(allowed)):
        if allowed[i] == cpu:
            return siblings_of[i].copy()
    var lone = List[Int]()
    lone.append(cpu)
    return lone^


def _lowest_allowed_sibling(
    cpu: Int, sibs: List[Int], sorted_allowed: List[Int]
) -> Int:
    """The canonical core id for `cpu`: the lowest-numbered sibling that is
    also in the allowed set. Falls back to `cpu` itself if no sibling is
    allowed (always at least `cpu`, since `cpu` is allowed)."""
    var best = cpu
    for i in range(len(sibs)):
        var s = sibs[i]
        if s < best and _contains(sorted_allowed, s):
            best = s
    return best


def _contains(xs: List[Int], v: Int) -> Bool:
    for i in range(len(xs)):
        if xs[i] == v:
            return True
    return False


def _cap_compute(var topo: CpuTopology, max_compute: Int) -> CpuTopology:
    """Cap the compute pool to `max_compute` cores (cgroup quota tighter than
    the cpuset). Drops the highest-numbered cores' compute+IO lanes so the
    surviving lanes stay a valid compute/IO pairing.

    `max_compute` is assumed `>= 1` and `< len(compute)` by the caller."""
    var keep = max_compute
    if keep < 1:
        keep = 1
    var new_compute = List[Int]()
    var new_io = List[Int]()
    for i in range(len(topo._compute)):
        if i < keep:
            new_compute.append(topo._compute[i])
    for i in range(len(topo._io)):
        if i < keep:
            new_io.append(topo._io[i])
    return CpuTopology(
        topo._allowed.copy(),
        new_compute^,
        new_io^,
        topo._driver,
        topo._io_mode,
    )


# =============================================================================
# Engine worker-pool sizing helper -- the cgroup/cpuset-aware count
# =============================================================================


def engine_worker_count(placement: EnginePlacement) -> Int:
    """The cgroup/cpuset-aware worker count for the engine parallel pool.

    Sources the count from `engine_topology(placement).physical_core_count()`
    -- which respects a cpuset / container pin via `sched_getaffinity` --
    instead of the raw host `num_physical_cores()`, which a NUMA-pinned
    container over-reports (over-threading its cgroup).

    SAFE FALLBACK / NO-OP ON BARE METAL:
      * `CpuTopology.detect()` NEVER raises and NEVER returns < 1: on any probe
        failure (non-Linux, hardened /sys, empty affinity mask) it falls back
        to `num_physical_cores()` as the compute lane. So with
        `EnginePlacement()` this function returns the SAME value as
        `max(num_physical_cores(), 1)` whenever the process is NOT inside a
        restrictive cpuset/cgroup.
      * On BARE METAL with no cpuset restriction, `sched_getaffinity` returns
        ALL host CPUs, so `physical_core_count()` == the host physical-core
        count == `num_physical_cores()`.

    COST: the topology probe is frozen once per process (see
    `CpuTopology.detect`); each call applies the placement policies to that
    snapshot. The engine calls this once per materialize DISPATCH, NOT per
    morsel/row.

    Driver reservation: when `placement.driver_reserved()` AND the host has no
    free SMT sibling to donate (the ARM / no-HT shape), the reservation buys
    the driver a whole physical core and this count drops by one. That is the
    stated cost of the policy; with the default placement and on any host with
    a free sibling the value is unchanged.

    Args:
        placement: The engine's placement policy (`EnginePlacement()` for the
            default: nothing pinned, reserved or restricted).

    Returns:
        The compute-lane parallelism: `max(physical_core_count(), 1)`, always
        `>= 1`.
    """
    var n = engine_topology(placement).physical_core_count()
    if n < 1:
        n = 1
    return n


# =============================================================================
# Compute / IO hyperthread split — engine worker-pool consumers
# =============================================================================
#
# These helpers are the module-boundary surface the engine's worker pools
# need. Every one takes the engine's `EnginePlacement` and derives from ONE
# `engine_topology(placement)` value, so worker sizing, worker placement, the
# driver CPU and the IO lane can never disagree with each other:
#
#   * `engine_compute_cpus(p)` / `engine_io_cpus(p)` — the per-lane
#     logical-CPU index lists, consumed at worker-thread start to pin worker N
#     to lane N when `p.pin_workers` is set.
#   * `engine_topology(p)` — detect() + every placement POLICY `p` enables.
#   * `engine_driver_cpu(p)` / `pin_driver_thread(p)` — the reserved driver
#     CPU and the driver-side pin (call AFTER the worker pthreads are spawned).
#
# CACHING: the allowed-CPU SET and the detected topology are snapshotted ONCE
# per process (`_Global`, plain-data storage; see `_read_allowed_cpus` and
# `CpuTopology.detect`). Re-probing per call would make the derived topology a
# function of WHICH THREAD ASKED. The placement POLICIES are applied per call
# from the snapshot, so `engine_topology()` remains the single choke point.
# =============================================================================


def engine_topology(placement: EnginePlacement) -> CpuTopology:
    """The engine's EFFECTIVE topology: the probed `CpuTopology.detect()` with
    every placement POLICY `placement` enables applied on top.

    Three policies, applied in this ORDER (the order is load-bearing):
      0. The NUMA-node restriction (`derive_numa_locality`), when
         `placement.numa_local`.
      1. The driver-CPU reservation (`derive_driver_reservation`), when
         `placement.driver_reserved()`.
      2. The IO-lane placement (`derive_io_placement`), when
         `placement.io_lane`.

    WHY THAT ORDER: the NUMA restriction SHRINKS `_allowed` / `_compute`, the
    driver reservation picks the driver CPU out of `_allowed`, and the IO
    placement may steal from `_compute` — so running the restriction anywhere
    but FIRST would let the driver or the IO lane land on the far socket.
    Then the IO placement's `DRIVER_CORESIDENT` arm needs to see
    `driver_cpu()`, so the reservation must already be applied; running 1 and
    2 the other way round would silently degrade every small no-HT host from
    CORESIDENT to INLINE.

    Keeping all three policies here — rather than inside `detect()` — is what
    makes the lanes consistent by construction: every engine-facing helper below
    reads THIS function, so the compute lane, the worker count, the driver CPU
    and the IO lane are always derived from ONE topology value under ONE
    placement.

    With `EnginePlacement()` this is exactly `CpuTopology.detect()`.
    """
    var topo = CpuTopology.detect()
    if placement.numa_local:
        topo = _frozen_numa_local_topology()
    if placement.driver_reserved():
        topo = derive_driver_reservation(topo^)
    if placement.io_lane:
        topo = derive_io_placement(topo^)
    return topo^


def engine_driver_cpu(placement: EnginePlacement) -> Int:
    """The logical CPU reserved for the driver / main thread, or -1 for none.

    -1 unless `placement.driver_reserved()`, and on any host where no
    reservation is possible or worthwhile (see `derive_driver_reservation`
    CASE 3). When `>= 0` it is guaranteed NOT to be in
    `engine_compute_cpus(placement)`; it MAY be in
    `engine_io_cpus(placement)` — that overlap is the point (the IO lane is
    welcome on the driver's CPU).
    """
    return engine_topology(placement).driver_cpu()


def pin_driver_thread(placement: EnginePlacement) -> Bool:
    """Pin the CALLING thread (the driver / main thread) to the reserved CPU.

    This is the driver-side counterpart of the worker-side pin. Call it from
    the thread that drives query execution, AFTER the worker pthreads have
    been spawned.

    ORDERING IS LOAD-BEARING — call this AFTER `pthread_create`, never before.
    A pthread INHERITS its creator's CPU affinity mask, so pinning the driver
    first would spawn every worker with a mask of {driver_cpu} and each worker
    would run on the driver's CPU until its own `pin_current_thread_to` lands
    (and would stay there forever with `pin_workers` off). Pinning after the
    spawn loop means workers inherit the unrestricted mask and then place
    themselves.

    Returns:
        True iff the thread was actually pinned. False on every no-op path:
        no driver reservation in `placement`, no reservation derivable (-1),
        non-Linux, or an EINVAL/EPERM from the kernel. False always means
        "ran unpinned".
    """
    if not placement.driver_reserved():
        return False
    var cpu = engine_driver_cpu(placement)
    if cpu < 0:
        return False
    return pin_current_thread_to(cpu)


def engine_compute_cpus(placement: EnginePlacement) -> List[Int]:
    """The compute-lane logical-CPU indices: one CPU per physical core.

    `engine_compute_cpus(p)[k]` is the CPU that compute worker `k` pins to
    when `p.pin_workers` is set. Length == `engine_worker_count(p)` (the
    compute pool size). Sourced from `engine_topology(p).compute_cpus()`, so
    it is cpuset/cgroup-aware and NEVER raises (falls back to
    `num_physical_cores()` on any probe failure).

    Under an active driver reservation on a no-HT host this list is one entry
    SHORTER (the highest-numbered core is handed to the driver). It stays in
    lockstep with `engine_worker_count(p)` because both read
    `engine_topology(p)`.
    """
    return engine_topology(placement).compute_cpus()


def engine_io_cpus(placement: EnginePlacement) -> List[Int]:
    """The IO-lane logical-CPU indices: the sibling hyperthread of each physical
    core that has one.

    `engine_io_cpus(p)[k]` is the CPU that IO worker `k` pins to when
    `p.pin_workers` is set. EMPTY when HT is disabled / non-SMT / only one
    sibling per core is allowed — in which case there is no IO lane and
    blocking IO runs inline on the compute worker. On a partial-HT host (for
    example P-cores with HT + E-cores without) this returns only the P-core
    siblings, so the IO lane is smaller than the compute lane and the E-core
    compute workers have no IO sibling.

    The driver reservation does NOT remove its CPU from this list. On the HT
    shape the reserved CPU is a sibling and therefore normally an IO CPU, and
    the IO lane keeps it deliberately: IO-bound work belongs on the driver's
    CPU rather than preempting a pinned compute core.

    When `p.io_lane` is set this is the PLACED lane, not the raw sibling list
    — `derive_io_placement` decides. On the HT shape they are the same value
    (the SIBLING arm); on a no-HT host the list is either ONE stolen core
    (DEDICATED, P >= 17), ONE co-resident driver CPU (DRIVER_CORESIDENT), or
    EMPTY (INLINE). Read `engine_io_placement_mode(p)` to know which. Without
    `io_lane` the placement policy does not run, so this returns the raw
    siblings.
    """
    return engine_topology(placement).io_cpus()


def engine_io_placement_mode(placement: EnginePlacement) -> UInt8:
    """Which IO placement the engine uses on THIS host under `placement`.

    `IO_PLACEMENT_UNSET` whenever `placement.io_lane` is off (the policy does
    not run). Otherwise one of SIBLING / DEDICATED / DRIVER_CORESIDENT /
    INLINE. Diagnostic + test surface; an EXPLAIN-style probe can report it so
    a deployment can see what the engine decided rather than guessing from
    core counts.
    """
    return engine_topology(placement).io_placement_mode()


# =============================================================================
# The engine-facing NUMA surface
# =============================================================================


def engine_numa_spanned_nodes() -> Int:
    """How many NUMA nodes the DETECTED compute lane spans on this host.

    THE NO-OP PREDICATE, and a diagnostic in its own right. `<= 1` means the
    NUMA restriction takes its identity arm whatever the placement says: a
    single-socket box, a container already confined to one node, or a host
    with no readable `/sys/devices/system/node` (which reports 0).

    Frozen per process alongside the restriction itself, so this is free to
    call and cannot disagree with `engine_numa_node_cpus()`. Reads the RAW
    detected topology, independent of any placement — that is what makes it
    usable as "would the NUMA restriction do anything here?".
    """
    return _frozen_numa_snapshot_spanned()


def engine_pinned_worker_node_histogram(num_workers: Int) -> List[Int]:
    """DIAGNOSTIC: workers-per-NUMA-node that `pin_workers` WOULD produce for
    a pool of `num_workers` compute workers on THIS host.

    **DIAGNOSTIC ONLY — NOT FOR THE DISPATCH PATH.** Unlike every other
    `engine_numa_*` helper this one is NOT served from the frozen snapshot: the
    per-node CPU membership is a `List[List[Int]]` and `_NumaLocalSnapshot` is
    deliberately plain data (Int / UInt8 / InlineArray only), so answering
    this re-walks `/sys/devices/system/node` — the per-call sysfs cost the
    frozen snapshot exists to keep off the per-query driver path. Call it
    ONCE, from a harness or a startup log line — never from
    `engine_worker_count()`'s neighbourhood.

    Reads the RAW detected compute lane, independent of any placement: with
    workers unpinned CFS may run any worker anywhere, and what this returns
    is the placement a pin WOULD impose — which is the thing an A/B has to be
    able to state about its treatment arm.

    Returns:
        `out[i]` = pinned workers landing on node ORDINAL `i`; length is the
        online-node count. EMPTY when no NUMA information is readable (the same
        signal as `engine_numa_spanned_nodes() == 0`), NOT a one-node answer.
    """
    var ids = _read_numa_node_ids()
    var lists = _read_numa_node_cpulists(ids)
    return numa_pin_node_histogram(
        CpuTopology.detect().compute_cpus(), num_workers, lists
    )


def engine_numa_node_id(placement: EnginePlacement) -> Int:
    """The kernel NUMA node id the engine confines its threads to, or -1.

    -1 on every no-op path: `placement.numa_local` off, single-node host, no
    NUMA information. When `>= 0`, `engine_numa_node_cpus(placement)` is that
    node's allowed CPU set and `engine_worker_count(placement)` /
    `engine_compute_cpus(placement)` have already been filtered to it (they
    read `engine_topology(placement)`, which applies the restriction first).
    """
    if not placement.numa_local:
        return -1
    return _frozen_numa_snapshot_node_id()


def engine_numa_node_cpus(placement: EnginePlacement) -> List[Int]:
    """The CPU set every engine thread confines itself to under the NUMA
    restriction.

    This is the `numactl --cpunodebind=<n>` equivalent: the chosen node's whole
    ALLOWED set (both SMT siblings of each core, not just the compute lane), so
    CFS keeps its freedom to balance INSIDE the node — the property that
    distinguishes this from a 1:1 worker pin.

    EMPTY on every no-op path (`numa_local` off, single-node host, no NUMA
    info). An empty list is the "do not touch this thread's affinity" signal
    that `confine_thread_to_engine_numa_node` reads, so the no-op needs no
    separate branch at any call site.
    """
    if engine_numa_node_id(placement) < 0:
        return List[Int]()
    return _frozen_numa_local_topology().allowed_cpus()


def confine_thread_to_engine_numa_node(placement: EnginePlacement) -> Bool:
    """Confine the CALLING thread to the NUMA restriction's node CPUs.

    Called for every engine worker at thread start AND for the driver after
    the pool is spawned. The driver is included because Linux places a page
    on the node of the CPU that FIRST WRITES it, and the driver first-touches
    a great deal of what the workers later read.

    Returns:
        True iff this thread's affinity mask was actually narrowed. False on
        every no-op path — `numa_local` off, single-node host, no NUMA info,
        non-Linux, or an EINVAL/EPERM from the kernel. False always means
        "ran unconfined".
    """
    var cpus = engine_numa_node_cpus(placement)
    if len(cpus) == 0:
        return False
    return confine_current_thread_to(cpus)


def prime_cpu_topology() -> Int:
    """Force the process-wide allowed-CPU snapshot to be taken NOW, and return
    its size.

    The snapshot is what makes every later topology query immune to a
    thread-level affinity pin (see `_read_allowed_cpus`). It is taken lazily on
    the first topology query, and `pin_current_thread_to` takes it before it
    narrows the calling thread — so on every in-tree path the snapshot is
    already correct by construction.

    This function exists for embedders that want the sample taken at an
    EXPLICIT, provably-unpinned point (e.g. the top of `main`, before any
    library that might call `sched_setaffinity` on the main thread runs).
    Calling it more than once is a no-op; calling it never is also fine.

    Returns:
        The number of logical CPUs in the process-wide allowed set, or 0 on a
        probe failure / non-Linux (in which case `detect()` uses the
        `num_physical_cores()` fallback).
    """
    return len(_read_allowed_cpus())


# =============================================================================
# Thread pinning helper
# =============================================================================


def pin_current_thread_to(cpu: Int) -> Bool:
    """Pin the CALLING thread to a single logical CPU via
    `sched_setaffinity(0, ...)`.

    Used by a worker thread to place itself on a specific compute / IO lane
    CPU (e.g. `topo.compute_cpus()[worker_id]`). Returns True on success,
    False on any failure (non-Linux, EINVAL, EPERM) -- callers treat a False
    as "ran unpinned", which is always safe.

    SAFETY:
      (a) `mask` is a heap-allocated 128-byte (`_CPU_SET_BYTES`) buffer,
          zeroed then with the single `cpu` bit set, freed before return. The
          pointer is valid for the whole syscall.
      (b) `cpu` out of [0, 1024) returns False without touching the kernel.
    """
    comptime if CompilationTarget.is_linux():
        if cpu < 0 or cpu >= _CPU_SET_MAX:
            return False
        # ORDERING INVARIANT:
        # snapshot the PROCESS-wide allowed set BEFORE narrowing this thread's
        # mask. `sched_getaffinity(0, ...)` reads the CALLING THREAD, so once
        # this call lands, every later probe FROM THIS THREAD would see a
        # one-CPU set. Priming here makes "resolve the topology before any
        # thread is pinned" a STRUCTURAL property of the module rather than a
        # call-order convention: you cannot pin through this API without the
        # snapshot already being taken.
        _ = _read_allowed_cpus()
        var mask = alloc[UInt8](_CPU_SET_BYTES)
        for i in range(_CPU_SET_BYTES):
            mask[i] = 0
        # Set bit `cpu`: byte = cpu // 8, bit = cpu % 8 (little-endian within
        # each unsigned long; byte-addressed this is just cpu//8, cpu%8).
        var byte_i = cpu // 8
        var bit_i = cpu % 8
        mask[byte_i] = UInt8(1) << UInt8(bit_i)
        # FFI-BOUNDARY: sched_setaffinity(pid_t, size_t, cpu_set_t*) -> int.
        # Library: libc.so.6. pid=0 means "the calling thread".
        var ret = external_call["sched_setaffinity", c_int](
            c_int(0), _CPU_SET_BYTES, mask
        )
        mask.free()
        return ret == 0
    else:
        return False


def confine_current_thread_to(cpus: List[Int]) -> Bool:
    """Confine the CALLING thread to a SET of logical CPUs via
    `sched_setaffinity(0, ...)`.

    The multi-CPU sibling of `pin_current_thread_to`, and the difference is the
    whole point of the NUMA restriction: a mask of N CPUs leaves CFS free to
    migrate and load-balance INSIDE the set (which is what `numactl
    --cpunodebind` does), where a 1-CPU mask does not (which is what
    `pin_workers` does). Callers treat a False return as "ran unconfined",
    which is always safe.

    Args:
        cpus: The logical CPUs to allow. Ids outside [0, 1024) are DROPPED, not
            an error — an out-of-range id in a sysfs list is bad data, and
            failing the whole confinement over one is worse than ignoring it.
            An EMPTY resulting mask returns False WITHOUT touching the kernel:
            `sched_setaffinity` with an empty mask is EINVAL, and a thread that
            is allowed on nothing is not a state we want to ask for.

    SAFETY:
      (a) `mask` is a heap-allocated 128-byte (`_CPU_SET_BYTES`) buffer, zeroed
          then with one bit set per allowed cpu, freed before return. The
          pointer is valid for the whole syscall.
      (b) The snapshot-before-narrow ordering invariant is the same one
          `pin_current_thread_to` documents, and is honoured for the same
          reason — see the `_ = _read_allowed_cpus()` line below.
    """
    comptime if CompilationTarget.is_linux():
        # ORDERING INVARIANT — identical to `pin_current_thread_to`: snapshot
        # the PROCESS-wide allowed set BEFORE narrowing this thread's mask, so
        # a later `sched_getaffinity(0, ...)` from this thread cannot shrink the
        # engine's idea of the machine. Structural, not conventional: you cannot
        # narrow through this API without the snapshot already being taken.
        _ = _read_allowed_cpus()
        var mask = alloc[UInt8](_CPU_SET_BYTES)
        for i in range(_CPU_SET_BYTES):
            mask[i] = 0
        var n_set = 0
        for i in range(len(cpus)):
            var cpu = cpus[i]
            if cpu < 0 or cpu >= _CPU_SET_MAX:
                continue
            # Bit `cpu`: byte = cpu // 8, bit = cpu % 8. `|=` because two ids in
            # the same byte must both survive — the one place this differs
            # materially from the single-CPU pin's straight assignment.
            var byte_i = cpu // 8
            var bit_i = cpu % 8
            mask[byte_i] = mask[byte_i] | (UInt8(1) << UInt8(bit_i))
            n_set += 1
        if n_set == 0:
            mask.free()
            return False
        # FFI-BOUNDARY: sched_setaffinity(pid_t, size_t, cpu_set_t*) -> int.
        # Library: libc.so.6. pid=0 means "the calling thread".
        var ret = external_call["sched_setaffinity", c_int](
            c_int(0), _CPU_SET_BYTES, mask
        )
        mask.free()
        return ret == 0
    else:
        return False


def reset_current_thread_affinity_to_all() -> Bool:
    """Clear the CALLING thread's affinity restriction: set an ALL-ONES mask.

    The kernel intersects the requested mask with the cpuset/cgroup the task
    belongs to, so an all-ones request is exactly "no thread-level pin" — the
    thread is handed back the process's full cpuset. Bits for CPUs that do not
    exist are ignored (the call succeeds as long as at least one online,
    cpuset-allowed CPU is in the mask).

    This is the inverse of `pin_current_thread_to` and is deliberately
    CACHE-INDEPENDENT: it does not consult the topology snapshot, so it works
    (and restores the true host set) even on a build whose snapshot is wrong.
    That property is what lets the topology regression test restore the
    test thread and then
    measure the UNRESTRICTED truth to compare against.

    Returns:
        True iff the mask was applied. False on non-Linux or an EINVAL/EPERM.
    """
    comptime if CompilationTarget.is_linux():
        var mask = alloc[UInt8](_CPU_SET_BYTES)
        for i in range(_CPU_SET_BYTES):
            mask[i] = 0xFF
        # FFI-BOUNDARY: sched_setaffinity(pid_t, size_t, cpu_set_t*) -> int.
        # Library: libc.so.6. pid=0 means "the calling thread".
        var ret = external_call["sched_setaffinity", c_int](
            c_int(0), _CPU_SET_BYTES, mask
        )
        mask.free()
        return ret == 0
    else:
        return False


# =============================================================================
# Internal: sched_getaffinity probe (cpu_set_t fully confined here)
# =============================================================================


struct _AllowedCpuSnapshot(Copyable, Movable):
    """The PROCESS-WIDE allowed-CPU set, sampled once and frozen.

    Storage is a 1024-bit mask in `InlineArray[UInt64, 16]` plus a count —
    strictly POD (no `List`, no `String`, no `OwnedPointer`, no wildcard
    origin), so it is safe as `_Global` static storage: the hazard is
    heap-OWNING fields inside process-lifetime/byte-slab storage, and this
    struct has none.
    """

    var count: Int
    var words: Array[UInt64, _CPU_SET_WORDS]
    var fallback_cores: Int
    """`num_physical_cores()` sampled at the SAME unpinned moment as the mask.

    Mojo's `num_physical_cores()` is itself AFFINITY-AWARE on Linux — under
    `taskset -c 0` it reports 1, not the host's core count. So `_fallback()` (the probe-failure /
    non-Linux path) would collapse to a one-worker pool under a thread pin for
    exactly the same reason the mask does. Freezing it here makes the fallback
    pin-immune too, instead of leaving a second copy of the bug behind the
    first one's error path.
    """

    def __init__(out self, cpus: List[Int], fallback_cores: Int):
        """Freeze `cpus` into the bit mask. Out-of-range ids are dropped."""
        self.count = 0
        self.fallback_cores = fallback_cores
        self.words = Array[UInt64, _CPU_SET_WORDS](fill=0)
        for i in range(len(cpus)):
            var c = cpus[i]
            if c < 0 or c >= _CPU_SET_MAX:
                continue
            var wi = c // 64
            self.words[wi] = self.words[wi] | (UInt64(1) << UInt64(c % 64))
            self.count += 1

    def to_list(self) -> List[Int]:
        """Expand the mask back to a sorted ascending List[Int]."""
        var out = List[Int]()
        for w in range(_CPU_SET_WORDS):
            var word = self.words[w]
            if word == 0:
                continue
            for b in range(64):
                if (word & (UInt64(1) << UInt64(b))) != 0:
                    out.append(w * 64 + b)
        return out^


def _init_allowed_cpu_snapshot() -> OwnedPointer[_AllowedCpuSnapshot]:
    """`_Global` init_fn — runs EXACTLY ONCE per process, under the stdlib's
    own init-once guard. THE probe of `sched_getaffinity` for the whole
    process happens here, so the sample is taken at the first topology query
    (and, via `pin_current_thread_to`'s prime, always before any in-tree
    thread pin narrows the mask)."""
    var probed = _probe_allowed_cpus_uncached()
    var cores = num_physical_cores()
    var raw = alloc[_AllowedCpuSnapshot](1)
    # SAFETY: FFI carve-out — `raw` is fresh uninitialized storage handed
    # straight to the `_Global` OwnedPointer, which owns it for process
    # lifetime. Exactly one `init_pointee_move` into it, no aliasing.
    raw.unsafe_write(_AllowedCpuSnapshot(probed, cores))
    return OwnedPointer[_AllowedCpuSnapshot](unsafe_from_raw_pointer=raw)


def _process_physical_core_count() -> Int:
    """`num_physical_cores()` as sampled at snapshot time — the process-wide
    value, immune to a later thread pin (see `_AllowedCpuSnapshot`).

    Degrades to a LIVE `num_physical_cores()` if the snapshot is unavailable,
    which is never worse than the pre-fix behaviour."""
    try:
        # SAFETY: FFI carve-out (see `_read_allowed_cpus`).
        var gp = _ALLOWED_CPU_SNAPSHOT.get_or_create_ptr()
        var n = gp[][].fallback_cores
        if n > 0:
            return n
    except:  # cov: unreachable _Global.get_or_create_ptr raises only when given on_error_msg, and this one is not
        pass
    return num_physical_cores()


comptime _ALLOWED_CPU_SNAPSHOT = _Global[
    "komira_host_runtime_allowed_cpu_snapshot",
    _init_allowed_cpu_snapshot,
]


# =============================================================================
# Internal: the derived topology, frozen per process
# =============================================================================


struct _TopologySnapshot(Copyable, Movable):
    """The DERIVED `CpuTopology`, frozen once per process.

    Storage is three fixed `InlineArray[Int32, _CPU_SET_MAX]` lanes plus their
    lengths and the driver id — strictly POD (no `List`, no `String`, no
    `OwnedPointer`, no wildcard origin), so it is safe as `_Global`
    static storage, for exactly the reason `_AllowedCpuSnapshot` is: the
    hazard is heap-OWNING fields inside process-lifetime storage, and this
    struct has none.

    ORDER IS PRESERVED, not re-sorted. `derive_pools` emits `compute` and `io`
    in core order, and downstream placement (`derive_io_placement`, the
    worker-pin site) pairs `compute[k]` with `io[k]` positionally — so a
    bitmask round-trip, which would silently re-sort, is NOT a legal encoding
    here. Index-parallel arrays are.
    """

    var n_allowed: Int
    var n_compute: Int
    var n_io: Int
    var driver: Int
    var io_mode: UInt8
    var allowed: Array[Int32, _CPU_SET_MAX]
    var compute: Array[Int32, _CPU_SET_MAX]
    var io: Array[Int32, _CPU_SET_MAX]

    def __init__(out self, topo: CpuTopology):
        """Freeze `topo`'s three lanes verbatim. A lane longer than
        `_CPU_SET_MAX` (impossible — every id came from a `_CPU_SET_MAX`-wide
        affinity mask) is truncated rather than overrunning."""
        self.allowed = Array[Int32, _CPU_SET_MAX](fill=Int32(-1))
        self.compute = Array[Int32, _CPU_SET_MAX](fill=Int32(-1))
        self.io = Array[Int32, _CPU_SET_MAX](fill=Int32(-1))
        var a = topo.allowed_cpus()
        var c = topo.compute_cpus()
        var i = topo.io_cpus()
        var na = min(len(a), _CPU_SET_MAX)
        var nc = min(len(c), _CPU_SET_MAX)
        var ni = min(len(i), _CPU_SET_MAX)
        for k in range(na):
            self.allowed[k] = Int32(a[k])
        for k in range(nc):
            self.compute[k] = Int32(c[k])
        for k in range(ni):
            self.io[k] = Int32(i[k])
        self.n_allowed = na
        self.n_compute = nc
        self.n_io = ni
        self.driver = topo.driver_cpu()
        self.io_mode = topo.io_placement_mode()

    def to_topology(self) -> CpuTopology:
        """Rebuild the `CpuTopology` value. Three small `List` fills — no
        syscall, no sysfs, no parse."""
        var a = List[Int]()
        var c = List[Int]()
        var i = List[Int]()
        for k in range(self.n_allowed):
            a.append(Int(self.allowed[k]))
        for k in range(self.n_compute):
            c.append(Int(self.compute[k]))
        for k in range(self.n_io):
            i.append(Int(self.io[k]))
        return CpuTopology(a^, c^, i^, self.driver, self.io_mode)


def _init_topology_snapshot() -> OwnedPointer[_TopologySnapshot]:
    """`_Global` init_fn — runs EXACTLY ONCE per process under the stdlib's own
    init-once guard. THE sysfs sibling walk + cgroup-quota read for the whole
    process happen here."""
    _bump_topology_probe_count()
    var probed = CpuTopology.detect_uncached()
    var raw = alloc[_TopologySnapshot](1)
    # SAFETY: FFI carve-out — `raw` is fresh uninitialized storage handed
    # straight to the `_Global` OwnedPointer, which owns it for process
    # lifetime. Exactly one `init_pointee_move` into it, no aliasing.
    raw.unsafe_write(_TopologySnapshot(probed))
    return OwnedPointer[_TopologySnapshot](unsafe_from_raw_pointer=raw)


comptime _DETECTED_TOPOLOGY = _Global[
    "komira_host_runtime_detected_topology",
    _init_topology_snapshot,
]


def _init_topology_probe_counter() -> OwnedPointer[Int]:
    var raw = alloc[Int](1)
    # SAFETY: FFI carve-out — as `_init_topology_snapshot`.
    raw.unsafe_write(0)
    return OwnedPointer[Int](unsafe_from_raw_pointer=raw)


comptime _TOPOLOGY_PROBE_COUNTER = _Global[
    "komira_host_runtime_topology_probe_count",
    _init_topology_probe_counter,
]


def _bump_topology_probe_count():
    try:
        var gp = _TOPOLOGY_PROBE_COUNTER.get_or_create_ptr()
        gp[][] += 1
    except:
        pass


def topology_probe_count() -> Int:
    """How many times this process has run the UNCACHED topology derivation.

    The falsifier for the topology freeze: it reaches 1 and stays there for
    the life of the process no matter how many `detect()` / `engine_topology()
    / `engine_worker_count()` calls follow. A guard that calls `detect()` N
    times and asserts this is 1 fails loudly if the freeze is ever removed.

    Returns 0 only if `detect()` has never been called in this process. It is
    NOT platform-conditional: `detect()` routes every target through
    `_frozen_detected_topology()`, so the counter reaches 1 on the first call
    and stays there on macOS exactly as it does on Linux."""
    try:
        var gp = _TOPOLOGY_PROBE_COUNTER.get_or_create_ptr()
        return gp[][]
    except:
        return 0


def _frozen_detected_topology() -> CpuTopology:
    """The process-frozen `detect()` result. Degrades to a live probe if the
    global is unavailable, which is never worse than not freezing."""
    try:
        # SAFETY: FFI carve-out (see `_read_allowed_cpus`).
        var gp = _DETECTED_TOPOLOGY.get_or_create_ptr()
        return gp[][].to_topology()
    except:
        return CpuTopology.detect_uncached()  # cov: unreachable _Global.get_or_create_ptr raises only when given on_error_msg, and this one is not


# =============================================================================
# Internal: the NUMA node probe + its per-process freeze
# =============================================================================


def _read_numa_node_ids() -> List[Int]:
    """The ONLINE NUMA node ids from `/sys/devices/system/node/online`.

    The file holds a Linux cpu-list-grammar range ("0-1", "0,2"), so
    `_parse_cpu_list` parses it verbatim — node ids and CPU ids share the
    grammar exactly.

    Returns an EMPTY list on any failure, and that is the important case: a
    kernel built without NUMA, a hardened container with no `/sys`, or macOS all
    land here, and an empty list makes every NUMA derivation take its identity
    no-op arm. `_read_small_file` already returns "" rather than raising.
    """
    comptime if CompilationTarget.is_linux():
        var online = _read_small_file(String("/sys/devices/system/node/online"))
        if online.byte_length() == 0:
            return List[Int]()
        return _parse_cpu_list(online)
    else:
        return List[Int]()


def _read_numa_node_cpulists(node_ids: List[Int]) -> List[List[Int]]:
    """Per-node CPU lists, index-parallel to `node_ids`.

    Reads `/sys/devices/system/node/node<id>/cpulist` for each id. A node whose
    file is unreadable contributes an EMPTY list rather than being dropped, so
    the index-parallel correspondence with `node_ids` (which is what turns a
    `numa_preferred_node` ORDINAL back into a kernel node id) is never broken by
    a partial read.

    Cost: `1 + len(node_ids)` small-file reads, paid ONCE per process — see
    `_init_numa_local_snapshot`.
    """
    var out = List[List[Int]]()
    comptime if CompilationTarget.is_linux():
        for i in range(len(node_ids)):
            var path = String("/sys/devices/system/node/node")
            path += String(node_ids[i])
            path += String("/cpulist")
            var contents = _read_small_file(path^)
            if contents.byte_length() == 0:
                out.append(List[Int]())
            else:
                out.append(_parse_cpu_list(contents))
    return out^


struct _NumaLocalSnapshot(Copyable, Movable):
    """The NUMA restriction's result, frozen once per process.

    Frozen for the same reason `_TopologySnapshot` is: `engine_topology()` is
    reached from `engine_worker_count()` on every materialize dispatch, ON THE
    DRIVER, inside the serial region — so a per-call
    `/sys/devices/system/node/*` walk would be a per-query sysfs cost.

    Plain data: `Int` + `UInt8` + `InlineArray` only, no `List` / `String` /
    `OwnedPointer` / wildcard origin anywhere in the closure, which is what
    makes it legal as `_Global` process-lifetime storage.
    """

    var spanned: Int
    """Distinct NUMA nodes the DETECTED compute lane spans. 0 = no NUMA
    information at all; 1 = single-node host. Both are the no-op."""

    var node_id: Int
    """The KERNEL node id chosen (not the ordinal), or -1 when nothing was
    restricted. Kept as the kernel id because that is what an operator reading a
    diagnostic will compare against `numactl -H` / `lscpu`."""

    var topo: _TopologySnapshot
    """The RESTRICTED topology, or a verbatim freeze of the detected one on
    every no-op path."""

    def __init__(out self, spanned: Int, node_id: Int, topo: CpuTopology):
        self.spanned = spanned
        self.node_id = node_id
        self.topo = _TopologySnapshot(topo)


def _init_numa_local_snapshot() -> OwnedPointer[_NumaLocalSnapshot]:
    """`_Global` init_fn — runs EXACTLY ONCE per process. THE
    `/sys/devices/system/node` walk for the whole process happens here.

    Nested `_Global` creation (`CpuTopology.detect()` reaches
    `_DETECTED_TOPOLOGY`, which itself reaches `_ALLOWED_CPU_SNAPSHOT`) is the
    shape `_init_topology_snapshot` already ships, so it is known-good here.
    """
    var detected = CpuTopology.detect()
    var ids = _read_numa_node_ids()
    var lists = _read_numa_node_cpulists(ids)
    var spanned = numa_nodes_spanned(detected.compute_cpus(), lists)
    var ordinal = numa_preferred_node(detected.compute_cpus(), lists)
    var node_id = -1
    var restricted = derive_numa_locality(detected^, lists)
    if spanned > 1 and ordinal >= 0 and ordinal < len(ids):
        node_id = ids[ordinal]
    var raw = alloc[_NumaLocalSnapshot](1)
    # SAFETY: FFI carve-out — `raw` is fresh uninitialized storage handed
    # straight to the `_Global` OwnedPointer, which owns it for process
    # lifetime. Exactly one `init_pointee_move` into it, no aliasing.
    raw.unsafe_write(_NumaLocalSnapshot(spanned, node_id, restricted))
    return OwnedPointer[_NumaLocalSnapshot](unsafe_from_raw_pointer=raw)


comptime _NUMA_LOCAL_SNAPSHOT = _Global[
    "komira_host_runtime_numa_local_snapshot",
    _init_numa_local_snapshot,
]


def _frozen_numa_local_topology() -> CpuTopology:
    """The process-frozen NUMA-restricted topology. Degrades to the
    unrestricted `CpuTopology.detect()` if the global is unavailable — never
    worse than running without the restriction."""
    try:
        # SAFETY: FFI carve-out (see `_read_allowed_cpus`).
        var gp = _NUMA_LOCAL_SNAPSHOT.get_or_create_ptr()
        return gp[][].topo.to_topology()
    except:
        return CpuTopology.detect()  # cov: unreachable _Global.get_or_create_ptr raises only when given on_error_msg, and this one is not


def _frozen_numa_snapshot_spanned() -> Int:
    """Distinct NUMA nodes the detected compute lane spans; 0 on any failure."""
    try:
        # SAFETY: FFI carve-out (see `_read_allowed_cpus`).
        var gp = _NUMA_LOCAL_SNAPSHOT.get_or_create_ptr()
        return gp[][].spanned
    except:
        return 0


def _frozen_numa_snapshot_node_id() -> Int:
    """The chosen KERNEL node id, or -1 (also on any failure)."""
    try:
        # SAFETY: FFI carve-out (see `_read_allowed_cpus`).
        var gp = _NUMA_LOCAL_SNAPSHOT.get_or_create_ptr()
        return gp[][].node_id
    except:
        return -1  # cov: unreachable _Global.get_or_create_ptr raises only when given on_error_msg, and this one is not


def _read_allowed_cpus() -> List[Int]:
    """The PROCESS-WIDE allowed logical-CPU set, sampled once and reused.

    WHY IT IS SAMPLED ONCE
    ----------------------
    `sched_getaffinity(0, ...)` on Linux means **the CALLING THREAD**, not the
    process — `pid == 0` is `gettid()`, not `getpid()`. Every consumer of this
    module, though, asks a PROCESS-WIDE question ("how many workers should
    this engine run?"). Deriving a process invariant from a per-thread
    property is only correct while no thread is pinned.

    `pin_driver_thread()` (with a driver reservation in the placement) pins
    the driver — which is the same thread that constructs the engine context
    and then drives every later materialize dispatch. A per-call re-probe
    would see `allowed = {driver_cpu}` on the first query after that pin and
    derive a ONE-worker pool, with the already-spawned workers spinning and
    parking.

    WHY A SNAPSHOT, AND NOT THE OTHER TWO CANDIDATES
    ------------------------------------------------
      * `/proc/self/status` `Cpus_allowed` — REFUTED EMPIRICALLY. `/proc/self`
        resolves to the thread-GROUP LEADER (the main thread), and our driver
        IS the main thread, so the field collapses to the pinned CPU exactly
        like `sched_getaffinity` does: pinning the main thread to cpu 1 moves
        `Cpus_allowed_list` from `0-27` to `1`. It reads like a process-wide
        source and is not one.
      * cgroup `cpuset.cpus.effective` — genuinely process-wide and immune to
        thread pins, but it is NOT the whole answer: it is blind to a
        `taskset`-launched process (a real deployment shape) whose affinity is
        restricted while its cpuset is unrestricted, and the controller is
        frequently absent from the leaf cgroup. It would under-count exactly the containers the module was
        written for and over-thread the taskset case.
      * SNAPSHOT-ONCE (chosen) — sample `sched_getaffinity` while the process
        is still unrestricted and freeze it. It is correct for BOTH the cpuset
        and the taskset shape (both are visible in the initial mask), needs no
        new syscall or file, and matches the semantics consumers actually
        want: the worker pool is sized once at startup and does not resize.

    THE ORDERING GUARANTEE. The sample must be taken before any thread is
    pinned. That is structural, not conventional: `pin_current_thread_to` —
    the ONLY affinity-narrowing path in this package — calls this function
    before it issues `sched_setaffinity`. So the snapshot is always taken
    through an unrestricted mask. `prime_cpu_topology()` is the
    explicit entry point for an embedder that wants to name the sample point.

    WHAT THE SNAPSHOT COSTS. A cpuset/affinity change applied to a LIVE
    process is no longer picked up; the engine keeps the startup sizing. That
    is the intended trade — the worker pool is spawned once and never
    resized, so re-probing could only ever produce a pool-size value that
    disagrees with the pool that actually exists (which is precisely the bug
    above). The cgroup v2 `cpu.max` QUOTA read in `_detect_linux` is
    deliberately left UNCACHED, so a live quota change is still honoured.

    Returns:
        The allowed set as a sorted List[Int], or an EMPTY list on any
        failure (callers fall back to `num_physical_cores()`).
    """
    comptime if CompilationTarget.is_linux():
        try:
            # SAFETY: FFI carve-out — `get_or_create_ptr` targets
            # KGEN-runtime static storage (process-lifetime); the wildcard is
            # the stdlib `_Global` API's own return type, confined here.
            var gp = _ALLOWED_CPU_SNAPSHOT.get_or_create_ptr()
            var snap = gp[][].to_list()
            if len(snap) > 0:
                return snap^
        except:  # cov: unreachable _Global.get_or_create_ptr raises only when given on_error_msg, and this one is not
            pass
        # Snapshot unavailable, or the one-shot probe failed at snapshot time
        # (hardened kernel, non-Linux emulation). Degrade to a live probe
        # rather than reporting an empty set from a transient failure.
        return _probe_allowed_cpus_uncached()
    else:
        return List[Int]()


def _probe_allowed_cpus_uncached() -> List[Int]:
    """Raw, UNCACHED `sched_getaffinity(0, ...)` probe of the CALLING THREAD.

    Do NOT call this directly for sizing/placement decisions — it is
    thread-scoped and is the source of the bug documented on
    `_read_allowed_cpus`. It exists only as (a) the one-shot input to the
    process-wide snapshot and (b) the degraded fallback when the snapshot
    machinery is unavailable.

    SAFETY:
      (a) `mask` is a heap-allocated 128-byte buffer (`_CPU_SET_BYTES` =
          glibc cpu_set_t size = 1024 bits), zeroed before the call and freed
          before return. The pointer is valid for the whole syscall.
      (b) RETURN-VALUE SEMANTICS (the load-bearing detail; see below). The
          success return of `sched_getaffinity` is NOT portably 0 -- it
          depends on whether `external_call` binds the glibc wrapper or the
          raw syscall, which DIFFERS between the JIT (source) and AOT
          (precompiled package) build paths:
            * glibc wrapper: returns 0 on success.
            * raw syscall (the AOT-linked binding observed on x86_64 Linux): returns the number of BYTES used in the mask
              (e.g. 8 for 28 CPUs), i.e. a POSITIVE value on success.
          Both return a NEGATIVE value on failure. So the only portable
          success/failure discriminator is `ret >= 0` (success) vs `ret < 0`
          (failure) -- NOT `ret == 0`. A `ret != 0` guard would discard the
          (correct, fully-populated) mask whenever the raw-syscall binding is
          in effect, collapsing the allowed set and sizing the engine to a
          SINGLE worker. We additionally validate
          the mask is non-empty (a "success with empty mask" is treated as a
          probe failure -> caller falls back).
      (c) We read the mask byte-by-byte; bit `cpu` lives at byte cpu//8,
          bit cpu%8. No aliasing cast, no alignment trap.
    """
    comptime if CompilationTarget.is_linux():
        var mask = alloc[UInt8](_CPU_SET_BYTES)
        for i in range(_CPU_SET_BYTES):
            mask[i] = 0
        # FFI-BOUNDARY: sched_getaffinity(pid_t, size_t, cpu_set_t*) -> int.
        # Library: libc.so.6. pid=0 means "the calling thread".
        var ret = external_call["sched_getaffinity", c_int](
            c_int(0), _CPU_SET_BYTES, mask
        )
        # Failure is a NEGATIVE return (errno). Success is 0 (glibc wrapper)
        # OR a positive byte-count (raw syscall) -- accept both via `< 0`.
        if Int(ret) < 0:
            mask.free()
            return List[Int]()
        var out = List[Int]()
        for byte_i in range(_CPU_SET_BYTES):
            var b = Int(mask[byte_i])
            if b == 0:
                continue
            for bit_i in range(8):
                if (b & (1 << bit_i)) != 0:
                    out.append(byte_i * 8 + bit_i)
        mask.free()
        # A "success with an empty mask" is degenerate -- treat as a probe
        # failure so the caller falls back to num_physical_cores().
        return out^
    else:
        return List[Int]()


# =============================================================================
# Internal: sysfs thread_siblings_list reader + parser
# =============================================================================


def _read_thread_siblings(cpu: Int) -> List[Int]:
    """Read and parse
    `/sys/devices/system/cpu/cpu<cpu>/topology/thread_siblings_list`.

    The file is a comma/range list, e.g. "0,44" (comma form) or "0-1" or
    "0-21,44-65" (range form). Returns the expanded list of sibling logical
    CPUs, or an EMPTY list on failure (file missing / unreadable -- caller
    treats the cpu as a lone core)."""
    var path = String("/sys/devices/system/cpu/cpu")
    path += String(cpu)
    path += String("/topology/thread_siblings_list")
    var contents = _read_small_file(path^)
    if contents.byte_length() == 0:
        return List[Int]()
    return _parse_cpu_list(contents)


def _parse_cpu_list(s: String) -> List[Int]:
    """Parse a Linux cpu-list string ("0,44" / "0-1" / "0-21,44-65") into the
    expanded list of CPU indices. Tolerates trailing newline / whitespace.
    Returns an empty list if nothing parses."""
    var out = List[Int]()
    var n = s.byte_length()
    if n == 0:
        return out^
    var bs = s.as_bytes()
    var i = 0
    while i < n:
        # Skip separators / whitespace.
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
        # Parse first number of a token.
        var lo = 0
        while i < n:
            var d = Int(bs[i])
            if d >= _ASCII_ZERO and d <= _ASCII_NINE:
                lo = lo * 10 + (d - _ASCII_ZERO)
                i += 1
            else:
                break
        # Range? Look for '-' then a second number.
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
        # Emit [lo, hi].
        if hi >= lo:
            var v = lo
            while v <= hi:
                out.append(v)
                v += 1
    return out^


# =============================================================================
# Internal: cgroup v2 cpu.max quota reader (best-effort)
# =============================================================================


def _read_cgroup_v2_quota_cores() -> Int:
    """Read the cgroup v2 CPU quota for the current process and convert it to
    an integer core-count cap (ceil(quota / period)). Returns 0 when there is
    no quota / not measurable (the common case) so the caller leaves the
    cpuset-derived count untouched.

    cgroup v2 `cpu.max` format: "<quota> <period>" in microseconds, where
    quota == "max" means unlimited. We locate the leaf cgroup via the unified
    `/proc/self/cgroup` (a single `0::<path>` line on v2) and read
    `/sys/fs/cgroup<path>/cpu.max`. Best-effort: ANY parse miss returns 0."""
    var rel = _read_unified_cgroup_path()
    if rel.byte_length() == 0:
        return 0
    var path = String("/sys/fs/cgroup")
    path += rel
    path += String("/cpu.max")
    var contents = _read_small_file(path^)
    if contents.byte_length() == 0:
        return 0
    # Format: "<quota> <period>". "max <period>" -> unlimited.
    var bs = contents.as_bytes()
    var n = contents.byte_length()
    # First token.
    var i = 0
    # If it starts with 'm' (the word "max"), unlimited.
    if n > 0 and Int(bs[0]) != 0:
        var first = Int(bs[0])
        if first < _ASCII_ZERO or first > _ASCII_NINE:
            return 0
    var quota = 0
    while i < n:
        var d = Int(bs[i])
        if d >= _ASCII_ZERO and d <= _ASCII_NINE:
            quota = quota * 10 + (d - _ASCII_ZERO)
            i += 1
        else:
            break
    # Skip the space.
    while i < n and (Int(bs[i]) == _ASCII_SPACE or Int(bs[i]) == _ASCII_NEWLINE):
        i += 1
    var period = 0
    while i < n:
        var d = Int(bs[i])
        if d >= _ASCII_ZERO and d <= _ASCII_NINE:
            period = period * 10 + (d - _ASCII_ZERO)
            i += 1
        else:
            break
    if quota <= 0 or period <= 0:
        return 0
    # ceil(quota / period).
    var cores = (quota + period - 1) // period
    if cores < 1:
        cores = 1
    return cores


def _read_unified_cgroup_path() -> String:
    """Return the relative cgroup path from `/proc/self/cgroup`'s unified
    (`0::<path>`) line, or "" if absent. v2 hosts have exactly one `0::` line;
    we return the `<path>` (already leading-slash, e.g. "/user.slice/...")."""
    var contents = _read_small_file(String("/proc/self/cgroup"))
    var n = contents.byte_length()
    if n == 0:
        return String("")
    var bs = contents.as_bytes()
    # Find a line beginning "0::". Lines are '\n'-separated.
    var i = 0
    while i < n:
        # Is this the start of a "0::" line?
        if (
            i + 2 < n
            and Int(bs[i]) == _ASCII_ZERO
            and Int(bs[i + 1]) == 58  # ':'
            and Int(bs[i + 2]) == 58  # ':'
        ):
            # Collect to end of line.
            var j = i + 3
            var path = String("")
            while j < n and Int(bs[j]) != _ASCII_NEWLINE:
                path += chr(Int(bs[j]))
                j += 1
            return path
        # Advance to next line.
        while i < n and Int(bs[i]) != _ASCII_NEWLINE:
            i += 1
        i += 1  # skip the newline
    return String("")


# =============================================================================
# Internal: small-file reader (fopen/fread/fclose) -- Linux only
# =============================================================================


def _read_small_file(var path: String) -> String:
    """fopen + fread + fclose of a small sysfs/procfs file, capped at
    `_SIBLINGS_FILE_MAX` bytes. Returns "" on any error. Mirrors
    `proc_probe.mojo`'s `_read_small_file_to_string` (kept local so the FFI
    surface of this module is auditable in one place).

    SAFETY:
      (a) `buf` is heap-allocated and freed before return; valid for the
          whole frame.
      (b) `fopen` returns FILE* as Int64; 0 = null-on-failure; we branch.
      (c) `path` is by-value so `.as_c_string_slice()` may NUL-append; the
          C-string pointer is valid until the call returns.
    """
    comptime if CompilationTarget.is_linux():
        var c_path = path.as_c_string_slice().unsafe_ptr()
        var mode_str = String("rb")
        var c_mode = mode_str.as_c_string_slice().unsafe_ptr()
        # FFI-BOUNDARY: libc fopen. Library: libc.so.6.
        var fp = external_call["fopen", Int64](c_path, c_mode)
        if fp == 0:
            return String("")
        var buf = alloc[UInt8](_SIBLINGS_FILE_MAX)
        # FFI-BOUNDARY: fread(ptr, size, nmemb, FILE*) -> size_t.
        var n_read = external_call["fread", Int64](
            buf, Int64(1), Int64(_SIBLINGS_FILE_MAX), fp
        )
        _ = external_call["fclose", Int32](fp)
        if n_read <= 0:
            buf.free()
            return String("")
        var n_int = Int(n_read)
        var s = String("")
        var i = 0
        while i < n_int:
            s += chr(Int(buf[i]))
            i += 1
        buf.free()
        return s
    else:
        return String("")
