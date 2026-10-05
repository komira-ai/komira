# =============================================================================
# tests/test_series_source_seam.mojo
#   ⭐ THE SEAM, PROVED IMPLEMENTABLE.
#
# `SeriesSource` is the entire contract between this detector and whatever
# eventually produces the data — the metrics system being designed in parallel,
# a reader over recorded bench artifacts, or a fake. A trait that NOTHING
# conforms to is documentation, not an interface: it can be subtly
# unimplementable (a signature that cannot be satisfied, a lifetime that cannot
# be produced) and nobody finds out until the day someone tries.
#
# So this file writes a conformer and drives the real detector through it, via
# the real generic `evaluate_source`. That is the falsifier for three separate
# claims the design rests on:
#
#   (1) the trait CAN be conformed;
#   (2) `evaluate_source` really is generic over it — it is compiled here
#       against a type the library has never seen;
#   (3) the seam is sufficient. If the detector needed anything the trait does
#       not expose, this would not compile, and the gap would be found now
#       rather than when the metrics system arrives.
#
# ⚠ WHAT THE FAKE DELIBERATELY DOES NOT HAVE: any notion of a metric point, an
# attribute set, a table, a file format or a query. If a future conformer needs
# the trait to grow one of those, that is a signal the seam was drawn in the
# wrong place — and this file is where it would show up first.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_anomaly import (
    DetectorConfig,
    STATE_ACCUMULATING,
    STATE_ANOMALY,
    STATE_NORMAL,
    Series,
    SeriesSource,
    evaluate_source,
)


struct InMemorySource(SeriesSource):
    """A conformer built from nothing but the three verbs.

    It holds keys and values and knows no more about a measurement than the
    trait does — which is the point: the detector must be drivable by a
    producer that shares no vocabulary with it.
    """

    var keys: List[String]
    var values: List[List[Float64]]
    var raise_on: String

    def __init__(out self):
        self.keys = []
        self.values = []
        self.raise_on = String("")

    def add(mut self, key: String, var values: List[Float64]):
        self.keys.append(key)
        self.values.append(values^)

    # ---- SeriesSource -------------------------------------------------------

    def series_count(mut self) raises -> Int:
        return len(self.keys)

    def series_key_at(mut self, index: Int) raises -> String:
        if index < 0 or index >= len(self.keys):
            raise Error(String("no series at index ") + String(index))
        return self.keys[index]

    def load_series(mut self, key: String) raises -> Series:
        if key == self.raise_on:
            raise Error(String("simulated unreadable series: ") + key)
        for i in range(len(self.keys)):
            if self.keys[i] == key:
                var s = Series(key)
                for j in range(len(self.values[i])):
                    s.append(Int64(j), self.values[i][j])
                return s^
        raise Error(String("unknown series key: ") + key)


def _stable(n: Int) -> List[Float64]:
    var pattern: List[Float64] = [-2.0, -1.0, 0.0, 1.0, 2.0]
    var out = List[Float64]()
    for i in range(n):
        out.append(100.0 + pattern[i % 5])
    return out^


def _stepped(before: Int, after: Int, factor: Float64) -> List[Float64]:
    var pattern: List[Float64] = [-2.0, -1.0, 0.0, 1.0, 2.0]
    var out = List[Float64]()
    for i in range(before):
        out.append(100.0 + pattern[i % 5])
    for i in range(after):
        out.append((100.0 + pattern[i % 5]) * factor)
    return out^


def test_the_seam_conforms_and_drives_the_real_detector() raises:
    """(1),(2),(3) at once: this file COMPILING is most of the assertion."""
    var src = InMemorySource()
    src.add(String("a/stable"), _stable(14))
    src.add(String("b/regressed"), _stepped(12, 8, Float64(1.30)))
    src.add(String("c/young"), _stable(4))

    var report = evaluate_source(src, DetectorConfig())
    assert_equal(report.total, 3, "every series is visited")
    assert_equal(report.normal, 1, "the stable one is NORMAL")
    assert_equal(report.anomaly, 1, "the regressed one fires")
    assert_equal(report.accumulating, 1, "the young one is still accumulating")
    assert_equal(report.load_failures, 0, "nothing failed to load")


def test_each_verdict_keeps_its_own_series_identity() raises:
    """A sweep that mixed up which verdict belonged to which series would be
    worse than no sweep — every card would name the wrong subject."""
    var src = InMemorySource()
    src.add(String("a/stable"), _stable(14))
    src.add(String("b/regressed"), _stepped(12, 8, Float64(1.30)))

    var report = evaluate_source(src, DetectorConfig())
    var seen_stable = False
    var seen_regressed = False
    for i in range(len(report.verdicts)):
        var v = report.verdicts[i].copy()
        if v.series_key == String("a/stable"):
            seen_stable = True
            assert_equal(v.state, STATE_NORMAL, "the stable one is NORMAL")
        if v.series_key == String("b/regressed"):
            seen_regressed = True
            assert_equal(v.state, STATE_ANOMALY, "the stepped one is ANOMALY")
            assert_equal(
                v.change_ordinal, Int64(12), "at its own change point"
            )
    assert_true(seen_stable and seen_regressed, "both keys are reported")


def test_one_unreadable_series_does_not_sink_the_sweep() raises:
    """⛔ An aborted census is indistinguishable from a clean short one. The
    failure is COUNTED and the remaining series are still evaluated."""
    var src = InMemorySource()
    src.add(String("a/stable"), _stable(14))
    src.add(String("b/broken"), _stable(14))
    src.add(String("c/regressed"), _stepped(12, 8, Float64(1.30)))
    src.raise_on = String("b/broken")

    var report = evaluate_source(src, DetectorConfig())
    assert_equal(report.load_failures, 1, "the failure is counted, not hidden")
    assert_equal(report.total, 2, "and the other two were still evaluated")
    assert_equal(report.anomaly, 1, "including the one that fires")
    assert_true(
        report.render().find(String("load_failures=1")) >= 0,
        String("the census line must carry it; got ") + report.render(),
    )


def test_an_empty_source_reports_an_empty_census() raises:
    """Zero series is a real answer, and it reports as zeros rather than as a
    green — a caller that reads 'no anomalies' off an empty sweep has measured
    nothing."""
    var src = InMemorySource()
    var report = evaluate_source(src, DetectorConfig())
    assert_equal(report.total, 0, "nothing visited")
    assert_equal(report.normal, 0, "and emphatically not 'all normal'")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
