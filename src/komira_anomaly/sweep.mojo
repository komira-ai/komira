# =============================================================================
# komira_anomaly.sweep — DRIVING THE DETECTOR ACROSS EVERY SERIES A SOURCE HAS.
# =============================================================================
#
# ★ THIS IS WHAT MAKES `SeriesSource` LOAD-BEARING RATHER THAN DECORATIVE. The
# seam in `series.mojo` is only worth its documentation if something in the
# product is written against the TRAIT and not against a concrete producer.
# `evaluate_source` is that something: it is generic over any conformer, so a
# metrics-backed source, a bench-artifact-backed source and an in-memory fake
# reach the detector by the identical path.
#
# ⚠ IT REPORTS A CENSUS, NOT A PASS. There is deliberately no
# `report.is_green()`, because the run-level question a caller wants answered —
# 'is this build clean?' — is not one this function can answer honestly:
#
#   * some series will be ACCUMULATING, and a run that treats those as passes
#     is reporting compliance it has not measured;
#   * a firing on a REAL run may be a true positive, so a run-level
#     'firings <= budget' check is only meaningful against a KNOWN ZERO, where
#     every firing is false by construction.
#
# Both counts are returned separately for exactly that reason. A caller
# deciding what to do with them has to state which question it is asking.
#
# ⛔ AND ONE SERIES' FAILURE MUST NOT SINK THE SWEEP. A source that raises on
# series 40 of 82 would otherwise discard the 39 verdicts already computed.
# `load_failures` counts them and the sweep continues — an aborted census is
# indistinguishable from a clean short one.
# =============================================================================

from komira_anomaly.detector import (
    DetectorConfig,
    STATE_ACCUMULATING,
    STATE_ANOMALY,
    STATE_NORMAL,
    STATE_UNCALIBRATED,
    SeriesDetector,
    Verdict,
)
from komira_anomaly.series import SeriesSource


struct SweepReport(Movable, Deinitable):
    """One pass over every series a source holds."""

    var total: Int
    var accumulating: Int
    var normal: Int
    var anomaly: Int
    var uncalibrated: Int
    var load_failures: Int
    var verdicts: List[Verdict]

    def __init__(out self):
        self.total = 0
        self.accumulating = 0
        self.normal = 0
        self.anomaly = 0
        self.uncalibrated = 0
        self.load_failures = 0
        self.verdicts = []

    def _record(mut self, var verdict: Verdict):
        self.total += 1
        if verdict.state == STATE_ACCUMULATING:
            self.accumulating += 1
        elif verdict.state == STATE_NORMAL:
            self.normal += 1
        elif verdict.state == STATE_ANOMALY:
            self.anomaly += 1
        elif verdict.state == STATE_UNCALIBRATED:
            self.uncalibrated += 1
        self.verdicts.append(verdict^)

    def render(self) -> String:
        """The census, in one line. Every bucket is printed even at zero — a
        line that omits its empty buckets cannot be diffed between runs."""
        return (
            String("sweep total=")
            + String(self.total)
            + String(" normal=")
            + String(self.normal)
            + String(" anomaly=")
            + String(self.anomaly)
            + String(" accumulating=")
            + String(self.accumulating)
            + String(" uncalibrated=")
            + String(self.uncalibrated)
            + String(" load_failures=")
            + String(self.load_failures)
        )


def evaluate_source[S: SeriesSource](
    mut source: S, config: DetectorConfig
) raises -> SweepReport:
    """Evaluate every series the source enumerates, with a fresh detector each.

    ⚠ A FRESH DETECTOR PER SERIES, SO THIS IS A ONE-SHOT CENSUS. A detector's
    latch, baseline and dismissal are its memory ACROSS runs, and this function
    has nowhere to keep them; a caller that needs the memory holds its own
    `SeriesDetector` per key and calls `evaluate` directly. Reusing one
    detector across different series would apply one series' latch to another's
    data, which `evaluate` raises on.
    """
    var report = SweepReport()
    var count = source.series_count()
    for i in range(count):
        var key = source.series_key_at(i)
        try:
            var series = source.load_series(key)
            var det = SeriesDetector(key, config)
            report._record(det.evaluate(series))
        except e:
            # Counted, never swallowed silently — see the module header.
            report.load_failures += 1
    return report^
