# =============================================================================
# Counters -- OS-level performance counters
# =============================================================================
#
# Captures OS-level performance metrics via getrusage(RUSAGE_SELF) for
# profiling pipeline phases:
#   * Voluntary / involuntary context switches
#   * Major page faults
#   * Peak RSS (resident set size)
#   * User / system CPU time
#
# Usage pattern:
#   var before = Counters.now()
#   # ... pipeline phase ...
#   var after = Counters.now()
#   var delta = after.delta_from(before)
#   print(delta)
#
# Platform support:
#   * macOS: `ru_maxrss` from getrusage already reports bytes.
#   * Linux: `ru_maxrss` reports KB, so it is multiplied by 1024 under
#     `comptime if CompilationTarget.is_linux()`. Both branches type-check and
#     only the host's branch enters codegen.
#
# Field offsets (`OFF_MAXRSS=32`, `OFF_NVCSW=128`, `OFF_NIVCSW=136`) are the
# same on Linux glibc x86_64 LP64 and macOS LP64; only the unit conversion
# differs.
# =============================================================================

from std.sys.info import CompilationTarget
from std.ffi import external_call, c_int
from std.memory import UnsafePointer, alloc


# getrusage(RUSAGE_SELF, ...) -- POSIX constant.
comptime RUSAGE_SELF: Int = 0

# Size of struct rusage on macOS arm64/x86_64: 18 * 8 = 144 bytes.
# Fields are all longs (8 bytes each on LP64 macOS).
comptime RUSAGE_SIZE_BYTES: Int = 144

# Field offsets within struct rusage (macOS LP64 ABI).
# struct timeval { long tv_sec; long tv_usec; }
# struct rusage {
#   timeval ru_utime;       // offset 0   (user time)
#   timeval ru_stime;       // offset 16  (system time)
#   long ru_maxrss;         // offset 32
#   long ru_ixrss;          // offset 40
#   long ru_idrss;          // offset 48
#   long ru_isrss;          // offset 56
#   long ru_minflt;         // offset 64
#   long ru_majflt;         // offset 72
#   long ru_nswap;          // offset 80
#   long ru_inblock;        // offset 88
#   long ru_oublock;        // offset 96
#   long ru_msgsnd;         // offset 104
#   long ru_msgrcv;         // offset 112
#   long ru_nsignals;       // offset 120
#   long ru_nvcsw;          // offset 128 (voluntary ctx switches)
#   long ru_nivcsw;         // offset 136 (involuntary ctx switches)
# }
comptime OFF_UTIME_SEC: Int = 0
comptime OFF_UTIME_USEC: Int = 8
comptime OFF_STIME_SEC: Int = 16
comptime OFF_STIME_USEC: Int = 24
comptime OFF_MAXRSS: Int = 32
comptime OFF_MINFLT: Int = 64
comptime OFF_MAJFLT: Int = 72
comptime OFF_NVCSW: Int = 128
comptime OFF_NIVCSW: Int = 136


# =============================================================================
# Counters
# =============================================================================

