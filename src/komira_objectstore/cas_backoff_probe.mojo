# =============================================================================
# cas_backoff_probe -- what CasManifestStore.append's 412 backoff did, counted
# =============================================================================
#
# WHY IT EXISTS. `RetryPolicy` (cas_manifest.mojo) promises bounded
# exponential backoff with full jitter: after the k-th 412 a writer sleeps a
# draw in [0, min(base * 2^k, cap)] before it retries. Full jitter can draw 0,
# so no wall-clock lower bound can tell a loop that backs off from one that
# does not; a contention test that only checks correctness and progress passes
# either way. These counters make the promise checkable. For every backoff
# they record its attempt number k, the upper bound the call site passed, the
# draw, and the time the sleep actually took, so a test can check, from its
# OWN RetryPolicy, that:
#
#   * attempt k drew exactly as often as its calls retried a k-th 412;
#   * the bounds passed for attempt k sum to count_k * the test's own
#     `backoff_us_for_attempt(k)` (the call site's bound is the policy's);
#   * no draw exceeded the bound it was drawn under;
#   * the total slept is at least the total drawn (a sleep runs long, never
#     short, with no signal handler installed).
#
# Process-global (komira_counters' GlobalCounterTable, keyed by name), relaxed
# atomics, written with the non-raising `try_add`: an instrument never changes
# the control flow of `append`. ONE CONTENTION TEST PER BINARY: two CAS tests
# running at once in one process would mix their counts. No pointer crosses
# this module's API.
# =============================================================================
from komira_counters.global_counter import GlobalCounterTable

comptime CAS_BACKOFF_PROBE_MAX_ATTEMPT = 40
"""Attempts 1 .. this have a slot each; a later attempt is counted in the
last one (`backoff_us_for_attempt` is already at its cap there)."""

comptime _DRAWS_OVER_UPPER = 0
comptime _DRAWN_US = 1
comptime _SLEPT_US = 2
comptime _COUNT_BASE = 3
comptime _UPPER_BASE = _COUNT_BASE + CAS_BACKOFF_PROBE_MAX_ATTEMPT
comptime _N = _UPPER_BASE + CAS_BACKOFF_PROBE_MAX_ATTEMPT
comptime _PROBE = GlobalCounterTable["komira_objectstore_cas_backoff_probe", _N]


def _attempt_slot(attempt: Int) -> Int:
    if attempt < 1:
        return 0
    if attempt > CAS_BACKOFF_PROBE_MAX_ATTEMPT:
        return CAS_BACKOFF_PROBE_MAX_ATTEMPT - 1
    return attempt - 1


def record_cas_backoff(attempt: Int, upper_us: Int64, drawn_us: Int64, slept_us: Int64):
    """Count one backoff: attempt `attempt`'s bound, its draw and the time
    slept. Called by CasManifestStore.append after each retried 412, never by
    a caller. Non-raising: a counter that failed to allocate drops the add."""
    var s = _attempt_slot(attempt)
    _PROBE.try_add(_COUNT_BASE + s, 1)
    _PROBE.try_add(_UPPER_BASE + s, Int(upper_us))
    _PROBE.try_add(_DRAWN_US, Int(drawn_us))
    _PROBE.try_add(_SLEPT_US, Int(slept_us))
    if drawn_us > upper_us or drawn_us < Int64(0):
        _PROBE.try_add(_DRAWS_OVER_UPPER, 1)


@fieldwise_init
struct CasBackoffCounts(Copyable, Movable):
    """The counters since the last `reset_cas_backoff_counts`."""

    var draws_at: List[Int]
    """`draws_at[k - 1]`: backoffs taken after the k-th 412 of a call."""
    var upper_sum_at: List[Int]
    """`upper_sum_at[k - 1]`: the sum of the bounds those draws were taken
    under (microseconds)."""
    var draws_over_upper: Int
    """Draws above the bound they were taken under."""
    var drawn_us: Int
    """Total drawn, microseconds."""
    var slept_us: Int
    """Total time the sleeps took, microseconds."""

    def draws(self) -> Int:
        """All backoffs."""
        var n = 0
        for i in range(len(self.draws_at)):
            n += self.draws_at[i]
        return n


def cas_backoff_counts() raises -> CasBackoffCounts:
    """The counters now. Read after the writers have joined."""
    var draws_at = List[Int]()
    var upper_sum_at = List[Int]()
    for i in range(CAS_BACKOFF_PROBE_MAX_ATTEMPT):
        draws_at.append(_PROBE.read(_COUNT_BASE + i))
        upper_sum_at.append(_PROBE.read(_UPPER_BASE + i))
    return CasBackoffCounts(
        draws_at^,
        upper_sum_at^,
        _PROBE.read(_DRAWS_OVER_UPPER),
        _PROBE.read(_DRAWN_US),
        _PROBE.read(_SLEPT_US),
    )


def reset_cas_backoff_counts() raises:
    """Set the counters to 0, with no writer running."""
    _PROBE.reset()
