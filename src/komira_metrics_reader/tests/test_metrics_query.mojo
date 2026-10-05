# komira_metrics_reader: the value types. Aggregation spellings round-trip
# and an unknown one is None; matchers carry their polarity; the query's
# lookups; a series' label lookup; a page counts its samples and the empty
# page is complete with nothing scanned.

from std.testing import assert_equal, assert_false, assert_true

from komira_metrics_reader import (
    MetricsAggregation,
    MetricsLabel,
    MetricsMatcher,
    MetricsPage,
    MetricsQuery,
    MetricsSample,
    MetricsSeriesData,
)


def test_aggregation_names_round_trip() raises:
    var names = ["raw", "sum", "rate", "mean", "min", "max", "count"]
    for i in range(len(names)):
        var a = MetricsAggregation.from_name(String(names[i]))
        assert_true(Bool(a), String(names[i]))
        assert_equal(a.value().name(), String(names[i]))
        assert_equal(a.value().code, i)
    assert_true(MetricsAggregation.from_name(String("raw")).value().is_raw())
    assert_false(MetricsAggregation.sum().is_raw())
    assert_true(MetricsAggregation.max() == MetricsAggregation.max())
    assert_true(MetricsAggregation.max() != MetricsAggregation.min())


def test_unknown_aggregation_is_none() raises:
    assert_false(Bool(MetricsAggregation.from_name(String("p99"))))
    assert_false(Bool(MetricsAggregation.from_name(String("SUM"))))
    assert_false(Bool(MetricsAggregation.from_name(String(""))))


def test_matchers_carry_their_polarity() raises:
    var e = MetricsMatcher.eq(String("code"), String("200"))
    var n = MetricsMatcher.neq(String("code"), String("500"))
    assert_false(e.negated)
    assert_true(n.negated)
    assert_equal(n.value, String("500"))


def test_query_lookups() raises:
    var m = List[MetricsMatcher]()
    m.append(MetricsMatcher.eq(String("route"), String("/a")))
    var g = List[String]()
    g.append(String("code"))
    var q = MetricsQuery(
        Int64(1), Int64(2), String("requests"), m^, MetricsAggregation.sum(),
        Int64(60_000), g^, 10, 100,
    )
    assert_true(q.has_matcher(String("route")))
    assert_false(q.has_matcher(String("code")))
    assert_true(q.groups_by(String("code")))
    assert_false(q.groups_by(String("route")))


def test_series_and_page() raises:
    var s = MetricsSeriesData.named(String("requests"))
    s.labels.append(MetricsLabel(String("code"), String("200")))
    s.samples.append(MetricsSample(Int64(10), 1.5))
    s.samples.append(MetricsSample(Int64(20), 2.5))
    assert_equal(s.label(String("code")).value(), String("200"))
    assert_false(Bool(s.label(String("route"))))
    var series = List[MetricsSeriesData]()
    series.append(s.copy())
    series.append(MetricsSeriesData.named(String("errors")))
    var page = MetricsPage(series^, True, 3)
    assert_equal(page.sample_count(), 2)
    assert_true(page.truncated)
    var empty = MetricsPage()
    assert_equal(len(empty.series), 0)
    assert_false(empty.truncated)
    assert_equal(empty.sources_scanned, 0)


def main() raises:
    test_aggregation_names_round_trip()
    test_unknown_aggregation_is_none()
    test_matchers_carry_their_polarity()
    test_query_lookups()
    test_series_and_page()
    print("OK")
