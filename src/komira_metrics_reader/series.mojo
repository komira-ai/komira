# =============================================================================
# komira_metrics_reader/series.mojo: what a metric read returns.
# =============================================================================
#
# A page of series; a series is a metric name, its labels, and its samples.
# Times are UNIX epoch nanoseconds and values are Float64 whatever the store
# spelled them as (an RFC 3339 string, epoch seconds, a quoted int64): each
# reader converts once, at its parser, so a consumer compares numbers rather
# than provider spellings.
#
# Encapsulation: value types only. No pointer.
# =============================================================================


@fieldwise_init
struct MetricsSample(Copyable, Movable, ImplicitlyCopyable):
    """One point of one series: `time_ns` is the END of the step it covers (or
    the point's own time for a `raw` read), `value` its value.

    An int64 counter arrives here as a Float64, exact up to 2^53. One numeric
    field is a simpler contract than two of which exactly one is set."""

    var time_ns: Int64
    var value: Float64


@fieldwise_init
struct MetricsLabel(Copyable, Movable):
    """One label of a series."""

    var key: String
    var value: String


@fieldwise_init
struct MetricsSeriesData(Copyable, Movable):
    """One series: the metric, the labels that tell it apart from the other
    series of the page, and its samples OLDEST FIRST.

    The ordering is the seam's contract: a reader whose store answers newest
    first reverses the points before returning them.

    A reader returns only the labels its store attaches to the series itself
    and the ones the query named (in a matcher or `group_by`). Labels that
    describe where the series was recorded (a project, an account) stay out
    unless asked for."""

    var metric: String
    var labels: List[MetricsLabel]
    var samples: List[MetricsSample]

    @staticmethod
    def named(metric: String) -> MetricsSeriesData:
        """A series of `metric` with no labels and no samples."""
        return MetricsSeriesData(
            metric.copy(), List[MetricsLabel](), List[MetricsSample]()
        )

    def label(self, key: String) -> Optional[String]:
        """The value of label `key`, or None."""
        for i in range(len(self.labels)):
            if self.labels[i].key == key:
                return Optional(self.labels[i].value.copy())
        return None


struct MetricsPage(Copyable, Movable):
    """One answer to one metric query.

      * `series`           at most the query's `series_limit`.
      * `truncated`        True when the reader stopped at a limit (series,
                           points or pages) with more to read. ⚠ Without it
                           a cut answer is indistinguishable from a complete
                           one.
      * `sources_scanned`  how many units the reader read (provider calls,
                           files). It is a measurement: it makes "nothing was
                           read" distinguishable from "nothing matched".

    An empty `series` is an answer: no points in the window. It is not a
    failure, which a reader raises."""

    var series: List[MetricsSeriesData]
    var truncated: Bool
    var sources_scanned: Int

    def __init__(out self):
        """The empty, complete page with nothing scanned."""
        self.series = List[MetricsSeriesData]()
        self.truncated = False
        self.sources_scanned = 0

    def __init__(
        out self,
        var series: List[MetricsSeriesData],
        truncated: Bool,
        sources_scanned: Int,
    ):
        self.series = series^
        self.truncated = truncated
        self.sources_scanned = sources_scanned

    def sample_count(self) -> Int:
        """Samples across every series."""
        var n = 0
        for i in range(len(self.series)):
            n += len(self.series[i].samples)
        return n
