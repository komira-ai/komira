from std.testing import assert_equal, assert_true
from anomaly import DetectorConfig, STATE_ANOMALY, STATE_NORMAL, Series, SeriesDetector


def main() raises:
    var wobble: List[Float64] = [-2.0, -1.0, 0.0, 1.0, 2.0]
    var config = DetectorConfig()
    var detector = SeriesDetector("bench/parse", config)

    var stable = Series("bench/parse")
    for i in range(12):
        stable.append(Int64(i), 100.0 + wobble[i % 5])
    assert_equal(detector.evaluate(stable).state, STATE_NORMAL)

    var stepped = stable.copy()
    for i in range(8):
        stepped.append(Int64(12 + i), (100.0 + wobble[i % 5]) * 1.25)
    var verdict = detector.evaluate(stepped)
    assert_equal(verdict.state, STATE_ANOMALY)
    assert_true(verdict.changepoint_fired)
    assert_equal(verdict.change_ordinal, Int64(12))
    assert_true(verdict.p_value < config.significance)
    assert_true(verdict.relative_shift > 0.20 and verdict.relative_shift < 0.30)
    assert_equal(detector.evaluate(stepped).state, STATE_ANOMALY)
