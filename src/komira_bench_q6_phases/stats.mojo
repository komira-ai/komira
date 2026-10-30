# =============================================================================
# stats -- median and quartiles of a few integer samples
# =============================================================================
#
# The probe takes n >= 5 timed runs per configuration, so it reports the
# median and the interquartile range, which one outlier does not move. A
# quartile is the linear interpolation between the closest ranks
# (h = (n - 1) * q, the usual "type 7" definition).

def sorted_copy(xs: List[Int]) -> List[Int]:
    """`xs` in ascending order (insertion sort; the samples are a handful)."""
    var out = xs.copy()
    for i in range(1, len(out)):
        var v = out[i]
        var j = i - 1
        while j >= 0 and out[j] > v:
            out[j + 1] = out[j]
            j -= 1
        out[j + 1] = v
    return out^


def quantile(xs: List[Int], q: Float64) -> Float64:
    """The `q` quantile (0 to 1) of `xs`; 0 for no samples."""
    var n = len(xs)
    if n == 0:
        return 0.0
    var s = sorted_copy(xs)
    if n == 1:
        return Float64(s[0])
    var h = Float64(n - 1) * q
    var lo = Int(h)
    if lo >= n - 1:
        return Float64(s[n - 1])
    var frac = h - Float64(lo)
    return Float64(s[lo]) + frac * Float64(s[lo + 1] - s[lo])


def median(xs: List[Int]) -> Float64:
    return quantile(xs, 0.5)


def minimum(xs: List[Int]) -> Int:
    var m = 0
    for i in range(len(xs)):
        if i == 0 or xs[i] < m:
            m = xs[i]
    return m


def maximum(xs: List[Int]) -> Int:
    var m = 0
    for i in range(len(xs)):
        if i == 0 or xs[i] > m:
            m = xs[i]
    return m
