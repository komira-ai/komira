# =============================================================================
# hardware_detect -- probe the machine once and return its HardwareProfile
# =============================================================================
#
# `detect_hardware_profile()` is the only code in the engine that reads the
# machine's CPU, cache and memory shape. It is called when the host profile is
# built (`host_detect.detect_host_profile`), once per host process; lowering
# and morsel sizing then read the recorded value and never probe again. It
# keeps no state of its own: each call re-runs the probes.
#
# Platform support
# ----------------
# Platform support
# ----------------
# * macOS:
#     Uses `sysctlbyname` FFI for CPU/cache/memory counts. On heterogeneous
#     silicon (Apple M-series with P+E clusters), additionally probes
#     `hw.perflevel0.l1dcachesize` (P-core L1d) and
#     `hw.perflevel1.l1dcachesize` (E-core L1d) and stores
#     `min(P-core, E-core)` in `l1d_min_bytes`. On homogeneous silicon
#     (older Intel Macs), the perflevel keys are absent and
#     `l1d_min_bytes == l1d_cache_bytes`. `host_statistics64` for available
#     RAM is NOT ported in this commit -- `available_ram_bytes` falls back
#     to `total / 2` (same fallback the v0.3 code already uses when the
#     Mach call fails).
#
# * Linux (MORSEL-SIZE-HARDWARE-AUTO-DERIVE SS1):
#     Uses sysfs reads under `/sys/devices/system/cpu/cpuN/cache/indexM/`.
#     The probe walks per-CPU directories and per-cache `index*` entries,
#     identifies data-L1, unified-L2, and unified-L3 caches by `level`+
#     `type` files, and takes the MIN L1d across all CPUs (heterogeneous
#     big.LITTLE / Intel hybrid). Core count comes from
#     `sysconf(_SC_NPROCESSORS_ONLN)` (constant 84 on glibc; stable ABI).
#     Container-aware: if sysfs files are missing (hardened K8s with
#     `read_only_root_filesystem`), warns on stderr and returns
#     `defaults()`.
#
# BINDING L2 INSTANCE. Additionally probes
#     `cache/index<L2>/{size,shared_cpu_list}` + `topology/thread_siblings_list`
#     over the PROCESS-WIDE allowed CPU set and reports the L2 instance with
#     the smallest per-worker share into `e_core_l2_bytes` / `e_cores_per_l2`.
#     This replaces a "cpu0's L2, divisor 1" placeholder that was 2x too large
#     on a hybrid part (it read a private P-core L2 and ignored the E cluster's
#     4-way sharing). The formula and its derivation live in `l2_share.mojo`;
#     this file owns only the sysfs reads that feed it.
#
# * Other platforms: `defaults()` (Apple-Silicon-shaped baseline).
#
# Purity contract (CRITICAL)
# --------------------------
# `HardwareProfile.detect()` is a PURE function: NO module-level state, NO
# caching, NO singleton. The caller is responsible for caching the result
# (e.g. `EngineContext` caches at session init). Mojo has no module-level
# mutable globals, so the v0.3 `OnceLock` pattern doesn't translate; each
# `detect()` call re-runs the FFI syscalls (~few microseconds on macOS;
# ~10s of microseconds on Linux due to sysfs reads). Consumers that call
# this on a hot path MUST hoist the detection result.
#
# Failure mode
# ------------
# If hardware probing fails (sysctl unavailable, sysfs missing under
# container), `detect()` prints a one-line warning to stdout (Mojo
# Mojo's `print(...)` has no `file=stderr` parameter, so we prefix
# with `"komira: warning:"` matching the project convention in
# `pthread_worker.mojo`) and returns `default_hardware_profile()`. Does
# NOT raise. maintainer directive (Q2): warn-and-fall-back so a
# customer with sysfs-blocked containers gets a clear triage signal
# instead of silent pessimistic defaults.
#
# =============================================================================

# =============================================================================
# FFI-BOUNDARY: libc sysctl(3) (darwin sysctlbyname) and sysconf(3).
# =============================================================================
# The only raw pointers in this file are the two 8-byte buffers `_sysctl_u64`
# allocates and frees around one `sysctlbyname` call, and the NULL sentinel
# passed as its (newp, newlen=0) "no-write" argument, which the kernel never
# reads through when newlen == 0. Per-site SAFETY comments are inline below.
# =============================================================================

from std.ffi import external_call, c_int
from std.memory import UnsafePointer, alloc
from std.sys.info import CompilationTarget

from komira_host_profile.hardware import (
    HardwareProfile,
    DEFAULT_L1D_BYTES,
    DEFAULT_L2_BYTES,
    DEFAULT_L3_BYTES,
    DEFAULT_CACHE_LINE,
    DEFAULT_TOTAL_RAM,
    DEFAULT_AVAILABLE_RAM,
    DEFAULT_E_CORE_L2_BYTES,
    DEFAULT_E_CORES_PER_L2,
    DEFAULT_P_CORE_L2_BYTES,
    DEFAULT_P_CORES_PER_L2,
)



