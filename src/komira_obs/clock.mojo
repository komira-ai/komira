# =============================================================================
# clock.mojo — user-space monotonic nanosecond clock for span timestamps
# =============================================================================
#
# The span hot path cannot afford a syscall per clock read:
# `time.perf_counter_ns()` costs ~25-50ns each on M-series, and with one
# open-packet timestamp + one close-packet timestamp the floor would be
# ~50-100ns per span just for clock reads, which rules out a <100ns/op span.
#
# This module exposes a single public symbol — `now_ns() -> UInt64` —
# that resolves to the cheapest user-space monotonic-ns source on the
# current platform via a comptime branch:
#
#   * macOS (osx-arm64): `clock_gettime_nsec_np(CLOCK_UPTIME_RAW)` from
#     libSystem. ~5-15ns: backed by `mach_absolute_time()` + the kernel-
#     cached timebase ratio. Performs the tick→ns conversion in
#     libSystem (faster than calling `mach_timebase_info` ourselves
#     because the libSystem helper inlines the divide). Function id 8
#     in Apple's clock-id enum (`<sys/_types/_clockid_t.h>`).
#
#   * Linux: `clock_gettime(CLOCK_MONOTONIC, &ts)` via vDSO. On x86_64
#     and aarch64 Linux this is a vDSO trampoline (no syscall;
#     ~10-15ns). `CLOCK_MONOTONIC = 1`. The vDSO stub does the
#     read-and-convert; we just multiply seconds by 1e9 and add nsec.
#
# Encapsulation rule: the FFI calls (external_call, raw stack-local
# pointer arithmetic) stay INSIDE this module. The public API
# (`now_ns`) returns a `UInt64` — never an `UnsafePointer`. Callers
# (`komira_obs.tracer`) get a single import:
#
#     from komira_obs.clock import now_ns
#
# Comptime selection means the non-target-platform branch is dead-code
# eliminated; the function inlines to a single call instruction at
# every span boundary. Both branches type-check on both platforms (this
# is the comptime-if requirement).
#
# SAFETY: every wildcard origin and stack pointer in this file is bound
# to a syscall or libSystem helper that:
#   (a) has a C ABI — Mojo ASAP destruction does not cross the call;
#   (b) does not retain the address past return — `clock_gettime` writes
#       to the timespec slot and returns, no kernel-side aliasing;
#   (c) the address is always a stack-local `InlineArray[Int64, 2]`
#       whose lifetime is bound by the caller's frame.
#
# References:
#   - Apple <sys/_types/_clockid_t.h> for CLOCK_UPTIME_RAW = 8.
#   - man 2 clock_gettime, man 7 vdso (Linux) for vDSO acceleration.
# =============================================================================

from std.ffi import external_call
from std.memory import UnsafePointer
from std.sys.info import CompilationTarget


# =============================================================================
# Linux clock id (comptime constant, matches <bits/time.h>).
# =============================================================================
# CLOCK_MONOTONIC = 1 — wall-clock monotonic, vDSO-accelerated on x86_64
# and aarch64. `CLOCK_MONOTONIC_RAW = 4` is also an option but it is NOT
# vDSO-accelerated on most kernels (forces a syscall, ~50-200ns). We
# choose `CLOCK_MONOTONIC` for the vDSO win.
comptime _CLOCK_MONOTONIC: Int32 = 1


# CLOCK_REALTIME = 0 — Unix-epoch wall clock; vDSO-accelerated on
# Linux x86_64 + aarch64 + Darwin. Subject to NTP adjustments; the
# credential-expiry use case wants the wall clock that the server's
# X-Amz-Date / `Expiration` JSON field is denominated in, so REALTIME
# is the right clock (not MONOTONIC).
comptime _CLOCK_REALTIME: Int32 = 0


# =============================================================================
# macOS clock id (comptime constant, matches <sys/_types/_clockid_t.h>).
# =============================================================================
# CLOCK_UPTIME_RAW = 8 — monotonic-since-boot, no leap-second smoothing,
# no syscall (libSystem reads `mach_absolute_time` + the cached
# timebase). ~5-15ns per call on M-series.
comptime _CLOCK_UPTIME_RAW: Int32 = 8


