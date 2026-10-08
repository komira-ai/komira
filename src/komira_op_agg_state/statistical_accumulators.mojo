# =============================================================================
# Statistical Accumulators — Stddev, Percentile, Covariance, Correlation
# =============================================================================
#
# Extracted from aggregate.mojo. Contains specialized accumulators for
# statistical aggregation functions.
# =============================================================================


# =============================================================================
# StddevAccumulator — Online standard deviation via Welford's algorithm
# =============================================================================


struct StddevAccumulator(Movable, Copyable):
    """Online standard deviation using Welford's algorithm.

    Tracks count, mean, and M2 (sum of squared differences from the
    running mean). Numerically stable even for large values.

    Fields:
        count: Number of values seen.
        mean: Running mean of all values seen.
        m2: Sum of squared deviations from the running mean.
    """

    var count: Int
    var mean: Float64
    var m2: Float64

    def __init__(out self, count: Int, mean: Float64, m2: Float64):
        self.count = count
        self.mean = mean
        self.m2 = m2

    @staticmethod
    def create() -> StddevAccumulator:
        """Create a new empty StddevAccumulator."""
        return StddevAccumulator(0, 0.0, 0.0)

    @always_inline
    def update(mut self, value: Float64):
        """Update with a new value using Welford's online algorithm."""
        self.count += 1
        var delta = value - self.mean
        self.mean += delta / Float64(self.count)
        var delta2 = value - self.mean
        self.m2 += delta * delta2

    def variance_pop(self) -> Float64:
        """Compute the population variance (M2 / count)."""
        if self.count == 0:
            return 0.0
        return self.m2 / Float64(self.count)

    def variance_sample(self) -> Float64:
        """Compute the sample variance (M2 / (count - 1))."""
        if self.count < 2:
            return 0.0
        return self.m2 / Float64(self.count - 1)

    def stddev_pop(self) -> Float64:
        """Compute the population standard deviation."""
        from std.math import sqrt
        return sqrt(self.variance_pop())

    def stddev_sample(self) -> Float64:
        """Compute the sample standard deviation (Bessel's correction)."""
        from std.math import sqrt
        return sqrt(self.variance_sample())


# =============================================================================
# PercentileAccumulator — Exact percentile via partial sort
# =============================================================================


struct PercentileAccumulator(Movable, Copyable):
    """Stores all values and computes exact percentile.

    Fields:
        values: All values collected so far.
        percentile: The target percentile (0.0 to 1.0).
    """

    var values: List[Float64]
    var percentile: Float64

    def __init__(out self, var values: List[Float64], percentile: Float64):
        self.values = values^
        self.percentile = percentile

    @staticmethod
    def create(percentile: Float64) -> PercentileAccumulator:
        """Create a new empty PercentileAccumulator for the given percentile."""
        return PercentileAccumulator(List[Float64](), percentile)

    @always_inline
    def insert(mut self, value: Float64):
        """Add a value to the accumulator."""
        self.values.append(value)

    def result(self) raises -> Float64:
        """NEAREST-RANK percentile under DuckDB's NaN-last TOTAL order.

        ⛔ THIS IS A `quantile_disc`, NOT AN INTERPOLATED PERCENTILE AND NOT
        DuckDB `quantile_cont`. `idx = ceil(p*n) - 1` with no interpolation, so
        `percentile(0.5)` of [1,2,3,4] is 2.0 where DuckDB's `median` says
        2.5. That is a DELIBERATE, ASSERTED contract
        (`komira_sdk/tests/test_display_stats.mojo`: "P25 with nearest-rank:
        ceil(0.25 * 8) = 2, so index 1 -> value 2"), left alone here on
        purpose — see `test_percentile_accumulator_nan_total_order.mojo` P6.
        The interpolated kernel is `PercentileAcc`
        (`columnar_acc_agg.mojo:86`), which is a DIFFERENT struct with a
        DIFFERENT NaN policy; do not unify them on the strength of the name.

        ⭐ WHAT CHANGED (2026-09-15): this sorted with a raw `sorted[j] > key`,
        which is FALSE for every comparison involving NaN. A NaN key never
        shifted, and a NaN landing at `sorted[0]` stopped every later
        insertion at `j == 0` and made the whole sort a NO-OP — so the answer
        was an artifact of INSERTION ORDER. Same mechanism, byte for byte, as
        the two capped AGG_MEDIAN finalize bodies fixed in the same change.

        THE ORDER: NaN is the LARGEST value, so the sorted array is
        [<k non-NaN ascending>, <n-k NaNs>]. The nearest-rank index is taken
        against the FULL n (NaN is COUNTED, not skipped — matching DuckDB,
        and matching what `insert` already did by appending unconditionally);
        an index inside the prefix yields that non-NaN value, an index at or
        past it yields NaN, which is the correct order statistic.
        """
        var n = len(self.values)
        if n == 0:
            raise Error("PercentileAccumulator.result: no values")

        # Compact the non-NaN values into sorted[0:k]. `k <= i` at every step,
        # so the write never clobbers a slot not yet read.
        var sorted = self.values.copy()
        var k = 0
        for i in range(n):
            var v = sorted[i]
            if v == v:
                sorted[k] = v
                k += 1

        # sorted[0:k] holds no NaN, so `>` IS a strict weak ordering on it and
        # this insertion sort is inside its own contract.
        for i in range(1, k):
            var key = sorted[i]
            var j = i - 1
            while j >= 0 and sorted[j] > key:
                sorted[j + 1] = sorted[j]
                j -= 1
            sorted[j + 1] = key

        var raw_idx = self.percentile * Float64(n)
        var idx = Int(raw_idx)
        if Float64(idx) < raw_idx:
            idx += 1
        idx -= 1
        if idx < 0:
            idx = 0
        if idx >= n:
            idx = n - 1

        if idx >= k:
            # The order statistic lands among the NaNs (covers the all-NaN
            # group, where k == 0, without a special case).
            return Float64(0.0) / Float64(0.0)
        return sorted[idx]