# The ONE process-wide CPU snapshot (, ).
#   * `_read_allowed_cpus` -- the allowed logical-CPU set, sampled once BEFORE
#     any in-tree thread pin can narrow it. `sched_getaffinity(0, ...)` is
#     per-THREAD on Linux, so a live probe from a pinned thread would report a
#     one-CPU machine; the L2 probe below MUST NOT do that (see l2_share.mojo
#     "THE AFFINITY CONTRACT").
#   * `_process_physical_core_count` -- `num_physical_cores()` as sampled at
#     that same unpinned moment. Mojo's `num_physical_cores()` is itself
# AFFINITY-AWARE on Linux (measured: it reports 1 under
#     `taskset -c 0`), so this module uses the snapshot value INSTEAD of a live
#     call on every fallback path. Reusing the existing snapshot, not adding a
#     second one, is deliberate: two snapshots taken at two moments can
#     disagree, which is the class of bug this is fixing.
from komira_host.cpu_topology import (
    _read_allowed_cpus,
    _process_physical_core_count,
)

# ENGINE-SEV-1. The procfs/sysfs small-file reader
# and the ASCII parsers used to be DEFINED here; they moved DOWN to
# `komira_host.proc_probe` with `detect_scan_cache_ram_basis_bytes`, the
# host RAM-basis probe that `komira_parquet/runtime_footer_cache.mojo` imported
# from this file. That ONE edge was the repo's highest-leverage severable import:
# cutting it frees hundreds of modules from reaching an engine-proper package.
#
# ⛔ `detect_scan_cache_ram_basis_bytes` IS NOT RE-EXPORTED HERE, DELIBERATELY.
# Importing it back would re-create the edge the move deleted, and it would look
# like tidiness. If you need it, import `komira_host.proc_probe`.
# Nothing else moved: `HardwareProfile`, `DEFAULT_L3_BYTES`, the L2-share
# derivation and `_linux_read_meminfo_total_bytes` all stay in the engine,
# because they are the engine's morsel-sizing model rather than a host probe.
from komira_host.proc_probe import (
    _read_small_file_to_string,
    _parse_decimal_int,
    _find_substring_bytes,
    _ZERO,
    _NINE,
    _SPACE,
    _TAB,
    _NEWLINE,
    _CR,
    _UPPER_K,
    _LOWER_K,
    _UPPER_M,
    _LOWER_M,
    _UPPER_G,
    _LOWER_G,
)
from komira_engine_runtime.l2_share import (
    L2Instance,
    derive_binding_l2_instance,
    parse_cpu_list,
)


# Canonical b2 FFI origin (FFI-BOUNDARY: sysctl(3)). StaticConstantOrigin is a
# CONCRETE (non-wildcard) origin replacing the banned MutExternalOrigin; the
# sole use is the sysctl (newp, newlen)="no-write" NULL sentinel, which the
# kernel never reads through when newlen == 0.
comptime _FFI_ORIGIN = ImmStaticOrigin


@always_inline
def _ffi_null_byte() -> UnsafePointer[UInt8, _FFI_ORIGIN]:
    """Raw NULL byte pointer (replaces the b2-removed null ctor).

    # SAFETY: `Optional[UnsafePointer[...]]` is layout-compatible with the bare
    # pointer; `None` is the all-zero NULL bit pattern. No removed null ctor, no
    # banned `unsafe_from_address=Int(0)`.
    """
    var none: Optional[UnsafePointer[UInt8, _FFI_ORIGIN]] = None
    return UnsafePointer(to=none).bitcast[UnsafePointer[UInt8, _FFI_ORIGIN]]()[]



def default_hardware_profile() -> HardwareProfile:
    """Apple-Silicon-shaped conservative defaults.

    Used as the warn-and-fall-back result on platforms where detection
    is unavailable (e.g. sysfs missing in a hardened container).
    `l1d_min_bytes` is `DEFAULT_L1D_BYTES` (homogeneous-silicon shape).

    Core count comes from `_process_physical_core_count()` (the process-wide
    snapshot), NOT a live `num_physical_cores()` -- the latter is
    affinity-aware on Linux, so a thread that pinned itself would get a
    one-core profile out of this fallback.
    """
    var cores = _process_physical_core_count()
    if cores < 1:
        cores = 4
    return HardwareProfile(
        cores,                    # physical_cores
        cores,                    # logical_cores (HT not distinguished)
        DEFAULT_L1D_BYTES,
        DEFAULT_L2_BYTES,
        DEFAULT_L3_BYTES,
        DEFAULT_CACHE_LINE,
        DEFAULT_TOTAL_RAM,
        DEFAULT_AVAILABLE_RAM,
        1,                        # numa_nodes
        DEFAULT_L1D_BYTES,        # l1d_min_bytes (homogeneous fallback)
        DEFAULT_E_CORE_L2_BYTES,  # e_core_l2_bytes
        DEFAULT_E_CORES_PER_L2,   # e_cores_per_l2
        DEFAULT_P_CORE_L2_BYTES,  # p_core_l2_bytes
        DEFAULT_P_CORES_PER_L2,   # p_cores_per_l2
    )


