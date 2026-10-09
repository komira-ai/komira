# =============================================================================
# komira_log.engine.calibration — raw-tick timestamp + drain-side anchor (P2a).
# =============================================================================
#
# The raw-counter timestamp model: the hot path records a RAW counter tick (no tick→ns divide); the DRAIN converts
# ticks→wall-time via a calibration anchor `(tick0, wall0_ns, tick_hz)`.
#
# P2a scope: the anchor + the convert. The periodic ~1 Hz re-anchor is a P2b
# runtime task — P2a just needs to capture an anchor and convert correctly.
#
# # The timestamp source (`read_raw_ticks`)
#
# macOS/ARM: `mach_absolute_time()` — a raw mach tick (a fixed ~24 MHz counter
#   on Apple Silicon). Takes NO args, returns UInt64 by value — NO pointer
#   crosses the FFI boundary, so this branch is pointer-free.
# Linux/x86: the deploy target reads RDTSC; the practical Mojo path is the
#   readcyclecounter intrinsic. On this pinned toolchain we delegate to the
#   `komira_clock.now_ns()` monotonic read (which keeps the Linux
#   `clock_gettime` call in a C shim, so no pointer is named here) and tag
#   the anchor's `tick_hz` as nanoseconds (1e9) so the convert is an identity
#   shift. This keeps P2a's tick math correct on both platforms with ZERO new
#   pointer site in this module (the macOS branch is pointer-free; the Linux
#   branch goes through the core clock).
#
# # Encapsulation
#
# The `CalibrationAnchor` is plain POD (three scalars). `read_raw_ticks` /
# `read_realtime_ns` return UInt64 by value. No `UnsafePointer` crosses any
# public API in this module; the only FFI is the no-arg `mach_absolute_time`
# (macOS) — confined here with a `# FFI-BOUNDARY:` note.
# =============================================================================

from std.ffi import external_call
from std.sys.info import CompilationTarget

from komira_clock import now_ns, now_unix_ms


# On Apple Silicon mach_absolute_time advances at ~24 MHz. We do NOT hardcode
# the rate — the anchor captures it empirically via two reads. On Linux the
# delegated source already returns nanoseconds, so tick_hz == 1e9 there.
comptime _NS_PER_SEC: UInt64 = UInt64(1_000_000_000)


# -----------------------------------------------------------------------------
# read_raw_ticks() — the hot-path timestamp. RAW counter tick, NO tick→ns
# divide on macOS; a monotonic-ns read on Linux (already user-space).
#
# FFI-BOUNDARY: `mach_absolute_time(void) -> uint64_t` takes no args and
# returns by value — NO pointer crosses. The Linux branch delegates to the
# core clock (no new FFI symbol here).
# -----------------------------------------------------------------------------


@always_inline
def read_raw_ticks() -> UInt64:
    comptime if CompilationTarget.is_macos():
        # SAFETY: no-arg, by-value-return libc call; no pointer crosses.
        return external_call["mach_absolute_time", UInt64]()
    else:
        # Linux deploy target: reuse the core monotonic clock (its
        # clock_gettime call lives in a C shim). Returns nanoseconds.
        return now_ns()


# -----------------------------------------------------------------------------
# read_realtime_ns() — the wall-clock component of the anchor (epoch ns).
# Reuses the core `now_unix_ms()` (CLOCK_REALTIME path) ×1e6.
# -----------------------------------------------------------------------------


def read_realtime_ns() -> UInt64:
    var ms = now_unix_ms()
    if ms < 0:
        return UInt64(0)  # cov: unreachable the realtime clock reads before 1970 only when the host clock is misset, which no test can do
    return UInt64(ms) * UInt64(1_000_000)


# -----------------------------------------------------------------------------
# The drain-side calibration anchor.
#
#   tick0    : a raw counter tick captured at anchor time.
#   wall0_ns : the wall-clock epoch-ns captured at the SAME instant.
#   tick_hz  : the counter's frequency (ticks/sec). macOS ~24e6; Linux 1e9
#              (the delegated source is already ns). Used to convert a tick
#              delta to a wall delta: `wall = wall0 + (tick - tick0)/tick_hz`.
#
# POD (three scalars). The anchor is GLOBAL (one anchor, all per-core drains
# read it) — invariant TSC / the mach counter is system-wide.
# -----------------------------------------------------------------------------


