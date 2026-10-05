# =============================================================================
# komira_anomaly.edivisive — E-DIVISIVE CHANGE POINT DETECTION.
# =============================================================================
#
# The PRIMARY detector (Matteson & James 2014, "A Nonparametric Approach for
# Multiple Change Point Analysis of Multivariate Data"). Distribution-free:
# it assumes no Gaussianity, no variance homogeneity and no uniform spacing on
# the X axis — three assumptions real benchmark measurements violate.
#
# ── THE STATISTIC ────────────────────────────────────────────────────────────
#
# For a candidate split of a segment into left X (size k) and right Y (size m),
# the ENERGY DISTANCE with exponent alpha = 1:
#
#   E(X,Y) = 2/(k*m) * SUM_{i,j} |x_i - y_j|
#          -  1/C(k,2) * SUM_{i<j} |x_i - x_j|
#          -  1/C(m,2) * SUM_{i<j} |y_i - y_j|
#
# scaled to Q = (k*m/(k+m)) * E. E is zero exactly when the two samples come
# from the same distribution, so Q is large when a split separates two
# genuinely different regimes and small when it does not.
#
# alpha is FIXED AT 1 and is not a knob. Matteson-James admits alpha in (0,2);
# at 1 the kernel is |x-y|, which needs no `pow`, is exactly representable in
# the arithmetic it is summed in, and is the value the method is almost always
# used at. A tunable exponent would be a second parameter nobody could justify
# a value for, on a method whose whole appeal is that it takes one.
#
# ── WHY THE SCAN IS O(n^2) AND NOT O(n^3) ────────────────────────────────────
#
# The three sums above share one total. Writing SL, SR, SC for the within-left,
# within-right and cross sums over UNORDERED pairs, and ST for the sum over all
# unordered pairs of the segment, ST = SL + SR + SC always. So advancing the
# split by one — moving point p from the right side to the left side — costs
# one row of distances:
#
#   SL += SUM_{i<p} |v_i - v_p|;  SR -= SUM_{j>p} |v_p - v_j|;  SC = ST-SL-SR
#
# That makes a full scan of every candidate split O(n^2) rather than the
# O(n^3) a naive recompute costs, which is what makes a 999-permutation test
# affordable on a series of a few hundred points.
#
# ── ⭐ DETERMINISM IS A DESIGN REQUIREMENT, NOT AN ACCIDENT ──────────────────
#
# A permutation test needs a random shuffle, and a detector that returns a
# different verdict for the same input on two runs is one nobody would be
# right to trust: a change-point verdict that flickers is a pager nobody
# believes.
#
# So the shuffle is driven by a SplitMix64 written out HERE rather than by any
# platform RNG, and the seed is an argument, never a clock and never entropy:
#
#   * same series + same seed  => same verdict, on every platform, forever.
#   * the seed is derived from the SERIES KEY (`seed_for_key`), so two series
#     are not shuffled in lockstep, and one series' verdict does not depend on
#     how many other series were evaluated before it.
#
# This implementation was cross-checked against an independent Python
# implementation of the same equations: on identical inputs and the same seed
# both produce the same split index, the same statistic to the last mantissa
# digit, and the same p-value. Two implementations agreeing is what makes the
# arithmetic evidence rather than one author's reading.
#
# Encapsulation: value types only, ZERO UnsafePointer, no wildcard origins.
# =============================================================================


comptime _SPLITMIX_GAMMA: UInt64 = 0x9E3779B97F4A7C15
comptime _SPLITMIX_M1: UInt64 = 0xBF58476D1CE4E5B9
comptime _SPLITMIX_M2: UInt64 = 0x94D049BB133111EB

# FNV-1a, for `seed_for_key`.
comptime _FNV_OFFSET: UInt64 = 0xCBF29CE484222325
comptime _FNV_PRIME: UInt64 = 0x00000100000001B3

# The smallest segment either side of a split may have. TWO is the ARITHMETIC
# floor — the within-segment term divides by C(k,2) = k*(k-1)/2, which is zero
# at k=1 — so this is the value below which the statistic is undefined, not a
# taste setting. `DEFAULT_MIN_SEGMENT` is the taste setting.
comptime MIN_SEGMENT_FLOOR: Int = 2

comptime DEFAULT_MIN_SEGMENT: Int = 3
comptime DEFAULT_PERMUTATIONS: Int = 999


struct SplitMix64(Copyable, Movable, Deinitable):
    """A seeded SplitMix64. Reproducible on every platform, by construction.

    Written out here rather than taken from a library because the whole value
    of the permutation test is that its answer is a function of (data, seed)
    alone — a library RNG whose algorithm changed between versions would
    silently change every verdict this package has ever issued.
    """

    var state: UInt64

    def __init__(out self, seed: UInt64):
        self.state = seed

    def next_u64(mut self) -> UInt64:
        self.state = self.state + _SPLITMIX_GAMMA
        var z = self.state
        z = (z ^ (z >> 30)) * _SPLITMIX_M1
        z = (z ^ (z >> 27)) * _SPLITMIX_M2
        return z ^ (z >> 31)

    def below(mut self, n: Int) -> Int:
        """A draw in [0, n). `n` must be positive; callers here pass i+1."""
        return Int(self.next_u64() % UInt64(n))


def seed_for_key(key: String) -> UInt64:
    """A stable seed derived from the series key by FNV-1a.

    ⚠ ORed WITH 1 SO IT IS NEVER ZERO. SplitMix64 tolerates a zero seed, but a
    zero here would mean 'the key hashed to nothing', which is worth not being
    able to express: every distinct key gets a distinct, non-degenerate stream,
    and the empty key is refused upstream by `Series.validate`.
    """
    var h = _FNV_OFFSET
    var b = key.as_bytes()
    for i in range(len(b)):
        h = (h ^ UInt64(Int(b[i]))) * _FNV_PRIME
    return h | UInt64(1)