def detect_hardware_profile() -> HardwareProfile:
    """Detect real hardware characteristics.

    macOS branch: populates from `sysctlbyname` (5-7 syscalls including
    the heterogeneous-aware `hw.perflevel{0,1}.l1dcachesize` probes for
    `l1d_min_bytes`).

    Linux branch: walks sysfs (`/sys/devices/system/cpu/cpuN/cache/`)
    to identify data-L1 / unified-L2 / unified-L3 caches and takes the
    MIN L1d across all CPUs (heterogeneous big.LITTLE / Intel hybrid
    aware). Core count comes from `sysconf(_SC_NPROCESSORS_ONLN)`.

    Other platforms / probe failure: prints a one-line warning to
    stdout (project-convention "komira: warning:" prefix; Mojo
    Mojo's `print` has no `file=stderr` parameter) and returns
    `defaults()`. PURE FUNCTION: no caching, no module state — caller
    is responsible for caching the result.
    """
    comptime if CompilationTarget.is_macos():
        return _detect_macos_or_fallback()
    comptime if CompilationTarget.is_linux():
        return _detect_linux_or_fallback()
    # Other platforms (unlikely in production): warn-and-fall-back.
    print(
        "komira: warning: unsupported platform for HardwareProfile.",
        "detect() — falling back to Apple-Silicon-shaped defaults",
    )
    return default_hardware_profile()

def _detect_macos_or_fallback() -> HardwareProfile:
    """macOS dispatch arm: probes `hw.physicalcpu` first; on success
    runs the full populate; on failure warns + returns defaults.

    The initial `hw.physicalcpu` probe also serves as a sandbox check:
    if a hardened mac sandbox (notebook env, restricted Mach service)
    blocks sysctl, the probe returns 0 and we degrade gracefully.
    """
    var probe = _sysctl_u64(String("hw.physicalcpu"))
    if probe <= 0:
        print(
            "komira: warning: detect_hardware_profile() — sysctl",
            "probe failed (hw.physicalcpu); falling back to defaults",
        )
        return default_hardware_profile()
    return _detect_macos_from_probe(probe)

def _detect_macos_from_probe(physical_cores_probe: Int) -> HardwareProfile:
    """Populate the profile from macOS sysctl keys.

    `physical_cores_probe` is the already-read `hw.physicalcpu` value.
    v0.3 parity: matches `detect_macos` (hardware.rs:262-284), except
    `available_ram_bytes` uses the v0.3 fallback (`total/2`) because the
    Mach `host_statistics64` call is not ported in this commit.

    SS1 EXTENSION: also probes `hw.perflevel0.l1dcachesize`
    (P-core) and `hw.perflevel1.l1dcachesize` (E-core) for the
    `l1d_min_bytes` field. On homogeneous Intel Macs, perflevel1 returns
    0 (absent) and `l1d_min_bytes == l1d_cache_bytes`.
    """
    var physical_cores = physical_cores_probe
    var logical_cores = _sysctl_u64_or(
        String("hw.logicalcpu"), physical_cores
    )
    var l1d = _sysctl_u64_or(
        String("hw.l1dcachesize"), DEFAULT_L1D_BYTES
    )
    var l2 = _sysctl_u64_or(String("hw.l2cachesize"), DEFAULT_L2_BYTES)
    # L3 is absent on Apple Silicon; v0.3 defaults to 0 there and
    # `l3_resident_rows` handles the 0 case specially.
    var l3 = _sysctl_u64_or(String("hw.l3cachesize"), 0)
    var cache_line = _sysctl_u64_or(
        String("hw.cachelinesize"), DEFAULT_CACHE_LINE
    )
    var total_ram = _sysctl_u64_or(
        String("hw.memsize"), DEFAULT_TOTAL_RAM
    )
    var avail_ram = total_ram // 2  # v0.3 fallback; Mach call not ported.
    # SS1: heterogeneous-aware L1d probe. Apple Silicon
    # exposes per-perflevel L1d sizes; M3 Ultra: P-core=192KB,
    # E-core=128KB. `_sysctl_u64` returns 0 when the key is absent
    # (homogeneous Intel Mac), so we compute min over non-zero values.
    var p_l1d = _sysctl_u64(String("hw.perflevel0.l1dcachesize"))
    var e_l1d = _sysctl_u64(String("hw.perflevel1.l1dcachesize"))
    var l1d_min = _min_nonzero3(p_l1d, e_l1d, l1d)
    # E-CORE-L2 HW MORSEL SIZING: probe the per-perflevel L2
    # sharing topology. `_sysctl_u64` returns 0 when the key is absent
    # (homogeneous Intel Mac), so the 0-sentinel flows to the budget
    # accessor which falls back to the homogeneous `l2_cache_bytes`.
    #   perflevel1 = E-cores (the SIZING BUDGET tier per the maintainer decision)
    #   perflevel0 = P-cores (captured for completeness / logging only)
    var e_l2 = _sysctl_u64(String("hw.perflevel1.l2cachesize"))
    var e_per_l2 = _sysctl_u64(String("hw.perflevel1.cpusperl2"))
    var p_l2 = _sysctl_u64(String("hw.perflevel0.l2cachesize"))
    var p_per_l2 = _sysctl_u64(String("hw.perflevel0.cpusperl2"))
    return HardwareProfile(
        physical_cores,
        logical_cores,
        l1d,
        l2,
        l3,
        cache_line,
        total_ram,
        avail_ram,
        1,  # macOS is always UMA (v0.3 hardware.rs:282).
        l1d_min,
        e_l2,      # e_core_l2_bytes  (perflevel1.l2cachesize)
        e_per_l2,  # e_cores_per_l2   (perflevel1.cpusperl2)
        p_l2,      # p_core_l2_bytes  (perflevel0.l2cachesize)
        p_per_l2,  # p_cores_per_l2   (perflevel0.cpusperl2)
    )

