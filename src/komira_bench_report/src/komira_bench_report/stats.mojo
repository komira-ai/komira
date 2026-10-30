# The statistics of a benchmark cell: how the timings of one cell's reps turn
# into one number, and how the ratios of many cells turn into a geomean. Every
# helper is a pure function of its arguments, and refuses an input that has no
# honest answer (no values, a value that is not finite, a non-positive time)
# rather than returning a number.

from std.math import exp, isfinite, log

comptime STEADY_STATE_DEFINITION: String = (
    "first = the first run of the first sweep; steady = the median of a sweep's"
    " runs after its first, and the least of those medians over the sweeps;"
    " every run is in result.json"
)
"""What a cell's first-run and steady-state times are. This is the one place
the definition is written; the table prints it and the README quotes it. No run
is dropped from the data by it: it only says which runs make which number."""


def _require_finite(values: List[Float64], what: String) raises:
    for i in range(len(values)):
        if not isfinite(values[i]):
            raise Error(what + ": value " + String(i) + " is not finite")


def _sorted(values: List[Float64]) -> List[Float64]:
    var s = values.copy()
    for i in range(1, len(s)):
        var key = s[i]
        var j = i - 1
        while j >= 0 and s[j] > key:
            s[j + 1] = s[j]
            j -= 1
        s[j + 1] = key
    return s^


def median(values: List[Float64]) raises -> Float64:
    """The median of `values`: the middle one of an odd count, the mean of the
    two middle ones of an even count. Raises on no values or a value that is
    not finite."""
    var n = len(values)
    if n == 0:
        raise Error("median: no values")
    _require_finite(values, String("median"))
    var s = _sorted(values)
    if n % 2 == 1:
        return s[n // 2]
    return (s[n // 2 - 1] + s[n // 2]) / 2.0


def minimum(values: List[Float64]) raises -> Float64:
    """The least of `values`. Raises on no values or a value that is not
    finite."""
    if len(values) == 0:
        raise Error("minimum: no values")
    _require_finite(values, String("minimum"))
    var m = values[0]
    for i in range(1, len(values)):
        if values[i] < m:
            m = values[i]
    return m


def maximum(values: List[Float64]) raises -> Float64:
    """The greatest of `values`. Raises on no values or a value that is not
    finite."""
    if len(values) == 0:
        raise Error("maximum: no values")
    _require_finite(values, String("maximum"))
    var m = values[0]
    for i in range(1, len(values)):
        if values[i] > m:
            m = values[i]
    return m


def drop_first_rep(reps: List[Float64]) raises -> List[Float64]:
    """The timings of one sweep without its first run, as the steady-state
    statistic takes them (the run itself stays in the data). A sweep of fewer
    than two reps has nothing left to measure and is refused."""
    if len(reps) < 2:
        raise Error(
            "drop_first_rep: a sweep needs at least two reps, got "
            + String(len(reps))
        )
    var out = List[Float64]()
    for i in range(1, len(reps)):
        out.append(reps[i])
    return out^


def sweep_median(reps: List[Float64]) raises -> Float64:
    """The median of one sweep's runs after its first."""
    return median(drop_first_rep(reps))


def sweep_medians(sweeps: List[List[Float64]]) raises -> List[Float64]:
    """`sweep_median` of every sweep, in order."""
    if len(sweeps) == 0:
        raise Error("sweep_medians: no sweeps")
    var out = List[Float64]()
    for i in range(len(sweeps)):
        out.append(sweep_median(sweeps[i]))
    return out^


def min_of_sweep_medians(sweeps: List[List[Float64]]) raises -> Float64:
    """The statistic `min_of_sweep_median`: the least, over the sweeps, of each
    sweep's median of the runs after its first."""
    return minimum(sweep_medians(sweeps))


def steady_state_ms(sweeps: List[List[Float64]]) raises -> Float64:
    """The steady-state time of a cell (`STEADY_STATE_DEFINITION`): the least,
    over the sweeps, of the median of each sweep's runs after its first.
    Raises on no sweeps and on a sweep of fewer than two runs."""
    return min_of_sweep_medians(sweeps)


def first_run_ms(sweeps: List[List[Float64]]) raises -> Float64:
    """The first-run time of a cell (`STEADY_STATE_DEFINITION`): the first run
    of the first sweep, which is what a first query pays. Raises on no sweeps or
    a first sweep with no runs."""
    if len(sweeps) == 0 or len(sweeps[0]) == 0:
        raise Error("first_run_ms: no runs")
    var t = sweeps[0][0]
    if not isfinite(t):
        raise Error("first_run_ms: the first run is not finite")
    return t


def spread_pct(values: List[Float64]) raises -> Float64:
    """How far apart the least and the greatest of `values` are, as a percent
    of the least: `(max - min) / min * 100`. The least must be positive."""
    var lo = minimum(values)
    var hi = maximum(values)
    if lo <= 0.0:
        raise Error("spread_pct: the least value must be positive")
    return (hi - lo) / lo * 100.0


def geomean(values: List[Float64]) raises -> Float64:
    """The geometric mean of `values`, each of which must be finite and
    positive. Raises on no values. It is the mean of logs through the
    platform's `log` and `exp`, so it is accurate to about 1e-9 relative and
    not bit-exact across platforms."""
    if len(values) == 0:
        raise Error("geomean: no values")
    var total = 0.0
    for i in range(len(values)):
        var v = values[i]
        if not isfinite(v) or v <= 0.0:
            raise Error(
                "geomean: value " + String(i) + " is not finite and positive"
            )
        total += log(v)
    return exp(total / Float64(len(values)))


def ratio_of(komira_ms: Float64, duckdb_ms: Float64) raises -> Float64:
    """`komira_ms / duckdb_ms`, lower is better for komira. Both times must be
    finite and positive."""
    if not isfinite(komira_ms) or komira_ms <= 0.0:
        raise Error("ratio_of: the komira time must be finite and positive")
    if not isfinite(duckdb_ms) or duckdb_ms <= 0.0:
        raise Error("ratio_of: the duckdb time must be finite and positive")
    return komira_ms / duckdb_ms