@always_inline
def now_ns() -> UInt64:
    """User-space monotonic nanosecond timestamp.

    macOS: `clock_gettime_nsec_np(CLOCK_UPTIME_RAW)` — direct UInt64
        return, no syscall, libSystem helper.
    Linux: `clock_gettime(CLOCK_MONOTONIC, &ts)` — vDSO-accelerated;
        seconds * 1e9 + nsec.

    Returns 0 if the platform call ever fails (extremely unlikely for
    a monotonic clock; documented as "cannot fail" on both kernels).
    """

    comptime if CompilationTarget.is_macos():
        # libSystem helper: returns nanoseconds-since-boot directly.
        # Equivalent to `mach_absolute_time() * timebase.numer /
        # timebase.denom` but inlined inside libSystem.
        # Signature: uint64_t clock_gettime_nsec_np(clockid_t clk_id);
        return external_call["clock_gettime_nsec_np", UInt64](
            _CLOCK_UPTIME_RAW
        )
    else:
        # Linux: clock_gettime(CLOCK_MONOTONIC, &ts) via vDSO.
        # struct timespec { time_t tv_sec; long tv_nsec; } — both 8
        # bytes on x86_64 / aarch64; the ABI we target. Stack-local
        # InlineArray[Int64, 2] is layout-compatible.
        # SAFETY: the timespec out-param lives in `_clock_gettime_ns`, the
        # module's single FFI shim (see its docstring for the carve-out).
        return _clock_gettime_ns(_CLOCK_MONOTONIC)


# =============================================================================
# Wall-clock helper: now_unix_ms() — milliseconds since Unix epoch.
# =============================================================================
#
# Distinct from `now_ns()` (monotonic) — this is the WALL clock that maps
# to AWS / Azure / GCP credential expiry timestamps and HTTP Date headers.
# Used by the IMDS / WebIdentity / ECS credential providers'
# `is_expired_or_near_expiry()` predicate.
#
# It always reads the real clock. A test that needs a fixed "now" passes
# the instant to the code under test explicitly; nothing here consults the
# environment.
#
# Encapsulation: this function lives in ONE source file (this one) and
# the `external_call["clock_gettime", ...]` declaration it emits is the
# SAME declaration that `now_ns()` above emits — the Linux branch
# already uses `clock_gettime`, so this file already owns the FFI
# declaration. Adding `now_unix_ms()` here adds zero new MLIR FFI
# symbols (`external_call` legalization is keyed on the symbol name +
# arg type tuple; both call sites match). All consumers MUST import
# from here.
# =============================================================================


