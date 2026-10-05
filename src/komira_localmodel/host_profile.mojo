# =============================================================================
# komira_localmodel/host_profile.mojo
#   HostMemoryProfile: the memory facts a model-fit decision needs, probed once:
#   total RAM, VRAM (if there is a discrete GPU), whether the memory is UNIFIED
#   (Apple Silicon: the GPU shares system RAM, there is no separate VRAM pool),
#   and the platform.
# =============================================================================
#
# This is about memory CAPACITY for model fit. CPU topology and cache sizes
# (cores, L1d/L2/L3, cache line) are a different concern and live elsewhere;
# the name HostMemoryProfile says which one this is.
#
# DETECTION (callers cache the returned value):
#   macOS:
#     * total_ram  = sysctl `hw.memsize` (bytes).
#     * unified    = sysctl `hw.optional.arm64` == 1 (Apple Silicon always has
#                    unified memory: the GPU draws from the system RAM pool).
#     * vram       = 0 on unified silicon (there is no SEPARATE VRAM pool; the
#                    GPU draws from `total_ram`). The fit code treats unified
#                    memory as "the model may use up to ~total_ram for weights +
#                    KV cache", so 0 here is correct, not a gap.
#   Linux:
#     * total_ram  = `MemTotal:` from /proc/meminfo (kB -> bytes).
#     * unified    = False (a discrete GPU has its OWN VRAM pool).
#     * vram       = `nvidia-smi --query-gpu=memory.total --format=csv,noheader,
#                    nounits` -> sum of MiB across GPUs -> bytes; 0 if nvidia-smi
#                    is absent or fails (a CPU-only host: weights must fit in RAM).
#
# Both branches compile (selected by `comptime if` on the target OS). A probe
# FAILURE never crashes: it yields zeros, and the fit code then rates a variant
# RED rather than GREEN against an unknown machine.
#
# POINTERS: the sysctl FFI is confined to one private helper with a `# SAFETY:`
# block; the /proc/meminfo read uses the stdlib `FileHandle`; the nvidia-smi
# probe uses komira_supervisor's `Supervisor` spawn + drain (no raw fd handling
# here). The public surface is Ints, a Bool and a small struct; no pointer in
# any public signature.
# =============================================================================

from std.ffi import external_call, c_int
from std.io import FileHandle
from std.memory import UnsafePointer, alloc
from std.sys.info import CompilationTarget

from komira_supervisor.supervisor import Supervisor, ChildSpec


@always_inline
def _null_ptr[T: AnyType, o: Origin]() -> UnsafePointer[T, o]:
    """A NULL typed pointer with a concrete origin (UnsafePointer has no null
    constructor).

    # SAFETY: `Optional[UnsafePointer[...]]` is layout-compatible with the bare
    # pointer (modular/mojo/proposals/non-null-pointer.md); `None` is the all-zero
    # (NULL) bit pattern. Used only for NULL pointer sentinels / FFI NULL args.
    """
    var none: Optional[UnsafePointer[T, o]] = None
    return UnsafePointer(to=none).bitcast[UnsafePointer[T, o]]()[]



# -----------------------------------------------------------------------------
# Platform discriminator (a small POD enum). Carried on the profile so a
# FitResolver / a log line can name the platform without re-probing.
# -----------------------------------------------------------------------------
comptime PLATFORM_UNKNOWN: Int = 0
comptime PLATFORM_MACOS: Int = 1
comptime PLATFORM_LINUX: Int = 2


def platform_name(platform: Int) -> StaticString:
    if platform == PLATFORM_MACOS:
        return "macos"
    elif platform == PLATFORM_LINUX:
        return "linux"
    return "unknown"


