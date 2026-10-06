# The package's Cloud Monitoring facts, checked against the pinned
# googleapis protos (google/monitoring/v3, staged by BUCK from
# //tools/vendor/googleapis, read here as text at test time, never copied):
# the default host, the ListTimeSeries path, the page-size ceiling, the
# minimum alignment period, that points come newest first, that a read's
# interval is (startTime, endTime], and that every aligner and reducer the
# reader sends is one the protos declare.
#
# A googleapis bump that changes any of these fails the build here.

from std.testing import assert_equal, assert_true

from komira_gcp_monitoring import (
    LIST_TIME_SERIES_MAX_PAGE_SIZE,
    MONITORING_DEFAULT_HOST,
    MONITORING_MIN_ALIGNMENT_S,
    monitoring_aligner,
    monitoring_reducer,
    time_series_list_name,
)
from komira_metrics_reader import MetricsAggregation, MetricsMatcher, MetricsQuery


comptime _SERVICE = "google/monitoring/v3/metric_service.proto"
comptime _COMMON = "google/monitoring/v3/common.proto"


def _read(path: String) raises -> String:
    with open(path, "r") as f:
        return f.read()


def _flat(path: String) raises -> String:
    """The file with each line's leading `//` comment marker and the
    indentation and line breaks folded to single spaces, so a sentence a
    comment wraps reads as one."""
    var out = String("")
    for line in _read(path).split("\n"):
        var t = String(line).strip()
        var s = String(t)
        if s.startswith("//"):
            s = String(String(s[byte=2:]).strip())
        if s.byte_length() > 0:
            out += s + " "
    return out^


def test_service() raises:
    var svc = _read(_SERVICE)
    assert_true(
        String('option (google.api.default_host) = "')
        + String(MONITORING_DEFAULT_HOST)
        + String('";')
        in svc
    )
    assert_true('get: "/v3/{name=projects/*}/timeSeries"' in svc)
    assert_equal(time_series_list_name(String("p-1")), String("projects/p-1"))
    var flat = _flat(_SERVICE)
    assert_equal(LIST_TIME_SERIES_MAX_PAGE_SIZE, 100_000)
    assert_true(
        "`page_size` is empty or more than 100,000 results, the effective"
        " `page_size` is 100,000 results" in flat
    )
    assert_true(
        "currently returned in reverse time order (most recent to oldest)" in flat
    )


def test_common() raises:
    var flat = _flat(_COMMON)
    assert_equal(MONITORING_MIN_ALIGNMENT_S, 60)
    assert_true("The value must be at least 60 seconds." in flat)
    assert_true(
        "Reads: A half-open time interval. It includes the end time but"
        " excludes the start time: `(startTime, endTime]`." in flat
    )
    var text = _read(_COMMON)
    for name in ["sum", "rate", "mean", "min", "max", "count"]:
        var agg = MetricsAggregation.from_name(String(name)).value()
        var q = MetricsQuery(
            Int64(0),
            Int64(1),
            String("m"),
            List[MetricsMatcher](),
            agg,
            Int64(60_000),
            [String("code")],
            1,
            1,
        )
        var aligner = monitoring_aligner(q)
        var reducer = monitoring_reducer(q)
        assert_true(aligner.byte_length() > 0, String(name))
        assert_true(reducer.byte_length() > 0, String(name))
        assert_true(String("    ") + aligner + String(" = ") in text, aligner)
        assert_true(String("    ") + reducer + String(" = ") in text, reducer)


def main() raises:
    test_service()
    test_common()
    print("OK")
