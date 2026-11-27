from std.testing import assert_equal, assert_true
from anomaly import AnomalyMonitor, DetectorConfig, OnlineConfig, STATE_ANOMALY


def main() raises:
    var steps: List[Float64] = [-2.0, -1.0, 0.0, 1.0, 2.0]
    var monitor = AnomalyMonitor(OnlineConfig(DetectorConfig(), 64, 1, 5.0, 5))
    var fired_at = -1
    for i in range(20):
        var value = 100.0 + steps[i % 5]
        if i >= 12:
            value *= 1.25
        if monitor.observe("svc/req", Int64(i), value).state == STATE_ANOMALY:
            fired_at = i
            break
    assert_equal(fired_at, 12)
    assert_true(monitor.verdict_for("svc/req").bound_breached)