# -----------------------------------------------------------------------------
# HostMemoryProfile — the memory-capacity facts. POD value type (Ints + a Bool);
# Copyable so it can be passed by value to FitResolver without lifetime plumbing.
# -----------------------------------------------------------------------------
struct HostMemoryProfile(Copyable, ImplicitlyCopyable, Movable, Writable):
    """Memory-capacity facts for model fit.

    All sizes are bytes. `detect()` probes the host once; callers CACHE the
    returned value (it does not change during a process run). The fields-ctor
    is the test seam — a fixture machine is just a `HostMemoryProfile(total_ram,
    vram, unified, platform)`.

    Fields:
      * total_ram_bytes — total system RAM.
      * vram_bytes      — discrete-GPU VRAM (0 on unified silicon / CPU-only).
      * unified_memory  — True when the GPU shares system RAM (Apple Silicon).
                          On a unified box the "GPU budget" is `total_ram_bytes`,
                          NOT `vram_bytes` (which is 0).
      * platform        — PLATFORM_MACOS / PLATFORM_LINUX / PLATFORM_UNKNOWN.

    The "memory the model may use" is a FitResolver policy, NOT a field here —
    this struct reports the raw capacity facts only.
    """

    var total_ram_bytes: Int
    var vram_bytes: Int
    var unified_memory: Bool
    var platform: Int

    def __init__(
        out self,
        total_ram_bytes: Int,
        vram_bytes: Int,
        unified_memory: Bool,
        platform: Int,
    ):
        """Construct directly (the test / fixture-machine seam)."""
        self.total_ram_bytes = total_ram_bytes
        self.vram_bytes = vram_bytes
        self.unified_memory = unified_memory
        self.platform = platform

    # --- derived views -------------------------------------------------------

    def gpu_budget_bytes(self) -> Int:
        """The bytes a GPU-resident model may draw from.

        Unified silicon: the GPU shares system RAM, so the budget is
        `total_ram_bytes`. Discrete GPU: the budget is the dedicated
        `vram_bytes`. CPU-only (no VRAM, not unified): 0 (a GPU-resident model
        cannot fit; FitResolver routes it to the RAM budget instead).
        """
        if self.unified_memory:
            return self.total_ram_bytes
        return self.vram_bytes

    def has_discrete_gpu(self) -> Bool:
        """True iff there is a separate VRAM pool (discrete GPU, not unified)."""
        return (not self.unified_memory) and self.vram_bytes > 0

    # --- detection -----------------------------------------------------------

    @staticmethod
    def detect() -> HostMemoryProfile:
        """Probe the host once. macOS -> sysctl; Linux -> /proc/meminfo +
        nvidia-smi. A probe failure yields conservative zeros (FitResolver
        rates RED rather than risk a false-GREEN against an unknown machine)."""
        comptime if CompilationTarget.is_macos():
            return HostMemoryProfile._detect_macos()
        else:
            return HostMemoryProfile._detect_linux()

    @staticmethod
    def _detect_macos() -> HostMemoryProfile:
        """macOS probe: hw.memsize + hw.optional.arm64 (unified-memory flag)."""
        var total = _sysctl_u64(String("hw.memsize"))
        var is_arm64 = _sysctl_u64(String("hw.optional.arm64"))
        # Apple Silicon ALWAYS has unified memory (GPU shares the RAM pool, no
        # separate VRAM budget). Intel Macs (is_arm64 == 0) are treated as
        # non-unified with 0 VRAM: their discrete-GPU VRAM is not probed, and
        # a 0 there is the conservative answer.
        var unified = is_arm64 == 1
        return HostMemoryProfile(
            total_ram_bytes=total,
            vram_bytes=0,
            unified_memory=unified,
            platform=PLATFORM_MACOS,
        )

    @staticmethod
    def _detect_linux() -> HostMemoryProfile:
        """Linux probe: /proc/meminfo MemTotal + nvidia-smi VRAM (0 if absent)."""
        var total = _read_meminfo_total_bytes()
        var vram = _probe_nvidia_vram_bytes()
        return HostMemoryProfile(
            total_ram_bytes=total,
            vram_bytes=vram,
            unified_memory=False,
            platform=PLATFORM_LINUX,
        )

    # --- Writable ------------------------------------------------------------

    def write_to[W: Writer](self, mut writer: W):
        writer.write(
            "HostMemoryProfile(platform=",
            platform_name(self.platform),
            ", total_ram=",
            self.total_ram_bytes,
            "B, vram=",
            self.vram_bytes,
            "B, unified=",
            self.unified_memory,
            ")",
        )


# =============================================================================
# Internal probe helpers (all FFI and I/O of this module is confined here).
# =============================================================================


