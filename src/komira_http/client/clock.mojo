# =============================================================================
# src/komira_http/client/clock.mojo — injectable Clock + RNG
# =============================================================================
#
#
#   "An injectable test clock. The timer wheel, idle timeout,
#    connect_timeout, expect_continue_timeout, and the retry backoff
#    schedule all read time from a clock abstraction the test controls.
#    Idle-eviction is tested by ADVANCING the test clock, not by sleeping;
#    connect_timeout is tested by a ScriptedConnector that never resolves
#    and a clock advance. This is an explicit scope requirement — if
#    the clock is not injectable from day one, every eviction/timeout
#    test is slow-or-flaky forever (the single most expensive thing to
#    retrofit)."
#
# This file ships:
#   * `Clock` trait — single method `now_us(self) -> Int`.
#   * `SystemClock` — production conformer; wraps `komira_clock.now_ns`
#     (monotonic, vDSO-fast on Linux, libSystem-fast on macOS).
#   * `MockClock` — test conformer; fixed clock + `advance_us(delta)` to
#     move time without sleeping.
#   * `Rng` trait — single method `next_u64(mut self) -> UInt64`.
#   * `SystemRng` — production conformer; basic xorshift64* seeded from
#     wall clock.
#   * `DeterministicRng` — test conformer; xorshift64* seeded from a
#     caller-controlled value.
#
# Why us (microseconds), not ns:
#   * Pool idle thresholds are 30-300s; us resolution gives ~1ns of
#     accumulated rounding error per check (~12 days continuous before
#     overflow on Int63). ns would be overkill + the SystemClock has to
#     /1000 anyway.
#   * The HTTP default idle timeout is 90s; everything in the
#     pool reads time via us. Consistent unit at the boundary.
#
# Pointer discipline:
#   * ZERO UnsafePointer in any signature.
#   * ZERO wildcard origins.
#   * ZERO `unsafe_from_address`.
#   * ZERO `take_pointee`.
#   * ZERO ArcPointer introduced here.
#   * ZERO additive parallel API (these are NEW traits, not migrations).
# =============================================================================

from komira_clock import now_ns as _system_now_ns


# =============================================================================
# §1 — Clock trait
# =============================================================================
#
# "the test clock is INJECTABLE — every time-reading site in
# the client reads through this trait, not a free function." The pool's
# checkin records `last_used_us = clock.now_us()`; eviction compares
# against `clock.now_us()`. Tests inject a MockClock and advance.


trait Clock(Movable, Deinitable):
    """Injectable monotonic clock.

    Conformers MUST provide a microsecond-precision monotonic clock.
    `now_us` is monotonically non-decreasing across all calls on the
    same Clock instance (system clocks via vDSO / libSystem; mock
    clocks because `advance_us` is the only way to move time forward).

    The HTTP client pool consumes Clock via the `mut self` checkout /
    checkin / evict_idle hot path. SystemClock has zero internal state
    and a `self` no-op for the const-self/mut-self distinction; MockClock
    holds a mutable `_now_us: Int` cell that `advance_us` increments.

    Why not a free function: deterministic tests need to STOP time
    advancing while a code path runs (e.g. a `MockClock` that returns
    the SAME value across two consecutive checkout-then-evict calls so
    the eviction-window arithmetic is exact). A free `now_us()` can't
    be stopped. The trait is the single integration point.
    """

    def now_us(mut self) -> Int:
        """Current monotonic time in microseconds since an unspecified
        epoch. Non-decreasing across consecutive calls on the same
        conformer instance.

        amendment: changed from `read self` to `mut self` so
        test conformers (like AutoAdvancingClock) can mutate internal
        state per-call to deterministically simulate elapsed time
        without sleep. SystemClock + MockClock production conformers
        do not require mutation on `now_us` (their state advances via
        external means: SystemClock reads the OS clock; MockClock is
        advanced via `advance_us`). This change is backward-compatible
        for the production conformers but enables auto-advancing test
        clocks essential for TimeoutLayer testing"""
        ...


# =============================================================================
# §2 — SystemClock — production conformer
# =============================================================================
#
# Wraps `komira_clock.now_ns`. That module is ALREADY the right
# user-space monotonic source (CLOCK_UPTIME_RAW on macOS, vDSO
# CLOCK_MONOTONIC on Linux). We divide by 1000 at the boundary.


