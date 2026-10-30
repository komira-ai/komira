# =============================================================================
# phase_snapshot -- the phase timers folded across threads
# =============================================================================
#
# For one phase and one run: the sum over threads of their time in it, the
# largest single thread's time in it (the critical path of that phase), the
# longest single interval, the number of intervals and the number of threads
# that spent any time in it. With the timers compiled out every field is 0.

from komira_phase_timers.phase_timers import (
    FIELD_CALLS,
    FIELD_MAX,
    FIELD_SUM,
    PH_COUNT,
    pt_get,
    pt_lane_count,
)


struct PhaseAgg(Copyable, Movable):
    var sum_ns: Int
    """The sum over threads."""
    var crit_ns: Int
    """The largest total of one thread."""
    var longest_ns: Int
    """The longest single interval of any thread."""
    var calls: Int
    var lanes: Int
    """Threads with at least one interval."""

    def __init__(out self):
        self.sum_ns = 0
        self.crit_ns = 0
        self.longest_ns = 0
        self.calls = 0
        self.lanes = 0


def snapshot_phase(phase: Int) -> PhaseAgg:
    var a = PhaseAgg()
    for lane in range(pt_lane_count()):
        var s = pt_get(lane, phase, FIELD_SUM)
        var c = pt_get(lane, phase, FIELD_CALLS)
        a.sum_ns += s
        a.calls += c
        if s > a.crit_ns:
            a.crit_ns = s
        var m = pt_get(lane, phase, FIELD_MAX)
        if m > a.longest_ns:
            a.longest_ns = m
        if c > 0:
            a.lanes += 1
    return a^


def snapshot_all() -> List[PhaseAgg]:
    var out = List[PhaseAgg](capacity=PH_COUNT)
    for p in range(PH_COUNT):
        out.append(snapshot_phase(p))
    return out^