def _detect_linux_or_fallback() -> HardwareProfile:
    """Linux dispatch arm: probes sysfs cache hierarchy + sysconf core
    count. Warns and falls back to defaults if any of the cache
    directories are unreadable (common in restricted containers).
    """
    # sysconf(_SC_NPROCESSORS_ONLN) is the canonical online-core count
    # on glibc/musl. Stable ABI; _SC_NPROCESSORS_ONLN = 84 on glibc per
    # <unistd.h>. Hardcoded to avoid an extra header probe.
    var online = _sysconf_or(_SC_NPROCESSORS_ONLN, -1)
    if online <= 0:
        # Fall back to the process-wide snapshot's core count (NOT a live
        # `num_physical_cores()`, which is affinity-aware on Linux and would
        # report 1 from a pinned thread -- ).
        var cores = _process_physical_core_count()
        if cores < 1:
            cores = 1
        online = cores
    # Now walk per-CPU cache directories to find L1d / L2 / L3 sizes.
    # We probe cpu0 first as the canonical homogeneous shape; then if
    # multiple CPUs exist, scan all of them for the heterogeneous L1d
    # min. Containers / restricted environments often expose only cpu0,
    # which the loop handles gracefully.
    var cpu0_caches = _linux_read_cpu_cache_sizes(0)
    if cpu0_caches.l1d <= 0 and cpu0_caches.l2 <= 0:
        # sysfs entirely unavailable — print warning + return defaults.
        print(
            "komira: warning: detect_hardware_profile() — sysfs cache",
            "info unavailable (/sys/devices/system/cpu/cpu0/cache/);",
            "falling back to conservative cache-size defaults. Common",
            "cause: a hardened container with read_only_root_filesystem",
            "or a masked /sys.",
        )
        return default_hardware_profile()
    var l1d = cpu0_caches.l1d if cpu0_caches.l1d > 0 else DEFAULT_L1D_BYTES
    var l2 = cpu0_caches.l2 if cpu0_caches.l2 > 0 else DEFAULT_L2_BYTES
    var l3 = cpu0_caches.l3  # 0 if absent — matches macOS Apple Silicon
    var cache_line = (
        cpu0_caches.line_bytes
        if cpu0_caches.line_bytes > 0
        else DEFAULT_CACHE_LINE
    )
    # Heterogeneous L1d min — scan every CPU's data-L1 size and pick
    # the minimum (Alder Lake P+E, big.LITTLE on Graviton/Ampere).
    # Cap the scan at 256 CPUs to bound startup cost; production
    # machines beyond that are vanishingly rare.
    var l1d_min = l1d
    var scan_cap = online if online < 256 else 256
    var i = 1
    while i < scan_cap:
        var per_cpu = _linux_read_cpu_cache_sizes(i)
        if per_cpu.l1d > 0 and per_cpu.l1d < l1d_min:
            l1d_min = per_cpu.l1d
        i += 1
    # `MemTotal` from /proc/meminfo. If unreadable, use a conservative
    # default; available_ram falls back to total/2.
    var total_ram = _linux_read_meminfo_total_bytes()
    if total_ram <= 0:
        total_ram = DEFAULT_TOTAL_RAM
    var avail_ram = total_ram // 2
    # NUMA: walk /sys/devices/system/node/node*/. v0.4 keeps `numa_nodes
    # = 1` (single-socket assumption; multi-socket discovery deferred).
    var numa = 1
    # THE BINDING L2 INSTANCE.
    #
    # This USED to hardcode `e_core_l2_bytes = <cpu0's L2>, e_cores_per_l2 =
    # 1` because the `shared_cpu_list` parse was deferred. On a hybrid part
    # that is cpu0's PRIVATE P-core L2 with no sharing divisor at all: on
    # the 14700K it reported 2 MiB per worker where the binding E-cluster
    # share is 4 MiB / 4 cores = 1 MiB -- 2x too large, so the derived
    # morsel/grain overflowed every E-core's L2 share.
    #
    # `_linux_probe_binding_l2` now finds the L2 INSTANCE with the smallest
    # per-worker share and reports its size and worker count TOGETHER, so
    # `effective_e_core_l2_per_worker()` (= size / workers) is a share of a
    # real cache. Formula + derivation: `l2_share.mojo`.
    #
    # FAIL-SOFT: an unreadable `shared_cpu_list` (hardened container) yields
    # the UNKNOWN sentinel and we keep the pre-existing conservative
    # constants (`DEFAULT_E_CORE_L2_BYTES / DEFAULT_E_CORES_PER_L2` =
    # 4 MiB / 4 = 1 MiB per worker) rather than guessing a divisor of 1,
    # which would inflate the share on exactly that shape.
    var binding = _linux_probe_binding_l2()
    var e_l2 = DEFAULT_E_CORE_L2_BYTES
    var e_per_l2 = DEFAULT_E_CORES_PER_L2
    if binding.is_known():
        e_l2 = binding.size_bytes
        e_per_l2 = binding.workers
    return HardwareProfile(
        online,                   # physical_cores (online-cores proxy)
        online,                   # logical_cores (SMT not distinguished)
        l1d,
        l2,
        l3,
        cache_line,
        total_ram,
        avail_ram,
        numa,
        l1d_min,
        e_l2,      # e_core_l2_bytes  (the BINDING L2 instance's size)
        e_per_l2,  # e_cores_per_l2   (compute workers behind that instance)
        l2,        # p_core_l2_bytes  (cpu0's L2 -- diagnostics only)
        1,         # p_cores_per_l2   (diagnostics only)
    )