struct Counters(Copyable, Movable, Writable):
    """Snapshot of OS-level performance counters."""

    var voluntary_ctx_switches: Int
    var involuntary_ctx_switches: Int
    var major_page_faults: Int
    var minor_page_faults: Int
    """Minor faults of the process (`ru_minflt`); not in the printed form."""
    var peak_rss_bytes: Int
    var user_time_us: Int
    var system_time_us: Int

    # --- Constructors --------------------------------------------------------

    def __init__(out self):
        """Zero-initialized counters."""
        self.voluntary_ctx_switches = 0
        self.involuntary_ctx_switches = 0
        self.major_page_faults = 0
        self.minor_page_faults = 0
        self.peak_rss_bytes = 0
        self.user_time_us = 0
        self.system_time_us = 0

    def __init__(
        out self,
        voluntary_ctx_switches: Int,
        involuntary_ctx_switches: Int,
        major_page_faults: Int,
        peak_rss_bytes: Int,
        user_time_us: Int,
        system_time_us: Int,
        minor_page_faults: Int = 0,
    ):
        self.voluntary_ctx_switches = voluntary_ctx_switches
        self.involuntary_ctx_switches = involuntary_ctx_switches
        self.major_page_faults = major_page_faults
        self.peak_rss_bytes = peak_rss_bytes
        self.user_time_us = user_time_us
        self.system_time_us = system_time_us
        self.minor_page_faults = minor_page_faults

    # --- Capture current state -----------------------------------------------

    @staticmethod
    def now() -> Counters:
        """Capture current OS counters via getrusage(RUSAGE_SELF).

        SAFETY:
          `ru_buf` is a heap-allocated 144-byte buffer passed to getrusage.
          It is freed before this function returns. The buffer is large
          enough for struct rusage on macOS LP64 (18 * 8 = 144 bytes).
          Fields are read as little-endian Int64 at fixed ABI offsets.
        """
        var ru_buf = alloc[UInt8](RUSAGE_SIZE_BYTES)
        # Zero-fill to ensure deterministic reads on failure.
        for i in range(RUSAGE_SIZE_BYTES):
            ru_buf[i] = 0

        var ret = external_call["getrusage", c_int](
            c_int(RUSAGE_SELF), ru_buf
        )

        var result = Counters()
        if ret == 0:
            var utime_sec = _read_i64(ru_buf, OFF_UTIME_SEC)
            var utime_usec = _read_i64(ru_buf, OFF_UTIME_USEC)
            var stime_sec = _read_i64(ru_buf, OFF_STIME_SEC)
            var stime_usec = _read_i64(ru_buf, OFF_STIME_USEC)

            result.voluntary_ctx_switches = _read_i64(ru_buf, OFF_NVCSW)
            result.involuntary_ctx_switches = _read_i64(ru_buf, OFF_NIVCSW)
            result.major_page_faults = _read_i64(ru_buf, OFF_MAJFLT)
            result.minor_page_faults = _read_i64(ru_buf, OFF_MINFLT)
            # ru_maxrss unit differs by platform: bytes on Darwin, KB on
            # Linux (glibc). Both branches type-check; only the host's
            # branch enters codegen.
            var raw_maxrss = _read_i64(ru_buf, OFF_MAXRSS)
            comptime if CompilationTarget.is_linux():
                result.peak_rss_bytes = raw_maxrss * 1024
            else:
                result.peak_rss_bytes = raw_maxrss
            result.user_time_us = utime_sec * 1_000_000 + utime_usec
            result.system_time_us = stime_sec * 1_000_000 + stime_usec

        ru_buf.free()
        return result^

    # --- Delta computation ---------------------------------------------------

    def delta_from(self, before: Counters) -> Counters:
        """Compute delta from a previous snapshot.

        Peak RSS is absolute (the later snapshot's value), not a difference.
        """
        return Counters(
            self.voluntary_ctx_switches - before.voluntary_ctx_switches,
            self.involuntary_ctx_switches - before.involuntary_ctx_switches,
            self.major_page_faults - before.major_page_faults,
            self.peak_rss_bytes,  # peak is absolute, not delta
            self.user_time_us - before.user_time_us,
            self.system_time_us - before.system_time_us,
            self.minor_page_faults - before.minor_page_faults,
        )

    # --- Writable ------------------------------------------------------------

    def write_to[W: Writer](self, mut writer: W):
        writer.write(
            "Counters(vol_csw=",
            self.voluntary_ctx_switches,
            ", invol_csw=",
            self.involuntary_ctx_switches,
            ", maj_flt=",
            self.major_page_faults,
            ", peak_rss=",
            self.peak_rss_bytes,
            ", user_us=",
            self.user_time_us,
            ", sys_us=",
            self.system_time_us,
            ")",
        )


# =============================================================================
# Internal: read a little-endian Int64 from a byte buffer
# =============================================================================

@always_inline
def _read_i64(buf: UnsafePointer[UInt8, _], offset: Int) -> Int:
    """Read an 8-byte little-endian signed integer from buf + offset.

    SAFETY: Caller guarantees buf has at least offset + 8 valid bytes.
    """
    var acc: UInt64 = 0
    for i in range(8):
        acc = acc | (UInt64(buf[offset + i]) << (UInt64(i) * 8))
    return Int(acc)
