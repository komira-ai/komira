# =============================================================================
# cas_backoff_probe -- what CasManifestStore.append's 412 backoff did, counted
# =============================================================================
#
# WHY IT EXISTS. `RetryPolicy` (cas_manifest.mojo) promises bounded
# exponential backoff with full jitter: after the k-th 412 a writer sleeps a
# draw in [0, min(base * 2^k, cap)] before it retries. Full jitter can draw 0,
# so no wall-clock lower bound can tell a loop that backs off from one that
# does not; a contention test that only checks correctness and progress passes
# either way. These counters make the promise checkable: every backoff draw is
# counted, and so is every draw above the bound `backoff_us_for_attempt` gives
# for its attempt. A test resets them, runs writers, and holds the count of
# draws equal to the 412s it saw retried.
#
# Process-global (komira_counters' GlobalCounterTable, keyed by name), relaxed
# atomics: two adds on a path that is about to sleep. No pointer crosses this
# module's API.
# =============================================================================
from komira_counters.global_counter import GlobalCounterTable

comptime _PROBE = GlobalCounterTable["komira_objectstore_cas_backoff_probe", 2]
comptime _DRAWS = 0
comptime _DRAWS_OVER_BOUND = 1


@fieldwise_init
struct CasBackoffCounts(Copyable, ImplicitlyCopyable, Movable):
    """The counters since the last `reset_cas_backoff_counts`."""

    var draws: Int
    """Backoff draws taken after a 412 that was retried."""
    var draws_over_bound: Int
    """Draws above `RetryPolicy.backoff_us_for_attempt(attempt)`."""


def record_cas_backoff(drawn_us: Int64, bound_us: Int64) raises:
    """Count one backoff draw, and whether it exceeded its bound. Called by
    CasManifestStore.append after each retried 412, never by a caller."""
    _PROBE.incr(_DRAWS)
    if drawn_us > bound_us or drawn_us < Int64(0):
        _PROBE.incr(_DRAWS_OVER_BOUND)


def cas_backoff_counts() raises -> CasBackoffCounts:
    """The counters now. Read after the writers have joined."""
    return CasBackoffCounts(_PROBE.read(_DRAWS), _PROBE.read(_DRAWS_OVER_BOUND))


def reset_cas_backoff_counts() raises:
    """Set the counters to 0, with no writer running."""
    _PROBE.reset()