def _linux_probe_binding_l2() -> L2Instance:
    """Probe sysfs for the L2 instance with the smallest per-worker share.

    THE THIN LAYER ONLY: it reads facts and hands them to the PURE
    `derive_binding_l2_instance` (`l2_share.mojo`), which owns the formula
    and is unit-tested against fabricated hybrid / SMT / ARM / cpuset /
    4-core / unreadable topologies. Nothing here decides anything.

    Reads, per L2 INSTANCE (not per CPU -- a CPU already covered by an
    earlier instance's `shared_cpu_list` is skipped entirely):
      * `cache/index<L2>/level`              -- locate the L2 index
      * `cache/index<L2>/size`               -- the instance's capacity
      * `cache/index<L2>/shared_cpu_list`    -- who shares it
    plus one `topology/thread_siblings_list` per member CPU, which is what
    makes the worker count PHYSICAL cores rather than hardware threads. On
    this 14700K that is 11 instances x 3 + 28 sibling reads, against 28
    logical CPUs; it adds ~150 us to a `detect()` that already costs ~1 ms
    for the per-CPU L1d-min scan.

    COST NOTE (pre-existing, not introduced here): `detect()` is documented
    PURE/uncached and two call sites invoke it per query DISPATCH
    (`pipeline_compiler.mojo`, `band_producer.mojo`). Hoisting those to a
    per-session cache is the right fix and is out of this change's scope.

    The allowed set is the PROCESS-WIDE snapshot, never a live
    `sched_getaffinity` -- see `l2_share.mojo` "THE AFFINITY CONTRACT".
    `detect_hardware_profile()` is called per query dispatch, and some of
    those dispatches run on pinned worker threads.

    Returns the UNKNOWN sentinel `L2Instance(0, 0)` on non-Linux or any
    probe failure; the caller falls back conservatively.
    """
    comptime if not CompilationTarget.is_linux():
        return L2Instance(0, 0)
    var allowed = _read_allowed_cpus()
    if len(allowed) == 0:
        return L2Instance(0, 0)

    var sizes = List[Int]()
    var shared_lists = List[List[Int]]()
    var sibling_lists = List[List[Int]]()
    # The L2 `index` number is 2 on x86 (index0=L1d, index1=L1i, index2=L2)
    # but that is a convention, not an ABI. Remember the index we found on
    # the first CPU and try it first on the rest -- correct everywhere, and
    # one `level` read per CPU instead of a scan on the common shape.
    var l2_index_hint = 2
    # `covered` mirrors the pure function's instance walk so we can SKIP the
    # file reads for a CPU whose instance we have already described.
    var covered = List[Bool]()
    for _ in range(len(allowed)):
        covered.append(False)
        sizes.append(0)
        shared_lists.append(List[Int]())
        sibling_lists.append(List[Int]())

    for i in range(len(allowed)):
        if covered[i]:
            continue
        var cpu = allowed[i]
        var idx = _linux_find_l2_index(cpu, l2_index_hint)
        if idx < 0:
            covered[i] = True
            continue
        l2_index_hint = idx
        var base = _linux_cache_index_path(cpu, idx)
        sizes[i] = _parse_size_with_suffix(
            _read_small_file_to_string(base + String("/size"))
        )
        var shared = parse_cpu_list(
            _read_small_file_to_string(base + String("/shared_cpu_list"))
        )
        # Sibling lists are needed for EVERY cpu in the shared set (the pure
        # function canonicalizes each one to its physical core), so read
        # them for the members, not just for `cpu`.
        for k in range(len(shared)):
            var m = _index_of_int(allowed, shared[k])
            if m < 0:
                continue
            covered[m] = True
            if len(sibling_lists[m]) == 0:
                sibling_lists[m] = _linux_read_thread_siblings(shared[k])
        shared_lists[i] = shared^
        covered[i] = True
        if len(sibling_lists[i]) == 0:
            sibling_lists[i] = _linux_read_thread_siblings(cpu)

    return derive_binding_l2_instance(
        allowed, sizes, shared_lists, sibling_lists
    )


# =============================================================================
# Internal: sysctlbyname wrapper
# =============================================================================

