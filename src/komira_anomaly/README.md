# komira_anomaly

Regression detection over an abstract series of ordered numbers, with no
dependencies. A `Series` is a string key and points of `(Int64 ordinal,
Float64 value)`; `validate` refuses non-finite values, ordinals that are not
strictly increasing, and an empty key. `SeriesDetector` is a per-series state
machine (ACCUMULATING, NORMAL, ANOMALY, UNCALIBRATED) whose primary arm is an
E-divisive change-point fit with a seeded permutation test, so a verdict is a
pure function of the data and the key; an ANOMALY latches until it is
acknowledged or dismissed. A tabular CUSUM chart on a median/MAD scale reports
slow drift and is advisory by default. `AnomalyMonitor` is the post-a-point
form: `observe(key, ordinal, value)` returns a verdict from O(1) running bounds
plus the same state machine, with the change-point arm run on a stated cadence.
`SeriesSource` and `MeasurementStore` are the traits a producer implements;
`evaluate_source` sweeps every series a source holds, and `InMemoryPointStore`
is the reference in-memory conformer.

## Examples

A series is checked before anything computes on it:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_anomaly import SERIES_OK, SERIES_REJECT_UNORDERED, Series, series_reject_reason_name

var good = Series("latency/p50")
good.append(Int64(1), 10.0)
good.append(Int64(2), 11.0)
assert_equal(good.validate(), SERIES_OK)

var bad = Series("latency/p50")
bad.append(Int64(2), 10.0)
bad.append(Int64(2), 11.0)
assert_equal(bad.validate(), SERIES_REJECT_UNORDERED)
assert_equal(String(series_reject_reason_name(bad.validate())), "ORDINALS_NOT_STRICTLY_INCREASING")
```

A 25% step after twelve stable points is found at the ordinal where it starts,
and the ANOMALY stays latched on the next evaluation:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from komira_anomaly import DetectorConfig, STATE_ANOMALY, STATE_NORMAL, Series, SeriesDetector

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
```

Post points one at a time; the running bounds judge each new point against the
points before it:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from komira_anomaly import AnomalyMonitor, DetectorConfig, OnlineConfig, STATE_ANOMALY

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
```

A store is a series source, so what was written sweeps through the detector:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_anomaly import DetectorConfig, InMemoryPointStore, evaluate_source

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
```