struct Split(Copyable, Movable, Deinitable):
    """The best candidate split of one segment.

    `index` is the count of points on the LEFT, so the split sits BETWEEN
    `index-1` and `index`; `index == -1` means no admissible split exists
    (the segment is too short to place one with `min_segment` on both sides).
    """

    var index: Int
    var statistic: Float64

    def __init__(out self, index: Int, statistic: Float64):
        self.index = index
        self.statistic = statistic

    def is_admissible(self) -> Bool:
        return self.index >= 0


def best_split(v: List[Float64], min_segment: Int) -> Split:
    """The split maximising the scaled energy statistic Q. O(n^2).

    Returns an inadmissible `Split` when `len(v) < 2*min_segment`, which is the
    honest answer for a segment with nowhere to put a change point — NOT a
    statistic of zero, which would be indistinguishable from 'a split was
    evaluated and separated nothing'.
    """
    var n = len(v)
    if n < 2 * min_segment or min_segment < MIN_SEGMENT_FLOOR:
        return Split(-1, Float64(0.0))

    # ST: the sum over every unordered pair. Accumulated in one fixed order so
    # the result is bit-reproducible.
    var st = Float64(0.0)
    for i in range(n):
        for j in range(i + 1, n):
            st += abs(v[i] - v[j])

    var sl = Float64(0.0)
    var sr = st
    var best_q = Float64(0.0)
    var best_t = -1

    for tau in range(1, n):
        # Move point `p` from the right side to the left side.
        var p = tau - 1
        var add = Float64(0.0)
        for i in range(p):
            add += abs(v[i] - v[p])
        var sub = Float64(0.0)
        for j in range(p + 1, n):
            sub += abs(v[p] - v[j])
        sl += add
        sr -= sub

        var k = tau
        var m = n - tau
        if k >= min_segment and m >= min_segment:
            var sc = st - sl - sr
            var e = (
                2.0 * sc / Float64(k * m)
                - 2.0 * sl / Float64(k * (k - 1))
                - 2.0 * sr / Float64(m * (m - 1))
            )
            var q = Float64(k * m) / Float64(n) * e
            if best_t < 0 or q > best_q:
                best_q = q
                best_t = tau

    return Split(best_t, best_q)


struct ChangePointFit(Copyable, Movable, Deinitable):
    """A fitted change point and the evidence for it.

    `p_value` is the permutation p-value: the fraction of shuffles of the SAME
    values whose best split scored at least as well as the observed one. It is
    the probability of seeing this much separation if the ordering carried no
    information at all. A fit with no admissible split reports `index == -1`
    and `p_value == 1.0` — the strongest possible statement of 'no evidence'.
    """

    var index: Int
    var statistic: Float64
    var p_value: Float64
    var permutations: Int
    var before_mean: Float64
    var after_mean: Float64

    def __init__(
        out self,
        index: Int,
        statistic: Float64,
        p_value: Float64,
        permutations: Int,
        before_mean: Float64,
        after_mean: Float64,
    ):
        self.index = index
        self.statistic = statistic
        self.p_value = p_value
        self.permutations = permutations
        self.before_mean = before_mean
        self.after_mean = after_mean

    def is_fitted(self) -> Bool:
        return self.index >= 0

    def relative_shift(self) -> Float64:
        """(after - before) / |before|, or 0.0 when before is 0 or unfitted.

        The SIZE of the change, which the p-value deliberately does not carry:
        on a long enough series a 0.5% shift is arbitrarily significant, and a
        reader deciding whether to care needs the magnitude as well as the
        evidence.
        """
        if not self.is_fitted():
            return Float64(0.0)
        if self.before_mean == 0.0:
            return Float64(0.0)
        return (self.after_mean - self.before_mean) / abs(self.before_mean)


def _mean_of(v: List[Float64], lo: Int, hi: Int) -> Float64:
    """Mean of v[lo:hi). Returns 0.0 on an empty range."""
    if hi <= lo:
        return Float64(0.0)
    var s = Float64(0.0)
    for i in range(lo, hi):
        s += v[i]
    return s / Float64(hi - lo)


def fit_change_point(
    v: List[Float64], min_segment: Int, permutations: Int, seed: UInt64
) -> ChangePointFit:
    """Fit the single best change point and test it by permutation.

    ⚠ THE p-VALUE USES THE (1+ge)/(1+P) FORM, NOT ge/P. The observed ordering
    is itself one of the arrangements under the null, so including it is what
    makes the test VALID rather than anti-conservative: ge/P can return exactly
    0, claiming a certainty no finite permutation test can produce. With
    P = 999 the smallest reportable p is 0.001, and that is a true floor, not a
    rounding.
    """
    var obs = best_split(v, min_segment)
    if not obs.is_admissible():
        return ChangePointFit(
            -1, Float64(0.0), Float64(1.0), permutations,
            Float64(0.0), Float64(0.0),
        )

    var ge = 0
    if permutations > 0:
        var rng = SplitMix64(seed)
        var w = v.copy()
        for _p in range(permutations):
            # Fisher-Yates, descending. Every permutation is equally likely and
            # the sequence is a pure function of the seed.
            for i in range(len(w) - 1, 0, -1):
                var j = rng.below(i + 1)
                var tmp = w[i]
                w[i] = w[j]
                w[j] = tmp
            if best_split(w, min_segment).statistic >= obs.statistic:
                ge += 1

    var p = Float64(1 + ge) / Float64(1 + permutations)
    return ChangePointFit(
        obs.index,
        obs.statistic,
        p,
        permutations,
        _mean_of(v, 0, obs.index),
        _mean_of(v, obs.index, len(v)),
    )
