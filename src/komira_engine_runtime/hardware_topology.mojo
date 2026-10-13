# =============================================================================
# HardwareTopology -- P-core / E-core split for worker_pool QoS tiering
# =============================================================================
#
# Design doc: an internal doc (v3, §1.1 + §1.2).
#
# Runtime probe of the system's physical CPU topology for the pthread-FFI-based
# worker pool. Distinct from `hardware.mojo::HardwareProfile` (which sizes
# morsels for cache) -- this module only answers "how many P-cores and
# E-cores does this box have?" so the pool can apply QoS classes per tier.
#
# macOS probe:
#   * `hw.perflevel0.physicalcpu` -> performance-core (P) count
#   * `hw.perflevel1.physicalcpu` -> efficiency-core  (E) count
#   * Fallback: `hw.physicalcpu` (all cores treated as one tier)
#
# Linux probe:
#   * Stubbed -- the full sysfs parser (`/sys/devices/system/cpu/cpu*/cpu_capacity`)
#     is tracked in backlog P0-WORKER-POOL-LINUX. For now `detect()` on Linux
#     returns a single-tier layout via `num_physical_cores()`.
#
# Callers:
#   * `worker_pool.mojo::WorkerPool.__init__` consumes `detect().num_p_cores`
#     and `num_e_cores` to size its pthread pool and pick QoS per worker.
#   * Tests may construct a `HardwareTopology(p=4, e=6)` directly to force a
#     specific layout without probing the host machine.
#
# Platform gating:
#   * Uses `comptime if CompilationTarget.is_macos()` -- both branches compile,
#     dead-code eliminated per target (matches v0.4 pattern used in other
#     FFI-adjacent modules).
# =============================================================================

# =============================================================================
# FFI-BOUNDARY: libc sysctl(3) (darwin sysctlbyname).
# =============================================================================
# The sole MutExternalOrigin in this file is the null-sentinel UnsafePointer
# passed as the (newp, newlen=0) "no-write" argument to sysctlbyname, per
# the POSIX sysctl ABI. Per-site SAFETY inline.
# =============================================================================

from std.ffi import external_call, c_int
from std.memory import UnsafePointer, alloc
from std.sys.info import CompilationTarget

# The process-wide physical-core count (snapshot taken before any in-tree thread
# pin) -- see `_detect_fallback` for why this is NOT `std.sys.num_physical_cores`.
from komira_host.cpu_topology import _process_physical_core_count


# Canonical b2 FFI origin (FFI-BOUNDARY: sysctl(3)). StaticConstantOrigin is a
# CONCRETE (non-wildcard) origin replacing the banned MutExternalOrigin; the
# sole use is the sysctl (newp, newlen)="no-write" NULL sentinel.
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


# =============================================================================
# HardwareTopology
# =============================================================================


