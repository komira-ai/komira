# Backoff caps, and the exact and bounded delays of both jitter modes under
# fixed random values.

from komira_retry import Backoff, Jitter, RetryRng, SplitMix64Rng

from std.testing import assert_equal, assert_true


struct ConstRng(RetryRng, Movable, Deinitable):
    var value: UInt64
    var calls: Int

    def __init__(out self, value: UInt64):
        self.value = value
        self.calls = 0

    def next_u64(mut self) -> UInt64:
        self.calls += 1
        return self.value


comptime _MAX_U64: UInt64 = 0xFFFFFFFFFFFFFFFF
comptime _HALF_U64: UInt64 = 0x8000000000000000


def test_caps() raises:
    var b = Backoff(initial_ms=100, multiplier=2.0, max_ms=1000)
    var expect: List[Int64] = [0, 100, 200, 400, 800, 1000, 1000]
    for n in range(7):
        assert_equal(b.cap_ms(n), expect[n], String(n))
    # Far past the cap stays at the cap (no overflow).
    assert_equal(b.cap_ms(10_000), 1000)
    var slow = Backoff(initial_ms=100, multiplier=1.5, max_ms=1000)
    assert_equal(slow.cap_ms(2), 150)
    assert_equal(slow.cap_ms(3), 225)
    # multiplier 1 is constant backoff.
    var flat = Backoff(initial_ms=250, multiplier=1.0, max_ms=250)
    assert_equal(flat.cap_ms(9), 250)


def test_full_jitter_fixed_rng() raises:
    var b = Backoff(initial_ms=100, multiplier=2.0, max_ms=1000, jitter=Jitter.full())
    for n in range(1, 7):
        var lo = ConstRng(0)
        var hi = ConstRng(_MAX_U64)
        assert_equal(b.delay_ms(n, lo), 0, String(n))
        assert_equal(b.delay_ms(n, hi), b.cap_ms(n), String(n))
    # Half way: floor(0.5 * (cap + 1)).
    var mid = ConstRng(_HALF_U64)
    assert_equal(b.delay_ms(1, mid), 50)
    assert_equal(b.delay_ms(3, mid), 200)
    assert_equal(b.delay_ms(9, mid), 500)
    assert_equal(mid.calls, 3)
    # Retry 0 is not a retry: no wait, no draw.
    var none = ConstRng(_MAX_U64)
    assert_equal(b.delay_ms(0, none), 0)
    assert_equal(none.calls, 0)


def test_band_jitter_fixed_rng() raises:
    var b = Backoff(initial_ms=100, multiplier=2.0, max_ms=1000, jitter=Jitter.band(25))
    # Retry 3: cap 400, band 100, roll = draw % 201.
    var lo = ConstRng(0)
    var at = ConstRng(100)
    var hi = ConstRng(200)
    var wrap = ConstRng(201)
    assert_equal(b.delay_ms(3, lo), 300)
    assert_equal(b.delay_ms(3, at), 400)
    assert_equal(b.delay_ms(3, hi), 500)
    assert_equal(b.delay_ms(3, wrap), 300)
    # At the cap (retry 5, cap 1000, band 250) the top is clamped to max.
    var top = ConstRng(500)
    var bottom = ConstRng(0)
    assert_equal(b.delay_ms(5, top), 1000)
    assert_equal(b.delay_ms(5, bottom), 750)
    # BAND(0), and a band that rounds to 0 ms, are exact.
    var exact = Backoff(initial_ms=100, multiplier=2.0, max_ms=1000, jitter=Jitter.band(0))
    var any = ConstRng(_MAX_U64)
    assert_equal(exact.delay_ms(4, any), 800)
    var tiny = Backoff(initial_ms=3, multiplier=1.0, max_ms=3, jitter=Jitter.band(25))
    assert_equal(tiny.delay_ms(1, any), 3)


def test_band_wider_than_cap_clamps_at_zero() raises:
    # Jitter.band refuses pct > 100, but the keyword constructor does not:
    # BAND(150) at cap 100 has band 150, so cap + roll - band reaches -50.
    # delay_ms clamps it to 0 (the header's "clamped to [0, max]") rather
    # than return a negative wait.
    var b = Backoff(initial_ms=100, multiplier=2.0, max_ms=1000, jitter=Jitter(_band_pct=150))
    # Retry 1: cap 100, band 150, roll = draw % 301, d = roll - 50.
    var lo = ConstRng(0)
    var below = ConstRng(49)
    var zero = ConstRng(50)
    var above = ConstRng(51)
    var top = ConstRng(300)
    assert_equal(b.delay_ms(1, lo), 0)
    assert_equal(b.delay_ms(1, below), 0)
    assert_equal(b.delay_ms(1, zero), 0)
    assert_equal(b.delay_ms(1, above), 1)
    assert_equal(b.delay_ms(1, top), 250)


def test_bounds_over_many_draws() raises:
    var full = Backoff(initial_ms=100, multiplier=2.0, max_ms=1000, jitter=Jitter.full())
    var band = Backoff(initial_ms=100, multiplier=2.0, max_ms=1000, jitter=Jitter.band(25))
    var rng = SplitMix64Rng(42)
    var saw_low = False
    var saw_high = False
    for i in range(4000):
        var n = 1 + i % 6
        var cap = full.cap_ms(n)
        var f = full.delay_ms(n, rng)
        assert_true(f >= 0 and f <= cap, String(f))
        var w = cap * 25 // 100
        var d = band.delay_ms(n, rng)
        assert_true(d >= cap - w and d <= min(cap + w, Int64(1000)), String(d))
        if n == 3 and d < 350:
            saw_low = True
        if n == 3 and d > 450:
            saw_high = True
    # The draws spread over the band, not one point of it.
    assert_true(saw_low and saw_high)


def test_seeded_rng_is_reproducible() raises:
    var a = SplitMix64Rng(7)
    var b = SplitMix64Rng(7)
    var c = SplitMix64Rng(8)
    var differs = False
    for _ in range(16):
        var x = a.next_u64()
        assert_equal(x, b.next_u64())
        if x != c.next_u64():
            differs = True
    assert_true(differs)


def test_splitmix64_known_answers() raises:
    # Vigna's reference splitmix64.c (prng.di.unimi.it/splitmix64.c): the
    # first outputs for seeds 0 and 1234567.
    var z = SplitMix64Rng(0)
    assert_equal(z.next_u64(), UInt64(0xE220A8397B1DCDAF))
    assert_equal(z.next_u64(), UInt64(0x6E789E6AA1B965F4))
    assert_equal(z.next_u64(), UInt64(0x06C45D188009454F))
    var s = SplitMix64Rng(1234567)
    assert_equal(s.next_u64(), UInt64(0x599ED017FB08FC85))
    assert_equal(s.next_u64(), UInt64(0x2C73F08458540FA5))
    assert_equal(s.next_u64(), UInt64(0x883EBCE5A3F27C77))


def main() raises:
    test_caps()
    test_full_jitter_fixed_rng()
    test_band_jitter_fixed_rng()
    test_band_wider_than_cap_clamps_at_zero()
    test_bounds_over_many_draws()
    test_seeded_rng_is_reproducible()
    test_splitmix64_known_answers()
    print("test_backoff: OK")