def _sysctl_u64(var name: String) -> Int:
    """Read a sysctl key as a u64. Returns 0 on any failure.

    v0.3 parity: `sysctl_u64` (hardware.rs:333-352). Always uses an 8-byte
    out buffer (matching `std::mem::size_of::<u64>()`), which covers every
    hardware sysctl key we query (`hw.physicalcpu`, `hw.l1dcachesize`, etc).

    Platform: this symbol exists in darwin libc; on Linux glibc the symbol
    is absent and `external_call` will fail at runtime, causing a non-zero
    return -- `detect()` then falls back to `defaults()`. `name` is taken by
    value so the ownership / null-termination guarantee held by
    `as_c_string_slice()` is local to this frame.

    SAFETY:
      (a) `val_buf` and `len_buf` are heap-allocated via `alloc[UInt8]` and
          freed before this function returns. Their pointers stay valid for
          the entire `external_call`. Pattern mirrors
          `ffi_external_call.mojo::get_hostname` and
          `parquet/file_reader.mojo`.
      (b) `sysctlbyname(const char*, void*, size_t*, void*, size_t)` returns
          `int` (0 = success). We bind the return as `c_int` and branch on
          it. On non-zero we leak the uninitialized buffer contents by
          ignoring them and returning 0.
      (c) `val_buf` is allocated with 8 bytes and reinterpreted as a
          little-endian `UInt64` on success. The buffer is 1-byte-aligned
          at allocation but `alloc` returns at least natural alignment for
          the requested type; to be safe we build the u64 byte-by-byte
          rather than dereferencing a cast pointer (avoids any
          alignment-trap risk on aarch64).
      (d) `len_buf` holds the single `size_t` = 8 that sysctl may shrink on
          return. We ignore the post-call value.
      (e) `name` is null-terminated via `as_c_string_slice()` which
          guarantees a '\\0' byte within the referenced bytes; the pointer
          remains valid until `name` is destroyed (end of this frame, after
          the call returns).
    """
    var val_buf = alloc[UInt8](8)
    var len_buf = alloc[UInt8](8)
    # Initialize value buffer to zero so a short-write by sysctl leaves
    # deterministic bytes in the unwritten region.
    for i in range(8):
        val_buf[i] = 0
    # size_t is 8 bytes on both darwin x86_64 and darwin arm64. Write the
    # value 8 in little-endian byte order.
    len_buf[0] = 8
    for i in range(1, 8):
        len_buf[i] = 0

    var result: Int = 0
    # Linux port C.5: gate the FFI call at compile time. `sysctlbyname` is a
    # darwin libc symbol; on Linux glibc the symbol is absent and the
    # static linker fails before runtime gets a chance to fall through.
    # Both branches type-check; only the host's branch enters codegen.
    # See docs Group E (Linux compat audit) and the audit's
    # canonical CompilationTarget.is_macos() comptime-if guidance.
    comptime if CompilationTarget.is_macos():
        var name_ptr = name.as_c_string_slice().unsafe_ptr()
        # FFI-BOUNDARY: libc sysctl(3) -- darwin sysctlbyname().
        # Library: /usr/lib/libSystem.dylib (man 3 sysctl)
        # Contract:
        #   - `null_ptr` is the (newp, newlen) "no-write" sentinel per the
        #     sysctl(3) ABI. The kernel never reads through this pointer when
        #     newlen == 0, so null is explicitly permitted by POSIX.
        #   - val_buf / len_buf own heap bytes; sysctl writes into them and
        #     we free them at function exit.
        # SAFETY: the concrete static FFI origin is correct for a null-sentinel
        # that crosses a C ABI whose lifetime is not expressible in Mojo.
        var null_ptr = _ffi_null_byte()
        var ret = external_call["sysctlbyname", c_int](
            name_ptr, val_buf, len_buf, null_ptr, UInt64(0)
        )
        if ret == 0:
            # Reconstruct little-endian u64 from the 8 bytes sysctl wrote.
            var acc: UInt64 = 0
            for i in range(8):
                acc = acc | (UInt64(val_buf[i]) << (UInt64(i) * 8))
            result = Int(acc)
    else:
        # Linux / other: existing fallback contract -- function returns 0
        # on probe failure, and `detect()` falls back to `defaults()`.
        result = 0
    val_buf.free()
    len_buf.free()
    return result


def _sysctl_u64_or(var name: String, fallback: Int) -> Int:
    """Read a sysctl key; return `fallback` on failure or zero result."""
    var v = _sysctl_u64(name^)
    if v <= 0:
        return fallback
    return v


# =============================================================================
# Internal: min-over-nonzero
# =============================================================================
#
# Used by both macOS (perflevel0 vs perflevel1 vs hw.l1dcachesize) and the
# Linux per-CPU L1d scan. Zero is the sentinel for "key absent / unread"; we
# skip zeros and return the min over the surviving values. If all three are
# zero, returns the third (caller's `fallback`).
# =============================================================================


def _min_nonzero3(a: Int, b: Int, c: Int) -> Int:
    """Returns the minimum across `a`, `b`, `c` ignoring zero values.

    `c` is the fallback (typically `hw.l1dcachesize`), so when both `a`
    and `b` are zero (homogeneous silicon, no perflevel keys), the result
    equals `c`. When `c` is also zero, the function returns 0 (caller
    must handle).
    """
    var best: Int = -1
    if a > 0:
        best = a
    if b > 0:
        if best < 0 or b < best:
            best = b
    if c > 0:
        if best < 0 or c < best:
            best = c
    if best < 0:
        return 0
    return best


