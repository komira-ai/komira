# =============================================================================
# src/komira_http_client/tests/test_rng.mojo — Rng trait + SystemRng + DeterministicRng
# =============================================================================
# #2 — injectable RNG
# substrate for's RetryLayer backoff jitter.

from std.testing import assert_equal, assert_true

from komira_http_client.clock import DeterministicRng, SystemClock, SystemRng


def test_system_rng_nonzero_outputs() raises:
    """A fresh SystemRng produces several non-zero outputs in sequence.

    xorshift64* requires non-zero seed; SystemRng substitutes 1 if the
    clock-seed XOR yields zero. We verify the post-seed output is
    non-zero across a few calls.
    """
    var r = SystemRng.new()
    var a = r.next_u64()
    var b = r.next_u64()
    var c = r.next_u64()
    # All three should be non-zero in any non-degenerate xorshift run.
    assert_true(a != UInt64(0))
    assert_true(b != UInt64(0))
    assert_true(c != UInt64(0))
    # And distinct in any non-degenerate sequence.
    assert_true(a != b)
    assert_true(b != c)


def test_system_rng_two_instances_diverge_across_a_clock_tick() raises:
    """Two SystemRng instances seeded from DIFFERENT clock readings produce
    different output — which is the property `SystemRng`'s own docstring claims.

    ⛔ WHY NOT "TWO INSTANCES BACK TO BACK DIVERGE". Constructing the two
    instances BACK TO BACK and asserting they diverge is not "necessarily
    probabilistic" in the harmless sense. Measured on an M3 Ultra (Darwin 25.5)
    by running such a test binary 30 times: **PASS=11 FAIL=19 — a 63% failure
    rate.**

    The mechanism is the CLOCK GRANULARITY, not the RNG. `SystemRng.new()`
    seeds from `komira_clock.now_ns()`, which on macOS is
    `clock_gettime_nsec_np(CLOCK_UPTIME_RAW)` — the raw mach timer, whose
    timebase on Apple Silicon is 125/3 ns, i.e. **one tick ≈ 41.7 ns**. Two
    adjacent `SystemRng.new()` calls take far less than one tick, so they read
    the SAME value, derive the SAME seed, and produce byte-identical sequences.
    On a slower or finer-grained clock the same source passes; the test was
    measuring the host's timebase.

    ⚠ AND THE PRODUCTION CODE IS NOT AT FAULT — IT DOCUMENTS THIS EXACT CASE.
    `SystemRng`'s struct docstring, unchanged, says: "Two SystemRng instances
    constructed at different times have different state. **Two constructed in
    the same ns get the same initial state (acceptable — non-crypto-quality is
    documented)**." A back-to-back test would assert the negation of a stated,
    accepted design decision, so this one asserts the half that IS claimed: divergence across DIFFERENT clock readings.

    ⛔⛔ WHY A FLAKE IS NOT TOLERABLE HERE. `komira_http`'s tests gate its
    package, and through it every binary that links it, with no retry. A
    63%-failing test is a ~63% chance that ANY build of such a binary fails.

    ★ THE ASSERTION IS DETERMINISTIC AND STRICTLY STRONGER — the FIRST
    outputs must differ, not merely "one of the first four". That is provable
    rather than hoped for. `next_u64`'s three xorshift steps are each a
    bijection on 64 bits, and its output multiplier 0x2545F4914F6CDD1D is ODD,
    so multiplication mod 2**64 is also a bijection. Distinct state therefore
    implies distinct FIRST output, with no probability involved.

    ⚠ THE ONE COLLISION THIS CANNOT EXCLUDE, stated rather than hidden:
    `new()` maps a zero seed to 1, so readings `t = 0x9E3779B97F4A7C15` and
    `t ^ 1` both seed to 1. That needs the monotonic clock to land on one exact
    nanosecond value and is not what this test is about.
    """
    # SystemClock reads the SAME monotonic source as SystemRng.new() and lives
    # in the SAME module, so spinning on it adds no dependency edge and cannot
    # observe a different timeline (its docstring: "Multiple instances of
    # SystemClock observe the same monotonic timeline").
    #
    # It reports MICROseconds, deliberately coarser than the ns source: waiting
    # for the microsecond count to change guarantees the ns reading changed too,
    # so `b` is seeded from a strictly later tick than `a`. The wait is bounded
    # so a stopped clock fails this test rather than hanging the build.
    var a = SystemRng.new()
    var clk = SystemClock.new()
    var t_after_a = clk.now_us()
    var spins = 0
    while clk.now_us() == t_after_a:
        spins += 1
        if spins > 100_000_000:
            break
    assert_true(
        clk.now_us() != t_after_a,
        "the monotonic clock never advanced — SystemRng cannot be seeded from"
        " it and this test cannot make its claim",
    )
    var b = SystemRng.new()

    # Distinct seeds => distinct first outputs, by the bijection argument above.
    assert_true(
        a.next_u64() != b.next_u64(),
        "two SystemRng seeded from different clock readings produced the same"
        " first output",
    )


def test_system_rng_from_seed_explicit() raises:
    """SystemRng.from_seed produces a known reproducible sequence for
    the same seed (it shares the algorithm with DeterministicRng)."""
    var a = SystemRng.from_seed(UInt64(42))
    var b = SystemRng.from_seed(UInt64(42))
    assert_equal(a.next_u64(), b.next_u64())
    assert_equal(a.next_u64(), b.next_u64())


def test_system_rng_from_seed_zero_substitutes() raises:
    """from_seed(0) must NOT produce a degenerate all-zero sequence —
    the substitution to 1 keeps xorshift in a valid state."""
    var r = SystemRng.from_seed(UInt64(0))
    var a = r.next_u64()
    var b = r.next_u64()
    assert_true(a != UInt64(0))
    assert_true(b != UInt64(0))


def test_deterministic_rng_reproducible() raises:
    """: deterministic RNG for retry-timing tests. Two
    instances with the same seed produce byte-identical sequences."""
    var a = DeterministicRng.from_seed(UInt64(0xDEADBEEF))
    var b = DeterministicRng.from_seed(UInt64(0xDEADBEEF))
    var i = 0
    while i < 16:
        assert_equal(a.next_u64(), b.next_u64())
        i = i + 1


def test_deterministic_rng_diff_seed_diff_sequence() raises:
    """Different seeds produce different sequences."""
    var a = DeterministicRng.from_seed(UInt64(1))
    var b = DeterministicRng.from_seed(UInt64(2))
    var found_diff = False
    var i = 0
    while i < 4:
        if a.next_u64() != b.next_u64():
            found_diff = True
            break
        i = i + 1
    assert_true(found_diff)


def test_deterministic_rng_zero_seed_substitutes() raises:
    """from_seed(0) substitutes to 1 -> non-degenerate sequence."""
    var r = DeterministicRng.from_seed(UInt64(0))
    var a = r.next_u64()
    assert_true(a != UInt64(0))


def main() raises:
    test_system_rng_nonzero_outputs()
    test_system_rng_two_instances_diverge_across_a_clock_tick()
    test_system_rng_from_seed_explicit()
    test_system_rng_from_seed_zero_substitutes()
    test_deterministic_rng_reproducible()
    test_deterministic_rng_diff_seed_diff_sequence()
    test_deterministic_rng_zero_seed_substitutes()
    print("OK: test_rng")
