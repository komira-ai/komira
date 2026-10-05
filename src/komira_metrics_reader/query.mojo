# =============================================================================
# komira_metrics_reader/query.mojo: ONE read of a metric, in terms every store
#   can answer.
# =============================================================================
#
# A metric can be read from several places: a cloud metric service (CloudWatch,
# Cloud Monitoring), or time-partitioned files a service wrote to an object
# store. The query is stated in terms all of them share: a time window, a metric
# name, label matchers, an aggregation over fixed steps, the labels to group by,
# and two bounds on the answer. Nothing here names a provider, a filter syntax
# or a file layout. A reader that cannot answer some part of a query says so
# (`MetricsReader.refusal`); the query never carries provider syntax.
#
# Encapsulation: value types only (Int64, Float64, String, List). No pointer.
# =============================================================================


@fieldwise_init
struct MetricsMatcher(Copyable, Movable, Deinitable):
    """One label condition: the series' label `key` equals `value`, or, when
    `negated`, does not.

    Equality only, on purpose: a regex matcher is a second grammar every reader
    would have to implement or refuse, and an exact match is what a selector
    over a handful of labels needs. A reader that cannot express `negated`
    refuses the query rather than dropping the condition."""

    var key: String
    var value: String
    var negated: Bool

    @staticmethod
    def eq(key: String, value: String) -> MetricsMatcher:
        return MetricsMatcher(key.copy(), value.copy(), False)

    @staticmethod
    def neq(key: String, value: String) -> MetricsMatcher:
        return MetricsMatcher(key.copy(), value.copy(), True)


comptime _AGG_RAW: Int = 0
comptime _AGG_SUM: Int = 1
comptime _AGG_RATE: Int = 2
comptime _AGG_MEAN: Int = 3
comptime _AGG_MIN: Int = 4
comptime _AGG_MAX: Int = 5
comptime _AGG_COUNT: Int = 6


@fieldwise_init
struct MetricsAggregation(Copyable, Movable, ImplicitlyCopyable):
    """How the points of one series are reduced within each step.

      * `raw`   no reduction: the points as stored. The step is ignored.
      * `sum`   the sum of the points in the step.
      * `rate`  the sum in the step divided by the step, per second.
      * `mean`, `min`, `max`  of the points in the step.
      * `count` how many points fell in the step.

    When the query groups by labels, the series of one group are combined
    after the per-step reduction: summed for `sum`, `rate` and `count`, and
    reduced with the same function for `mean`, `min` and `max`.

    A reader that cannot compute one of these refuses the query naming it; an
    empty answer would read as "no data"."""

    var code: Int

    @staticmethod
    def raw() -> MetricsAggregation:
        return MetricsAggregation(_AGG_RAW)

    @staticmethod
    def sum() -> MetricsAggregation:
        return MetricsAggregation(_AGG_SUM)

    @staticmethod
    def rate() -> MetricsAggregation:
        return MetricsAggregation(_AGG_RATE)

    @staticmethod
    def mean() -> MetricsAggregation:
        return MetricsAggregation(_AGG_MEAN)

    @staticmethod
    def min() -> MetricsAggregation:
        return MetricsAggregation(_AGG_MIN)

    @staticmethod
    def max() -> MetricsAggregation:
        return MetricsAggregation(_AGG_MAX)

    @staticmethod
    def count() -> MetricsAggregation:
        return MetricsAggregation(_AGG_COUNT)

    @staticmethod
    def from_name(name: String) -> Optional[MetricsAggregation]:
        """The aggregation spelled `name` (`raw`, `sum`, `rate`, `mean`,
        `min`, `max`, `count`), or None for any other spelling."""
        var names = _aggregation_names()
        for i in range(len(names)):
            if names[i] == name:
                return Optional(MetricsAggregation(i))
        return None

    def name(self) -> String:
        """This aggregation's spelling, as `from_name` reads it."""
        var names = _aggregation_names()
        if self.code >= 0 and self.code < len(names):
            return names[self.code].copy()
        return String("unknown")

    def is_raw(self) -> Bool:
        return self.code == _AGG_RAW

    def __eq__(self, other: MetricsAggregation) -> Bool:
        return self.code == other.code

    def __ne__(self, other: MetricsAggregation) -> Bool:
        return self.code != other.code


def _aggregation_names() -> List[String]:
    """The spellings, indexed by code."""
    var out = List[String]()
    out.append(String("raw"))
    out.append(String("sum"))
    out.append(String("rate"))
    out.append(String("mean"))
    out.append(String("min"))
    out.append(String("max"))
    out.append(String("count"))
    return out^


@fieldwise_init
struct MetricsQuery(Copyable, Movable, Deinitable):
    """One read of one metric.

      * `start_ns`, `end_ns`  the window, UNIX epoch nanoseconds, INCLUSIVE at
                              both ends (the log query's convention). A reader
                              over a store whose interval is half-open adjusts
                              the bound it sends, not the meaning.
      * `metric`              the metric's name in the reader's namespace
                              (a Cloud Monitoring metric type, a CloudWatch
                              metric name, a stored series name).
      * `matchers`            label conditions, all of which must hold.
      * `aggregation`, `step_ms`  the per-step reduction and the step. The
                              step is ignored for `raw`.
      * `group_by`            label keys to keep when combining series; empty
                              keeps every series apart.
      * `series_limit`        at most this many series in the answer.
      * `point_limit`         at most this many samples in each series.

    The two limits bound what one read materialises on a service instance
    sized for HTTP. A reader that stops at one sets `MetricsPage.truncated`, so
    a cut answer never reads as a complete one."""

    var start_ns: Int64
    var end_ns: Int64
    var metric: String
    var matchers: List[MetricsMatcher]
    var aggregation: MetricsAggregation
    var step_ms: Int64
    var group_by: List[String]
    var series_limit: Int
    var point_limit: Int

    def has_matcher(self, key: String) -> Bool:
        """True iff some matcher names `key`."""
        for i in range(len(self.matchers)):
            if self.matchers[i].key == key:
                return True
        return False

    def groups_by(self, key: String) -> Bool:
        """True iff `key` is one of `group_by`."""
        for i in range(len(self.group_by)):
            if self.group_by[i] == key:
                return True
        return False