# =============================================================================
# Linux port — sysfs + procfs + sysconf
# =============================================================================
#
# Cache hierarchy lives under `/sys/devices/system/cpu/cpuN/cache/indexM/`,
# with the following files of interest:
#   - `level`  -> ASCII integer cache level (1, 2, or 3)
#   - `type`   -> ASCII string: "Data", "Instruction", or "Unified"
#   - `size`   -> ASCII string like "32K", "1024K", "1M", "32768", maybe
#                 followed by a trailing newline
#   - `coherency_line_size` -> ASCII integer bytes (typically 64)
#
# v0.4 SS1 reads cpu0's index0..index7 to find:
#   - data-L1 (`type==Data`, `level==1`)
#   - any-L2 / any-L3 (`level==2` or `level==3`, regardless of type:
#     server SKUs typically have unified L2/L3)
# Then for `l1d_min_bytes`, walks cpu1..cpuN (up to a 256-CPU sanity cap)
# and updates the running min if any per-CPU L1d is smaller.
#
# Container caveat: hardened K8s with `read_only_root_filesystem` blocks
# sysfs entirely. The probe is fail-soft: a missing file returns size 0,
# and `detect()` falls back to `defaults()` if cpu0's L1d AND L2 are both
# absent (a strong sysfs-missing signal).
# =============================================================================


# `_SC_NPROCESSORS_ONLN` is the canonical sysconf key for the online-CPU
# count. Stable ABI across glibc / musl: 84 on Linux glibc per <unistd.h>.
# Hardcoded to avoid an extra C header probe at build time. macOS exposes
# the same key with the same value but we never call sysconf there.
comptime _SC_NPROCESSORS_ONLN: Int = 84


def _sysconf_or(name: Int, fallback: Int) -> Int:
    """Call `sysconf(name)` and return the result (or `fallback` on
    failure). `sysconf` returns `long` (Int64 on LP64 Linux). Errors
    are signalled by returning -1.

    Platform: glibc / musl on Linux. On macOS the symbol exists but we
    do not call this from the macOS arm; on other platforms (none in
    production) the call will fail to resolve and we surface the
    fallback.

    SAFETY: scalar-in, scalar-out. No pointers cross the FFI boundary.
    """
    comptime if CompilationTarget.is_linux():
        # FFI-BOUNDARY: libc sysconf(3). Library: /lib64/libc.so.6.
        var rc = external_call["sysconf", Int64](Int64(name))
        if rc <= 0:
            return fallback
        return Int(rc)
    else:
        # Unreachable on macOS (we only call from the Linux arm) but
        # keep the else-branch for type-checker uniformity.
        return fallback


@fieldwise_init
struct _LinuxCacheSet(Copyable, ImplicitlyCopyable, Movable):
    """POD aggregate of one CPU's cache sizes. Zero means "unread/absent".

    Used internally by `_linux_read_cpu_cache_sizes` to return the
    scan result without allocating. POD-by-value (Int fields only) so
    it slots into the gap6-safe field set. `ImplicitlyCopyable` so
    `return out` doesn't require explicit `^` transfer.
    """
    var l1d: Int
    var l2: Int
    var l3: Int
    var line_bytes: Int


def _linux_read_cpu_cache_sizes(cpu_index: Int) -> _LinuxCacheSet:
    """Walk one CPU's cache index directories and identify the L1d, L2,
    L3, and cache-line sizes.

    Returns a `_LinuxCacheSet` with zeros for any cache level not found.
    The function reads up to 8 cache indices per CPU (typical chips
    have 4; the 8 cap absorbs unusual layouts without unbounded I/O).
    """
    var out = _LinuxCacheSet(0, 0, 0, 0)
    var index = 0
    while index < 8:
        var base = String("/sys/devices/system/cpu/cpu")
        base += String(cpu_index)
        base += String("/cache/index")
        base += String(index)
        # Read `level` (1/2/3) and `type` (Data / Instruction / Unified).
        var level_path = base + String("/level")
        var level_str = _read_small_file_to_string(level_path^)
        if level_str.byte_length() == 0:
            # Out of indices for this CPU.
            break
        var level = _parse_decimal_int(level_str)
        var type_path = base + String("/type")
        var type_str = _read_small_file_to_string(type_path^)
        var size_path = base + String("/size")
        var size_str = _read_small_file_to_string(size_path^)
        var size_bytes = _parse_size_with_suffix(size_str)
        # cache-line size lives at this index too.
        if out.line_bytes == 0:
            var line_path = base + String("/coherency_line_size")
            var line_str = _read_small_file_to_string(line_path^)
            var line = _parse_decimal_int(line_str)
            if line > 0:
                out.line_bytes = line
        # Classify by (level, type).
        if level == 1:
            # Match "Data" exactly. Instruction L1 has the same size on
            # most modern chips but we want the data half specifically.
            if _starts_with(type_str, String("Data")):
                if out.l1d == 0 or size_bytes < out.l1d:
                    out.l1d = size_bytes
        elif level == 2:
            # L2 is usually Unified on server SKUs; accept any type at
            # this level.
            if out.l2 == 0 or size_bytes > out.l2:
                out.l2 = size_bytes
        elif level == 3:
            if out.l3 == 0 or size_bytes > out.l3:
                out.l3 = size_bytes
        index += 1
    return out


# -----------------------------------------------------------------------------
# Binding-L2-instance probe helpers (feed the PURE derivation in l2_share.mojo)
# -----------------------------------------------------------------------------


