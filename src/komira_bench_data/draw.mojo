# The generators' source of numbers. Every value is a pure function of the
# seed, a stream number (one per column) and the row number: no state moves
# from one row to the next, so a row is the same whatever batch it is built in
# and in whatever order the batches are built. The mixer is SplitMix64's
# finalizer; integer wraparound on UInt64 is the design, not an accident.

comptime _GOLDEN: UInt64 = 0x9E3779B97F4A7C15
comptime _MUL1: UInt64 = 0xBF58476D1CE4E5B9
comptime _MUL2: UInt64 = 0x94D049BB133111EB
comptime _STREAM_MUL: UInt64 = 0xD1B54A32D192ED03


def mix64(x: UInt64) -> UInt64:
    """SplitMix64's output function of `x`."""
    var z = x + _GOLDEN
    z = (z ^ (z >> 30)) * _MUL1
    z = (z ^ (z >> 27)) * _MUL2
    return z ^ (z >> 31)


def draw(seed: UInt64, stream: Int, row: Int) -> UInt64:
    """64 bits that depend on all three arguments and on nothing else."""
    return mix64(mix64(seed ^ (UInt64(stream) * _STREAM_MUL)) + UInt64(row))


def draw_range(seed: UInt64, stream: Int, row: Int, n: Int) -> Int:
    """An integer in 1..n (n >= 1). The modulo bias is below 2^-31 for the
    sizes the generators accept."""
    return Int(draw(seed, stream, row) % UInt64(n)) + 1


def draw_score(seed: UInt64, stream: Int, row: Int) -> Float64:
    """A value in [0, 100] with six decimals: an integer in 0..100000000
    divided by 1e6, which is a correctly rounded division and so the same
    double on every machine."""
    return Float64(Int(draw(seed, stream, row) % UInt64(100_000_001))) / 1.0e6


def padded_id(v: Int, width: Int) -> String:
    """"id" followed by `v` in decimal, left-padded with zeros to `width`
    digits (longer numbers are not cut)."""
    var digits = String(v)
    var out = String("id")
    for _ in range(width - digits.byte_length()):
        out += "0"
    out += digits
    return out^


def plain_id(v: Int) -> String:
    """"id" followed by `v` in decimal."""
    return String("id") + String(v)


def _gcd(a: Int, b: Int) -> Int:
    var x = a
    var y = b
    while y != 0:
        var t = x % y
        x = y
        y = t
    return x


struct Bijection(Copyable, Movable):
    """A seeded one-to-one map of the row numbers 0..n-1 onto the keys 1..n:
    `(row * multiplier + offset) mod n`, with a multiplier coprime to n. A
    table that takes its key from it holds every key once, in a scattered
    order, and any row can be computed on its own."""

    var n: Int
    var multiplier: Int
    var offset: Int

    def __init__(out self, seed: UInt64, stream: Int, n: Int):
        self.n = n
        var m = Int(draw(seed, stream, 0) % UInt64(n)) | 1
        if m >= n:
            m = 1
        while _gcd(m, n) != 1:
            m += 2
            if m >= n:
                m = 1
        self.multiplier = m
        self.offset = Int(draw(seed, stream, 1) % UInt64(n))

    def key(self, row: Int) -> Int:
        """The key of row `row` (0 <= row < n), in 1..n."""
        return (row * self.multiplier + self.offset) % self.n + 1