# =============================================================================
# CovarianceAccumulator — Online covariance using Welford's co-moment
# =============================================================================


struct CovarianceAccumulator(Movable, Copyable):
    """Online covariance using Welford's co-moment algorithm.

    Fields:
        count: Number of (x, y) pairs seen.
        mean_x: Running mean of x values.
        mean_y: Running mean of y values.
        co_moment: Running co-moment C = sum((xi - mean_x) * (yi - mean_y)).
    """

    var count: Int
    var mean_x: Float64
    var mean_y: Float64
    var co_moment: Float64

    def __init__(out self, count: Int, mean_x: Float64, mean_y: Float64, co_moment: Float64):
        self.count = count
        self.mean_x = mean_x
        self.mean_y = mean_y
        self.co_moment = co_moment

    @staticmethod
    def create() -> CovarianceAccumulator:
        """Create a new empty CovarianceAccumulator."""
        return CovarianceAccumulator(0, 0.0, 0.0, 0.0)

    @always_inline
    def update(mut self, x: Float64, y: Float64):
        """Update with a new (x, y) pair."""
        self.count += 1
        var n = Float64(self.count)
        var dx = x - self.mean_x
        self.mean_x += dx / n
        var dy = y - self.mean_y
        self.mean_y += dy / n
        self.co_moment += dx * (y - self.mean_y)

    def covar_pop(self) -> Float64:
        """Compute the population covariance (C / n)."""
        if self.count == 0:
            return 0.0
        return self.co_moment / Float64(self.count)

    def covar_sample(self) -> Float64:
        """Compute the sample covariance (C / (n - 1))."""
        if self.count < 2:
            return 0.0
        return self.co_moment / Float64(self.count - 1)


# =============================================================================
# CorrelationAccumulator — Online Pearson correlation coefficient
# =============================================================================


struct CorrelationAccumulator(Movable, Copyable):
    """Online Pearson correlation = covar(x,y) / (stddev(x) * stddev(y)).

    Fields:
        cov: CovarianceAccumulator tracking co-moment.
        std_x: StddevAccumulator tracking variance of x.
        std_y: StddevAccumulator tracking variance of y.
    """

    var cov: CovarianceAccumulator
    var std_x: StddevAccumulator
    var std_y: StddevAccumulator

    def __init__(out self, var cov: CovarianceAccumulator, var std_x: StddevAccumulator, var std_y: StddevAccumulator):
        self.cov = cov^
        self.std_x = std_x^
        self.std_y = std_y^

    @staticmethod
    def create() -> CorrelationAccumulator:
        """Create a new empty CorrelationAccumulator."""
        return CorrelationAccumulator(
            CovarianceAccumulator.create(),
            StddevAccumulator.create(),
            StddevAccumulator.create(),
        )

    @always_inline
    def update(mut self, x: Float64, y: Float64):
        """Update with a new (x, y) pair."""
        self.cov.update(x, y)
        self.std_x.update(x)
        self.std_y.update(y)

    def correlation(self) -> Float64:
        """Compute the Pearson correlation coefficient."""
        from std.math import sqrt

        if self.cov.count < 2:
            return 0.0
        var m2x = self.std_x.m2
        var m2y = self.std_y.m2
        if m2x == 0.0 or m2y == 0.0:
            return 0.0
        return self.cov.co_moment / sqrt(m2x * m2y)