@fieldwise_init
struct SystemClock(Clock, Copyable, Movable, Deinitable):
    """Production Clock — vDSO / libSystem monotonic now in microseconds.

    Zero per-instance state. Multiple instances of SystemClock observe
    the same monotonic timeline (the OS-level clock is process-global).

    Construction:
      * `SystemClock.new()` — fresh instance.
    """

    # Empty struct (Copyable; no fields). The Movable/Deinitable
    # default impls suffice.
    # NOTE: Mojo 1.0.0b1 requires a placeholder for empty structs; we use
    # a single zero-value UInt8 to satisfy that. The field carries no
    # semantic content.
    var _zero: UInt8

    @staticmethod
    def new() -> SystemClock:
        return SystemClock(_zero=UInt8(0))

    def now_us(mut self) -> Int:
        """Return monotonic time in microseconds.

        Reads `komira_clock.now_ns()` (UInt64 ns) and divides by
        1000. The result fits in Int63 for ~292 years of process uptime —
        safe. `mut self` per Clock trait — no internal state to
        mutate; mut is a no-op for SystemClock."""
        return Int(_system_now_ns() // UInt64(1000))


# =============================================================================
# §3 — MockClock — test conformer
# =============================================================================
#
# "Idle-eviction is tested by ADVANCING the test clock, not
# by sleeping." MockClock starts at a caller-chosen `initial_us` and
# only moves when `advance_us` is called.


struct MockClock(Clock, Movable, Deinitable):
    """Test Clock — starts at a fixed value; `advance_us` is the only
    way to move time forward.

    Construction:
      * `MockClock.new()` — starts at 0.
      * `MockClock.starting_at(us)` — starts at `us`.

    Pattern:
      var clk = MockClock.starting_at(1_000_000)         # t = 1s
      pool.checkin(conn, clk)                            # last_used = 1s
      clk.advance_us(90_000_000)                         # t = 91s
      assert pool.evict_idle(clk) == 1                   # 91 - 1 > 90s

    NOT Copyable — the internal mutable cell is single-ownership;
    cloning would let two test sites think they're advancing the same
    clock when they're not.
    """

    var _now_us: Int

    @staticmethod
    def new() -> MockClock:
        return MockClock(_now_us=0)

    @staticmethod
    def starting_at(us: Int) -> MockClock:
        return MockClock(_now_us=us)

    def __init__(out self, _now_us: Int):
        self._now_us = _now_us

    def now_us(mut self) -> Int:
        """`mut self` per Clock trait — MockClock's value
        does not advance on read (only via explicit advance_us); the
        mut is API-shape only."""
        return self._now_us

    def advance_us(mut self, delta_us: Int):
        """Move the mock clock forward by `delta_us` microseconds.

        Asserts `delta_us >= 0` — moving backward would break the
        monotonic invariant. Tests that want to test "no time passed"
        simply do not call advance_us.
        """
        debug_assert(
            delta_us >= 0,
            "MockClock.advance_us: delta_us must be non-negative",
        )
        self._now_us = self._now_us + delta_us


# =============================================================================
# §3b — ParkCoupledClock — the PROMPTNESS instrument
# =============================================================================
#
# ⭐ WHY THIS EXISTS, AND WHY `MockClock` IS NOT IT.
#
#'s clock injection makes eviction and timeout tests deterministic.
# It does NOT make PROMPTNESS assertions sound, and the difference is what this
# conformer is for. A promptness assertion is "the client did not burn the
# wall clock making no progress" — and the ONLY clocks this package had are
# both wrong for it in opposite directions:
#
#   * `MockClock` advances by an `advance_us` the TEST calls, so the elapsed
#     time it reports is whatever the test decided to say. It cannot observe
#     what the code under test actually did.
#   * The `AutoAdvancingClock` / `IncrementingClock` idiom in
#     `komira_http/tests/test_timeout_layer.mojo` advances on EVERY `now_us()`
#     CALL. That is exactly backwards: a client BUSY-POLLING in a tight loop
#     reads the clock more often than a client that parks, so the spinning
#     client is REWARDED with elapsed time it never spent, and a deadline
#     assertion written against it passes for the busy-poller and can fail for
#     the well-behaved one. A real wedge of this kind — tens of spins plus
#     one 50 ms park per cycle, hours of 504s at a steady low CPU — is a
#     busy-poll, and that is the precise failure mode an auto-advancing clock
#     cannot see.
#
# THE CONTRACT, which is Go's `testing/synctest` verbatim: "Time in a bubble
# only advances when every goroutine in the bubble is durably blocked."
# Here: `now_us()` is FROZEN, and the ONLY thing that moves it is `on_park`,
# by the timeout the parking code ACTUALLY REQUESTED.
#
#   * A loop that spins sees ZERO elapsed time, however many times it reads
#     the clock. A promptness assertion therefore CANNOT be satisfied by
#     spinning — it can only be satisfied by making progress.
#   * A loop that parks sees exactly the time it asked to wait for, so a
#     deadline test is exact rather than approximate.
#   * `park_count()` and `parked_us()` are a LEDGER of what the code did, not
#     of what the test declared, which is what makes "it parked twice for
#     50 ms" assertable at all.
#
# ⚠ ON WIRING IT TO `Reactor.park_on_fds`. This conformer is notified at the
# park SITE by the code that parks; it is deliberately NOT wired into the
# reactor. `Reactor.park_on_fds` skips every fd < 0 and
# "if EVERY fd is < 0, this returns immediately with 0"
# (`komira_async/reactor/reactor.mojo`), and `ScriptedStream.fd()` is -1 — so
# over the scripted seam the reactor park is a NO-OP that waits for nothing.
# A clock hooked to it would faithfully report the zero it waited, which is
# true and useless. The park site is where the requested timeout is known.
#
# NOT Copyable, for `MockClock`'s reason: two holders of a copy would each
# think they were advancing the same timeline.


struct ParkCoupledClock(Clock, Movable, Deinitable):
    """Test Clock whose time advances ONLY on a park, by the park timeout that
    was actually requested. See the §3b banner for why this is not `MockClock`
    and not the auto-advancing idiom.

    Construction:
      * `ParkCoupledClock.new()` — starts at 0.
      * `ParkCoupledClock.starting_at(us)`.

    Pattern:
      var clk = ParkCoupledClock.new()
      while not done:
          if try_progress():            # spinning costs NO time
              continue
          clk.on_park(50_000)           # the ONLY way time moves
      assert clk.park_count() == 2      # what the code DID
      assert clk.now_us() == 100_000
    """

    var _now_us: Int
    var _start_us: Int
    var _park_count: Int

    @staticmethod
    def new() -> ParkCoupledClock:
        return ParkCoupledClock(_now_us=0, _start_us=0, _park_count=0)

    @staticmethod
    def starting_at(us: Int) -> ParkCoupledClock:
        return ParkCoupledClock(_now_us=us, _start_us=us, _park_count=0)

    def __init__(out self, _now_us: Int, _start_us: Int, _park_count: Int):
        self._now_us = _now_us
        self._start_us = _start_us
        self._park_count = _park_count

    def now_us(mut self) -> Int:
        """FROZEN. Reading the clock does not move it — that is the whole
        point. `mut self` is the `Clock` trait's shape; nothing is mutated."""
        return self._now_us

    def on_park(mut self, timeout_us: Int) raises:
        """The ONLY way time advances: the parking code declares the timeout it
        asked the reactor to wait for, and the clock advances by exactly that.

        ⛔ REFUSES `timeout_us < 0` (the `park_on_fds` spelling for "block
        indefinitely"). In a bubble whose only time source is the park, an
        unbounded park cannot advance the clock by any finite amount, so every
        deadline after it is unreachable — that is a DEADLOCK, and reporting it
        as one is the behaviour Go's `synctest` has. Silently treating it as
        zero would convert a hung test into a passing one.

        `timeout_us == 0` is allowed and advances nothing: a poll with a zero
        timeout is a legitimate non-blocking probe, and it is COUNTED, so
        `park_count()` still sees it."""
        if timeout_us < 0:
            raise Error(
                "ParkCoupledClock.on_park: an UNBOUNDED park (timeout_us="
                + String(timeout_us)
                + ") cannot advance a park-coupled clock, so no later deadline"
                " is reachable — this is a deadlock, not a long wait. Park"
                " with a finite bound, or assert the hang directly."
            )
        self._park_count = self._park_count + 1
        self._now_us = self._now_us + timeout_us

    def park_count(self) -> Int:
        """How many times the code under test parked. A LEDGER of behaviour —
        `MockClock` cannot express this, because its advance is something the
        TEST decided rather than something the code did."""
        return self._park_count

    def parked_us(self) -> Int:
        """Total time spent parked since construction. Equals
        `now_us() - starting value` by construction: in this clock ALL elapsed
        time is parked time."""
        return self._now_us - self._start_us


# =============================================================================
# §4 — Rng trait
# =============================================================================
#
# #2: "An injectable jitter/RNG source for RetryLayer backoff,
# so retry-timing tests are deterministic." ships the trait + 2
# conformers;'s RetryLayer consumes them.


trait Rng(Movable, Deinitable):
    """Injectable RNG.

    Conformers MUST provide a 64-bit uniform random output via
    `next_u64`. Quality bar: xorshift64* or better (good enough for
    backoff jitter; NOT crypto-quality — RetryLayer's RNG is not
    security-sensitive).

    Why mut self: state-carrying RNGs advance per call (xorshift's
    internal seed updates on every `next_u64`). A const-self RNG would
    return the same value every call, defeating the purpose.
    """

    def next_u64(mut self) -> UInt64:
        """Return the next 64-bit uniform random value. Advances
        internal state."""
        ...


# =============================================================================
# §5 — SystemRng — production conformer
# =============================================================================
#
# xorshift64* — single multiplication + bit operations; ~1ns/call. Seeded
# from `komira_clock.now_ns()` so each fresh SystemRng has a
# different initial state. NOT cryptographically secure.


struct SystemRng(Rng, Movable, Deinitable):
    """Production RNG — xorshift64* seeded from monotonic clock.

    Two SystemRng instances constructed at different times have
    different state. Two constructed in the same ns get the same
    initial state (acceptable — non-crypto-quality is documented).

    Construction:
      * `SystemRng.new()` — seeded from now_ns.
      * `SystemRng.from_seed(seed)` — explicit seed (test path).
    """

    var _state: UInt64

    @staticmethod
    def new() -> SystemRng:
        # Seed from now_ns; XOR with a constant so a zero clock-read
        # (extremely unlikely) doesn't yield a degenerate xorshift state.
        var seed = _system_now_ns() ^ UInt64(0x9E3779B97F4A7C15)
        if seed == UInt64(0):
            seed = UInt64(1)
        return SystemRng(_state=seed)

    @staticmethod
    def from_seed(seed: UInt64) -> SystemRng:
        # xorshift requires a non-zero seed; substitute 1 if zero passed.
        var s = seed
        if s == UInt64(0):
            s = UInt64(1)
        return SystemRng(_state=s)

    def __init__(out self, _state: UInt64):
        self._state = _state

    def next_u64(mut self) -> UInt64:
        # xorshift64* — Marsaglia 2003 + multiplier from Vigna 2014.
        var x = self._state
        x = x ^ (x >> UInt64(12))
        x = x ^ (x << UInt64(25))
        x = x ^ (x >> UInt64(27))
        self._state = x
        return x * UInt64(0x2545F4914F6CDD1D)


# =============================================================================
# §6 — DeterministicRng — test conformer
# =============================================================================
#
# Same xorshift64* core as SystemRng but seeded from an explicit caller-
# supplied value. Two DeterministicRng(seed=N) instances produce
# byte-identical sequences. Used in retry-timing tests.


struct DeterministicRng(Rng, Movable, Deinitable):
    """Test RNG — xorshift64* with caller-controlled seed.

    Same algorithm as SystemRng but seeded explicitly. Two instances
    constructed with `DeterministicRng.from_seed(N)` produce identical
    sequences.

    Construction:
      * `DeterministicRng.from_seed(seed)` — explicit seed (must be
        non-zero; we substitute 1 if zero passed).
    """

    var _state: UInt64

    @staticmethod
    def from_seed(seed: UInt64) -> DeterministicRng:
        var s = seed
        if s == UInt64(0):
            s = UInt64(1)
        return DeterministicRng(_state=s)

    def __init__(out self, _state: UInt64):
        self._state = _state

    def next_u64(mut self) -> UInt64:
        var x = self._state
        x = x ^ (x >> UInt64(12))
        x = x ^ (x << UInt64(25))
        x = x ^ (x >> UInt64(27))
        self._state = x
        return x * UInt64(0x2545F4914F6CDD1D)
