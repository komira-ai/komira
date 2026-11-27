from std.testing import assert_equal
from anomaly import DetectorConfig, InMemoryPointStore, evaluate_source


def main() raises:
    var saw: List[Float64] = [-2.0, -1.0, 0.0, 1.0, 2.0]
    var store = InMemoryPointStore()
    for i in range(20):
        store.append_point("flat", Int64(i), 100.0 + saw[i % 5])
        var level = 125.0 if i >= 12 else 100.0
        store.append_point("stepped", Int64(i), level + saw[i % 5])

    var report = evaluate_source(store, DetectorConfig())
    assert_equal(report.total, 2)
    assert_equal(report.anomaly, 1)
    assert_equal(report.normal, 1)
