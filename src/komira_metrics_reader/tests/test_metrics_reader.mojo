# komira_metrics_reader: the trait, the erased facade and the double.
#
# A reader written against the trait accepts the erased facade and the double
# alike; the facade forwards the refusal and the read to the reader it holds
# and destroys it exactly once; the double answers its script, records every
# query, raises its fault and refuses with its sentence.

from std.memory import ArcPointer
from std.testing import assert_equal, assert_false, assert_raises, assert_true

from komira_metrics_reader import (
    ErasedMetricsReader,
    MetricsAggregation,
    MetricsMatcher,
    MetricsPage,
    MetricsQuery,
    MetricsReader,
    MetricsSample,
    MetricsSeriesData,
    ScriptedMetricsReader,
)


def _query(metric: String, step_ms: Int64 = 60_000) -> MetricsQuery:
    return MetricsQuery(
        Int64(1_000), Int64(2_000), metric.copy(), List[MetricsMatcher](),
        MetricsAggregation.mean(), step_ms, List[String](), 5, 50,
    )


struct Counting(MetricsReader, Movable, Deinitable):
    """Answers one series named after the query; counts its own drops."""

    var drops: ArcPointer[Int]

    def __init__(out self, var drops: ArcPointer[Int]):
        self.drops = drops^

    def refusal(self, q: MetricsQuery) -> String:
        if q.step_ms < Int64(60_000):
            return String("the smallest step is 60000 ms")
        return String("")

    def read(mut self, q: MetricsQuery) raises -> MetricsPage:
        var s = MetricsSeriesData.named(q.metric)
        s.samples.append(MetricsSample(q.end_ns, Float64(q.series_limit)))
        var series = List[MetricsSeriesData]()
        series.append(s^)
        return MetricsPage(series^, False, 1)

    def __deinit__(deinit self):
        self.drops[] += 1


def _through_trait[R: MetricsReader](mut r: R, q: MetricsQuery) raises -> String:
    """What generic code sees: the refusal, else the first series' metric."""
    var why = r.refusal(q)
    if why.byte_length() > 0:
        return String("refused: ") + why
    var page = r.read(q)
    return page.series[0].metric.copy()


def test_erased_forwards_and_drops_once() raises:
    var drops = ArcPointer[Int](0)
    var erased = ErasedMetricsReader.erase(Counting(drops))
    assert_equal(_through_trait(erased, _query(String("cpu"))), String("cpu"))
    assert_equal(
        _through_trait(erased, _query(String("cpu"), Int64(1_000))),
        String("refused: the smallest step is 60000 ms"),
    )
    var page = erased.read(_query(String("mem")))
    assert_equal(page.series[0].samples[0].time_ns, Int64(2_000))
    assert_equal(page.series[0].samples[0].value, 5.0)
    assert_equal(drops[], 0)
    _ = erased^
    assert_equal(drops[], 1)


def test_scripted_answers_and_records() raises:
    var d = ScriptedMetricsReader()
    var view = d.share()
    var s = MetricsSeriesData.named(String("requests"))
    s.samples.append(MetricsSample(Int64(5), 7.0))
    var series = List[MetricsSeriesData]()
    series.append(s^)
    d.answer(MetricsPage(series^, True, 2))
    var erased = ErasedMetricsReader.erase(d^)
    assert_equal(erased.refusal(_query(String("requests"))), String(""))
    var page = erased.read(_query(String("requests")))
    assert_equal(page.sample_count(), 1)
    assert_true(page.truncated)
    assert_equal(page.sources_scanned, 2)
    assert_equal(view.read_count(), 1)
    assert_equal(view.refusal_count(), 1)
    assert_equal(view.last_query().metric, String("requests"))
    assert_equal(view.last_query().aggregation.name(), String("mean"))


def test_scripted_refuses_and_fails() raises:
    var d = ScriptedMetricsReader()
    d.refuse(String("no quantiles here"))
    assert_equal(d.refusal(_query(String("x"))), String("no quantiles here"))
    d.refuse(String(""))
    d.fail(String("store unreachable"))
    with assert_raises(contains="store unreachable"):
        _ = d.read(_query(String("x")))
    # A failed read is still recorded: the query reached the reader.
    assert_equal(d.read_count(), 1)
    d.fail(String(""))
    var page = d.read(_query(String("x")))
    assert_equal(len(page.series), 0)
    assert_false(page.truncated)


def test_no_query_read_raises() raises:
    var d = ScriptedMetricsReader()
    with assert_raises(contains="no query has been read"):
        _ = d.last_query()


def main() raises:
    test_erased_forwards_and_drops_once()
    test_scripted_answers_and_records()
    test_scripted_refuses_and_fails()
    test_no_query_read_raises()
    print("OK")