struct HardwareTopology(Copyable, Movable, Writable):
    """Physical-CPU P/E tier layout.

    Populated once via `detect()` (runtime probe) or via the fields-ctor for
    tests. Consumers:
      * `WorkerPool.__init__(topology=...)` sizes the pool as
        `num_p_cores + num_e_cores` pthreads, with QOS_USER_INITIATED on the
        first `num_p_cores` and QOS_BACKGROUND on the rest.
      * On chips without a P/E split (older Intel, stock Linux in Wave 5),
        `num_p_cores = physical_cores`, `num_e_cores = 0`. All workers then
        run with QOS_USER_INITIATED; the QoS call is still made but has no
        tier-steering effect.

    All values are physical-core counts (not SMT/hyperthread counts) because
    the worker pool intentionally ignores SMT -- parallel scans are
    memory-bound and SMT adds contention without throughput.
    """

    var num_p_cores: Int
    var num_e_cores: Int

    # --- Constructors --------------------------------------------------------

    def __init__(out self, num_p_cores: Int, num_e_cores: Int):
        """Construct directly (test / forced-configuration path).

        Args:
            num_p_cores: Performance-core count. Must be >= 0.
            num_e_cores: Efficiency-core count. Must be >= 0.
        """
        self.num_p_cores = num_p_cores
        self.num_e_cores = num_e_cores

    # --- Derived views -------------------------------------------------------

    @always_inline
    def num_workers(self) -> Int:
        """Total thread count = p + e. Matches `WorkerPool.num_workers`."""
        return self.num_p_cores + self.num_e_cores

    # --- Detection -----------------------------------------------------------

    @staticmethod
    def detect() -> HardwareTopology:
        """Detect the current machine's P/E layout.

        macOS: probes `hw.perflevel0.physicalcpu` (P) and
               `hw.perflevel1.physicalcpu` (E). On older Intel Macs without
               heterogeneous cores, `perflevel1` is absent (returns 0) and
               we fall back to `hw.physicalcpu` as an all-P count.

        Linux / other: returns a single-tier layout via
               `std.sys.num_physical_cores()`. Full P/E detection on Linux
               is backlog P0-WORKER-POOL-LINUX (sysfs parser).
        """
        comptime if CompilationTarget.is_macos():
            return HardwareTopology._detect_macos()
        else:
            return HardwareTopology._detect_fallback()

    @staticmethod
    def _detect_macos() -> HardwareTopology:
        """macOS P/E probe via sysctl."""
        var p = _sysctl_u64(String("hw.perflevel0.physicalcpu"))
        var e = _sysctl_u64(String("hw.perflevel1.physicalcpu"))
        if p <= 0:
            # Older Intel Mac / probe failure -- fall back to hw.physicalcpu.
            var total = _sysctl_u64(String("hw.physicalcpu"))
            if total <= 0:
                # Runtime sysctl unavailable (e.g. running on Linux via Rosetta-
                # style env); let the generic fallback take over.
                return HardwareTopology._detect_fallback()
            return HardwareTopology(Int(total), 0)
        # Normal Apple Silicon path. `e` of 0 means pure-P silicon.
        return HardwareTopology(Int(p), Int(e) if e > 0 else 0)

    @staticmethod
    def _detect_fallback() -> HardwareTopology:
        """Single-tier layout for non-macOS or probe-failure paths.

        All cores are treated as P-tier. Matches Rayon/DataFusion behavior
        (use all physical cores at the same QoS).

        SOURCE OF THE COUNT. This is the arm
        EVERY Linux `HardwareTopology.detect()` takes (the P/E probe is
        macOS-only), and `EngineContext.__init__` calls it -- so this one number
        sizes the whole worker pool. It comes from the PROCESS-WIDE snapshot
        (`_process_physical_core_count()`, ) rather than a live
        `num_physical_cores()`.

        WHY, PRECISELY: `num_physical_cores()` is affinity-aware on Linux -- a
        process LAUNCHED under `taskset -c 0` gets 1 from it. Measured on this
        Mojo build the stdlib CACHES it, so a MID-process thread pin
        does not currently move it; the swap is therefore not a behaviour change
        today. It is made anyway because the correctness of a process-wide
        invariant must not rest on an undocumented stdlib caching detail: if
        that cache ever goes away, this site silently starts deriving a
        one-worker pool from whichever thread happened to ask. The snapshot
        makes the sample point explicit and shared with every other topology
        consumer.
        """
        var cores = _process_physical_core_count()
        if cores < 1:
            cores = 1
        return HardwareTopology(cores, 0)

    # --- Writable ------------------------------------------------------------

    def write_to[W: Writer](self, mut writer: W):
        writer.write(
            "HardwareTopology(P=", self.num_p_cores,
            ", E=", self.num_e_cores,
            ", total=", self.num_workers(),
            ")",
        )


# =============================================================================
# Internal: sysctlbyname wrapper
# =============================================================================
#
# Duplicated from hardware.mojo (private there). A follow-up may factor into a
# shared core module, but for Wave 5 we keep topology fully self-contained so
# reviewers can audit the FFI surface in one place.
# =============================================================================


def _sysctl_u64(var name: String) -> Int:
    """Read a sysctl key as a u64. Returns 0 on any failure.

    Platform: darwin libc. On Linux glibc the symbol is absent and the
    `external_call` dlsym lookup will fail -- this function returns 0, and
    callers should fall back to `num_physical_cores()`.

    SAFETY:
      (a) `val_buf` and `len_buf` are heap-allocated via `alloc[UInt8]` and
          freed before return. Pointers stay valid for the full call.
      (b) Return value is read little-endian byte-by-byte from `val_buf`
          (no aliasing cast, no alignment trap on arm64).
      (c) `name.as_c_string_slice()` guarantees a trailing `\\0` in the
          referenced bytes; the pointer is valid until `name` drops at
          end-of-frame (after the call returns).
    """
    var val_buf = alloc[UInt8](8)
    var len_buf = alloc[UInt8](8)
    for i in range(8):
        val_buf[i] = 0
    len_buf[0] = 8
    for i in range(1, 8):
        len_buf[i] = 0

    var result: Int = 0
    # Linux port C.5: gate the FFI call at compile time. `sysctlbyname` is a
    # darwin libc symbol; on Linux glibc the symbol is absent and the
    # static linker fails before runtime gets a chance to fall through.
    # Both branches type-check; only the host's branch enters codegen.
    comptime if CompilationTarget.is_macos():
        var name_ptr = name.as_c_string_slice().unsafe_ptr()
        # FFI-BOUNDARY: libc sysctl(3) -- darwin sysctlbyname(). See
        # engine/hardware.mojo for the full SAFETY block; same pattern.
        var null_ptr = _ffi_null_byte()
        var ret = external_call["sysctlbyname", c_int](
            name_ptr, val_buf, len_buf, null_ptr, UInt64(0)
        )
        if ret == 0:
            var acc: UInt64 = 0
            for i in range(8):
                acc = acc | (UInt64(val_buf[i]) << (UInt64(i) * 8))
            result = Int(acc)
    else:
        # Linux / other: existing fallback contract -- function returns 0
        # on probe failure; callers fall back to `num_physical_cores()`.
        result = 0
    val_buf.free()
    len_buf.free()
    return result