@always_inline
def now_unix_ms() -> Int64:
    """Milliseconds since Unix epoch (wall clock).

    Reads `CLOCK_REALTIME` on Linux (vDSO-accelerated; ~15-30ns) and
    `clock_gettime` on macOS (libSystem, also fast). Returns
    `tv_sec * 1000 + tv_nsec / 1_000_000`.

    Returns `Int64(0)` if the platform call fails (extremely unlikely).
    """

    # struct timespec { time_t tv_sec; long tv_nsec; } — same ABI
    # as the monotonic path; CLOCK_REALTIME is also vDSO-accelerated.
    # macOS exposes clock_gettime(2) since 10.12 (Sierra); same ABI.
    # SAFETY: the timespec out-param lives in `_clock_gettime_ns`, this
    # module's single FFI shim (see its docstring for the carve-out).
    var _rt_ns = _clock_gettime_ns(_CLOCK_REALTIME)
    # ns -> ms.
    return Int64(_rt_ns // UInt64(1_000_000))


@always_inline
def now_unix_us() -> Int64:
    """Microseconds since Unix epoch (wall clock).

    The µs-precision sibling of `now_unix_ms()`. Reads `CLOCK_REALTIME`
    (vDSO-accelerated on Linux; libSystem `clock_gettime` on macOS) and
    returns `tv_sec * 1_000_000 + tv_nsec / 1_000`. Suited to
    materializing a server-side `UPDATE ... SET col = NOW()` in the
    µs-since-epoch unit that TIMESTAMPTZ comparisons are denominated in,
    so a written `updated_at = NOW()` is directly comparable.

    Reuses the SAME `external_call["clock_gettime", ...]` declaration as
    `now_ns()` / `now_unix_ms()` — zero new FFI symbols (legalization is
    keyed on the symbol name + arg-type tuple, which match).

    Returns `Int64(0)` if the platform call fails (extremely unlikely).
    """

    # SAFETY: the timespec out-param lives in `_clock_gettime_ns`, this
    # module's single FFI shim (see its docstring for the carve-out).
    var _rt_ns = _clock_gettime_ns(_CLOCK_REALTIME)
    # ns -> us.
    return Int64(_rt_ns // UInt64(1_000))


# =============================================================================
# thread_cpu_ns() — PER-THREAD CPU time (the OCCUPANCY axis input)
# =============================================================================
#
# WHY THIS EXISTS. A WALL measurement of a driver-serial window is only an
# UPPER BOUND on recoverable compute: the driver can be blocked — on memory, on
# a page fault, on an allocator, on a lock — rather than computing, and a
# window that is mostly blocked can make a lever look far larger than it is.
#
# So: one `CLOCK_THREAD_CPUTIME_ID` read at each point that already samples a
# wall bookend. Pairing `cpu_ns` with the `wall_ns` a bracket already measures
# makes OCCUPANCY = cpu/wall an in-band, per-bracket field instead of an
# external `perf` pass that nobody runs.
#
# CLOCK ID CHOICE. `CLOCK_THREAD_CPUTIME_ID` counts CPU time consumed by the
# CALLING THREAD only — it excludes every other thread in the process. That is
# exactly the semantics a driver-serial bracket wants: idle worker threads
# spinning in the park loop must NOT be counted, which is why
# `CLOCK_PROCESS_CPUTIME_ID` (=2) is the WRONG clock here and would report a many-fold
# occupancy on an idle-spinning pool.
#
# COST. On Linux `CLOCK_THREAD_CPUTIME_ID` is NOT vDSO-accelerated — it is a
# real syscall, ~200-600ns, roughly 20-40x `now_ns()`. That is why this helper
# must only ever be called at bracket bookends that already fire ONCE PER
# DRIVER INVOCATION (combine, finalize, a fork/barrier bookend), never per
# morsel and never per row. A per-morsel call site would be a measurable tax at
# ~10^5 morsels/rep.
#
# SAFETY: identical contract to `now_ns()`'s Linux branch above and bound by the
# same file-level FFI carve-out — a stack-local `InlineArray[Int64, 2]`
# (layout-compatible with `struct timespec` on x86_64/aarch64), written by the
# kernel and read back before the caller's frame dies. The raw pointer never
# leaves this function, so the module's public surface is a plain `UInt64`.
# =============================================================================

@always_inline
def _clock_gettime_ns(clk: Int32) -> UInt64:
    """`clock_gettime(clk, &ts)` -> `tv_sec * 1e9 + tv_nsec`. Linux only.

    THE ONE place in this module that materializes a `timespec` out-param
    pointer for the POSIX clock ABI. Every clock in this module goes through
    it, so the module has exactly one unsafe site however many clocks it
    exposes.

    SAFETY: bound by the module-level FFI carve-out. `ts` is a stack-local
    `InlineArray[Int64, 2]`, layout-compatible with `struct timespec` on
    x86_64/aarch64 (both fields 8 bytes); the kernel writes it and returns
    before this frame dies, and the pointer never escapes this function — the
    public surface of every caller is a plain `UInt64`.
    """
    var ts = Array[Int64, 2](fill=Int64(0))
    var typed_ptr = UnsafePointer(to=ts).bitcast[Int64]()
    var addr = UnsafePointer[Int64, MutUntrackedOrigin](
        unsafe_from_address=Int(typed_ptr)
    )
    _ = external_call["clock_gettime", Int32](clk, addr)
    return UInt64(ts[0]) * UInt64(1_000_000_000) + UInt64(ts[1])


# Linux <bits/time.h>: CLOCK_THREAD_CPUTIME_ID = 3.
comptime _CLOCK_THREAD_CPUTIME_ID_LINUX: Int32 = 3
# Darwin <sys/_types/_clockid_t.h>: CLOCK_THREAD_CPUTIME_ID = 16.
comptime _CLOCK_THREAD_CPUTIME_ID_DARWIN: Int32 = 16


@always_inline
def thread_cpu_ns() -> UInt64:
    """CPU nanoseconds consumed by the CALLING THREAD.

    Pair with `now_ns()` across the same bracket to get OCCUPANCY:

        var w0 = now_ns(); var c0 = thread_cpu_ns()
        ...the bracketed region...
        var wall = now_ns() - w0; var cpu = thread_cpu_ns() - c0
        # occupancy = cpu / wall; < 1.0 means the thread was BLOCKED, so
        # `wall` overstates the recoverable compute by 1/occupancy.

    Counts ONLY this thread — idle worker threads spinning elsewhere in the
    process are excluded (that is the point; see the module note on why
    `CLOCK_PROCESS_CPUTIME_ID` is the wrong clock).

    NOT vDSO-accelerated on Linux (~200-600ns, a real syscall). Call it at
    bracket bookends that fire once per driver invocation — NEVER per morsel.

    Returns 0 if the platform call fails.
    """

    comptime if CompilationTarget.is_macos():
        return external_call["clock_gettime_nsec_np", UInt64](
            _CLOCK_THREAD_CPUTIME_ID_DARWIN
        )
    else:
        return _clock_gettime_ns(_CLOCK_THREAD_CPUTIME_ID_LINUX)