@fieldwise_init
struct CalibrationAnchor(Copyable, ImplicitlyCopyable, Movable):
    var tick0: UInt64
    var wall0_ns: UInt64
    var tick_hz: UInt64

    @always_inline
    def tick_to_wall_ns(self, tick: UInt64) -> Int64:
        """Convert a raw tick → wall-clock epoch-NANOSECONDS via the anchor.

        `wall_ns = wall0_ns + (tick - tick0) * 1e9 / tick_hz`. Handles ticks
        both before and after the anchor (signed delta) so a record captured
        just before the anchor re-read still converts sanely. This is the OTLP
        span timestamp source (start_ns / end_ns); `tick_to_wall_ms` is the
        log-line wall-MS twin (ns // 1e6)."""
        var hz = self.tick_hz if self.tick_hz != 0 else _NS_PER_SEC
        var wall_ns: Int64
        if tick >= self.tick0:
            var d = tick - self.tick0
            # (d * 1e9) / hz — do the multiply in 128-ish-safe UInt64 order.
            var delta_ns = (d // hz) * _NS_PER_SEC + (
                (d % hz) * _NS_PER_SEC
            ) // hz
            wall_ns = Int64(self.wall0_ns + delta_ns)
        else:
            var d = self.tick0 - tick
            var delta_ns = (d // hz) * _NS_PER_SEC + (
                (d % hz) * _NS_PER_SEC
            ) // hz
            wall_ns = Int64(self.wall0_ns) - Int64(delta_ns)
        if wall_ns < 0:
            wall_ns = 0
        return wall_ns

    @always_inline
    def tick_to_wall_ms(self, tick: UInt64) -> Int64:
        """Convert a raw tick → wall-clock epoch-MILLISECONDS via the anchor.

        `tick_to_wall_ns(tick) // 1e6`. The log-line wall-MS rendering source;
        spans use `tick_to_wall_ns` directly (OTLP wants nanoseconds)."""
        return self.tick_to_wall_ns(tick) // Int64(1_000_000)


# -----------------------------------------------------------------------------
# capture_anchor() — read BOTH the raw counter AND the wall clock together so
# the drain can convert. Measures tick_hz empirically only on platforms where
# the counter is not already ns; on Linux (ns source) tick_hz = 1e9 directly.
#
# P2a captures a single anchor at engine construction; P2b refreshes it ~1 Hz.
# -----------------------------------------------------------------------------


def capture_anchor() -> CalibrationAnchor:
    comptime if CompilationTarget.is_macos():
        # Capture (tick, wall) as close together as possible, then derive the
        # counter frequency from the mach timebase by sampling a known wall
        # span is overkill for P2a; instead we read the libSystem ns helper
        # alongside the raw tick to derive ticks-per-ns at capture time.
        var t_a = read_raw_ticks()
        var ns_a = now_ns()
        # tick_hz derivation: ns_a ≈ t_a * (numer/denom). For the round-trip
        # we only need a consistent (tick0, wall0, tick_hz). Derive tick_hz
        # from the ratio of the ns clock to the raw tick over a tiny busy
        # span so the conversion is self-consistent.
        var t_b = read_raw_ticks()
        var ns_b = now_ns()
        var d_tick = t_b - t_a if t_b > t_a else UInt64(1)
        var d_ns = ns_b - ns_a if ns_b > ns_a else UInt64(1)
        # ticks-per-second = d_tick / d_ns * 1e9. With a near-zero span this is
        # noisy, so fall back to the canonical ~24 MHz Apple rate when the
        # sampled span is too small to be meaningful.
        var hz: UInt64
        if d_ns >= UInt64(1000) and d_tick >= UInt64(1):
            hz = (d_tick * _NS_PER_SEC) // d_ns
        else:
            hz = UInt64(24_000_000)  # Apple Silicon CNTVCT ~24 MHz fallback.
        var wall0 = read_realtime_ns()
        return CalibrationAnchor(tick0=t_a, wall0_ns=wall0, tick_hz=hz)
    else:
        # Linux: the source is already ns. tick0/wall0 captured together;
        # tick_hz = 1e9 makes the convert an identity ns→ns shift.
        var tick0 = read_raw_ticks()
        var wall0 = read_realtime_ns()
        return CalibrationAnchor(
            tick0=tick0, wall0_ns=wall0, tick_hz=_NS_PER_SEC
        )