def _linux_cache_index_path(cpu: Int, index: Int) -> String:
    """`/sys/devices/system/cpu/cpu<cpu>/cache/index<index>`."""
    var p = String("/sys/devices/system/cpu/cpu")
    p += String(cpu)
    p += String("/cache/index")
    p += String(index)
    return p^


def _linux_find_l2_index(cpu: Int, hint: Int) -> Int:
    """The `cache/index<N>` number holding this CPU's level-2 cache.

    Tries `hint` first (index 2 on x86, and identical across the CPUs of one
    machine), then scans 0..7. Returns -1 when no level-2 index is readable
    (hardened container, or a CPU with no L2 exposed).
    """
    if hint >= 0 and _linux_cache_level_at(cpu, hint) == 2:
        return hint
    for idx in range(8):
        if idx == hint:
            continue
        if _linux_cache_level_at(cpu, idx) == 2:
            return idx
    return -1


def _linux_cache_level_at(cpu: Int, index: Int) -> Int:
    """The `level` file at `cpu`'s cache index `index`; 0 when unreadable."""
    var path = _linux_cache_index_path(cpu, index) + String("/level")
    return _parse_decimal_int(_read_small_file_to_string(path^))


def _linux_read_thread_siblings(cpu: Int) -> List[Int]:
    """`cpu`'s `topology/thread_siblings_list`, expanded. EMPTY on failure --
    the pure derivation then treats the CPU as its own physical core, which is
    the no-SMT shape and the only reading that cannot inflate the share."""
    var path = String("/sys/devices/system/cpu/cpu")
    path += String(cpu)
    path += String("/topology/thread_siblings_list")
    return parse_cpu_list(_read_small_file_to_string(path^))


def _index_of_int(xs: List[Int], v: Int) -> Int:
    for i in range(len(xs)):
        if xs[i] == v:
            return i
    return -1


def _linux_read_meminfo_total_bytes() -> Int:
    """Read `MemTotal` from `/proc/meminfo` and return bytes (the file
    reports kibibytes). Returns 0 on failure.

    `/proc/meminfo` is a few hundred bytes — read up to 4 KB into a
    buffer, scan line-by-line for "MemTotal: <n> kB", parse `n`.
    """
    var path = String("/proc/meminfo")
    var contents = _read_small_file_to_string(path^)
    var n_bytes = contents.byte_length()
    if n_bytes == 0:
        return 0
    var bs = contents.as_bytes()
    # Linear scan for "MemTotal:". The label is line-anchored at offset 0
    # on Linux 2.6+ but we don't depend on that.
    var pos = _find_substring_bytes(bs, "MemTotal:")
    if pos < 0:
        return 0
    var key_len = 9  # len("MemTotal:")
    var i = pos + key_len
    # Skip spaces.
    while i < n_bytes and (Int(bs[i]) == _SPACE or Int(bs[i]) == _TAB):
        i += 1
    # Parse decimal digits.
    var kb = 0
    while i < n_bytes:
        var c = Int(bs[i])
        if c >= _ZERO and c <= _NINE:
            kb = kb * 10 + (c - _ZERO)
            i += 1
        else:
            break
    if kb <= 0:
        return 0
    return kb * 1024


def _parse_size_with_suffix(s: String) -> Int:
    """Parse a sysfs cache `size` value into bytes.

    Recognizes:
      - "32"     -> 32 bytes
      - "32K"    -> 32 * 1024 bytes  (kibibytes; per Linux kernel docs)
      - "1024K"  -> 1024 * 1024 bytes
      - "1M"     -> 1024 * 1024 bytes
      - "32768"  -> 32768 bytes  (no suffix)
      - "32768\\n" -> 32768 bytes (already stripped by reader, but defensive)

    Returns 0 on parse failure.
    """
    var n_bytes = s.byte_length()
    if n_bytes == 0:
        return 0
    var n = _parse_decimal_int(s)
    if n <= 0:
        return 0
    var bs = s.as_bytes()
    # Find the suffix: first non-digit, non-whitespace character.
    var i = 0
    while i < n_bytes:
        var c = Int(bs[i])
        if (c >= _ZERO and c <= _NINE) or c == _SPACE or c == _TAB:
            i += 1
        else:
            break
    if i >= n_bytes:
        return n  # No suffix.
    var suf = Int(bs[i])
    if suf == _UPPER_K or suf == _LOWER_K:
        return n * 1024
    if suf == _UPPER_M or suf == _LOWER_M:
        return n * 1024 * 1024
    if suf == _UPPER_G or suf == _LOWER_G:
        return n * 1024 * 1024 * 1024
    if suf == _NEWLINE or suf == _CR:
        return n  # Trailing whitespace artifact, no suffix.
    # Unknown suffix; conservatively return raw bytes.
    return n


def _starts_with(s: String, prefix: String) -> Bool:
    """True iff `s` begins with `prefix` (byte-wise ASCII compare)."""
    var p_len = prefix.byte_length()
    var s_len = s.byte_length()
    if p_len > s_len:
        return False
    var sb = s.as_bytes()
    var pb = prefix.as_bytes()
    var i = 0
    while i < p_len:
        if sb[i] != pb[i]:
            return False
        i += 1
    return True