def _sysctl_u64(var name: String) -> Int:
    """Read a darwin sysctl key as a u64. Returns 0 on any failure.

    On Linux glibc the symbol is absent, so the comptime gate keeps the
    `external_call` out of the Linux codegen entirely; the Linux arm returns 0
    (callers never reach here on Linux: detect() routes Linux to
    /proc/meminfo).

    SAFETY:
      (a) `val_buf` / `len_buf` are heap-allocated via `alloc[UInt8]` and freed
          before return; pointers stay valid for the full sysctl call.
      (b) The result is read little-endian byte-by-byte from `val_buf` (no
          aliasing cast, no arm64 alignment trap).
      (c) `name.as_c_string_slice()` guarantees a trailing NUL in the referenced
          bytes; the pointer is valid until `name` drops at end-of-frame (after
          the call returns).
      (d) The only untracked-origin pointer is the NULL `newp` argument
          (with newlen=0, "do not write") of the sysctl ABI, bounded to this
          call.
    """
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
        var null_ptr = _null_ptr[UInt8, MutUntrackedOrigin]()
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


def _read_meminfo_total_bytes() -> Int:
    """Parse `MemTotal:` from /proc/meminfo into bytes. Returns 0 on any failure.

    /proc/meminfo's `MemTotal:` line is in kB (`MemTotal:   65854012 kB`); we
    multiply by 1024. Reads via the safe stdlib FileHandle (no raw fd). On
    macOS /proc does not exist -> the read raises -> we return 0 (callers never
    reach here on macOS — detect() routes macOS to sysctl).
    """
    try:
        var f = FileHandle(String("/proc/meminfo"), "r")
        var content = String(f.read())
        f.close()
        return _parse_meminfo_total_kb(content) * 1024
    except:
        return 0


def _parse_meminfo_total_kb(content: String) -> Int:
    """Extract the MemTotal kB value from /proc/meminfo content (PURE — the
    unit-test seam). Returns 0 if the line is absent / malformed."""
    var lines = content.split("\n")
    for li in range(len(lines)):
        var line = String(lines[li])
        if line.startswith("MemTotal:"):
            # `MemTotal:   65854012 kB` — take the first all-digit token (the
            # parse skips the non-digit prefix, so we hand it the whole line).
            return _first_uint_token(line)
    return 0


def _first_uint_token(s: String) -> Int:
    """Parse the first run of ASCII digits in `s` into an Int (0 if none).
    Non-digit prefix is skipped; parsing stops at the first non-digit after the
    digit run. Works on the String's UTF-8 bytes (ASCII-digit comparison)."""
    var bytes = s.as_bytes()
    var acc = 0
    var seen = False
    var zero = UInt8(ord("0"))
    var nine = UInt8(ord("9"))
    for i in range(len(bytes)):
        var c = bytes[i]
        if c >= zero and c <= nine:
            acc = acc * 10 + Int(c - zero)
            seen = True
        elif seen:
            break
    return acc if seen else 0


def _probe_nvidia_vram_bytes() -> Int:
    """Sum the total VRAM across NVIDIA GPUs via nvidia-smi. 0 if absent / fails.

    Runs `nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits`
    (emits one MiB integer per GPU, one per line) as a SUPERVISED child via
    komira_supervisor, drains its stdout, and sums the MiB values * 1024*1024.
    A CPU-only box (no nvidia-smi on PATH, or the spawn fails) -> 0, which is
    correct: there is no VRAM, so a GPU-resident model cannot fit there.

    Spawns via /usr/bin/env so nvidia-smi resolves off PATH without hardcoding
    its install path (it lives in different places across driver packagings).
    """
    var spec = ChildSpec(String("/usr/bin/env"))
    spec.with_arg(String("nvidia-smi"))
    spec.with_arg(String("--query-gpu=memory.total"))
    spec.with_arg(String("--format=csv,noheader,nounits"))
    var sup = Supervisor()
    var pid = sup.spawn(spec)
    if pid <= Int32(0):
        # Spawn failed (env / nvidia-smi missing) -> CPU-only.
        return 0
    var captured = sup.drain_pipe(sup.stdout_fd())
    _ = sup.wait_exit()
    sup.close()
    return _sum_nvidia_mib_lines(captured) * 1024 * 1024


def _sum_nvidia_mib_lines(text: String) -> Int:
    """Sum the per-line MiB integers in nvidia-smi's memory.total output (PURE —
    the unit-test seam). Each non-empty line is one GPU's MiB value; a line that
    does not parse to a positive int is skipped (defensive against a header /
    error text leaking in)."""
    var total_mib = 0
    var lines = text.split("\n")
    for li in range(len(lines)):
        var line = String(lines[li])
        var v = _first_uint_token(line)
        if v > 0:
            total_mib += v
    return total_mib
