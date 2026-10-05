# =============================================================================
# komira_anomaly.series — THE ABSTRACT SERIES, AND THE SEAM THAT PRODUCES ONE.
# =============================================================================
#
# ★ WHAT A SERIES IS HERE, AND WHAT IT DELIBERATELY IS NOT.
#
# A series is an ORDERED SEQUENCE OF TIMESTAMPED NUMBERS WITH AN IDENTITY. That
# is the whole model, and its poverty is the design:
#
#   * `ordinal` is an `Int64` the PRODUCER assigns and this package never
#     interprets — epoch nanoseconds, a commit timestamp, a sweep index. The
#     detector uses it for ORDER and to NAME where a change point sits, and for
#     nothing else. No calendar, no timezone, no resolution is implied.
#   * `value` is a bare `Float64`. No unit, no dimension, no aggregation
#     semantics.
#   * `key` is an OPAQUE `String`. This package never parses it, never splits
#     it, and attaches no meaning to its parts.
#
# ⛔ WHY IT MUST STAY THIS POOR. Two other systems are being designed RIGHT NOW
# and each owns something this package must not invent:
#
#   * the METRICS SYSTEM owns the measurement data model (the point type and
#     its attribute set). This package must not grow a second one — two data
#     models for one measurement is the mis-delivery primitive
#     `komira_mail_addr`'s header names, applied to numbers.
#   * the AT-REST FORMAT owns how a series is stored and queried. Nothing here
#     names a file format, a table, a bucket, a catalog or a query engine.
#
# So the seam below is stated in terms that NEITHER of them can falsify: an
# Int64, a Float64 and a String. A producer built on any data model and any
# storage format can conform it, which is the property that lets the detector
# be written, tested and validated BEFORE either exists.
#
# ⚠ THE X AXIS IS NOT ASSUMED TO BE UNIFORM. Sweeps are irregular; commits are
# irregular. Nothing here divides by an interval or assumes equal spacing. The
# detector is distribution-free over the ORDER, not over the clock — see
# `edivisive.mojo`. A method that needed uniform spacing would be unusable on
# real benchmark data, where 10 sweeps span an afternoon and a commit series
# spans months.
#
# Encapsulation: value types only. ZERO UnsafePointer crosses this boundary,
# no wildcard origins, no heap-owning raw pointer fields.
# =============================================================================

from std.math import isfinite


struct SeriesPoint(Copyable, Movable, Deinitable):
    """One observation: a position on the X axis and a number.

    `ordinal` is a monotone position assigned by the PRODUCER and never
    interpreted here (see the module header). `value` is the measured
    quantity, in whatever unit the producer measured it in — the detector is
    scale-free, so no unit needs to be declared.
    """

    var ordinal: Int64
    var value: Float64

    def __init__(out self, ordinal: Int64, value: Float64):
        self.ordinal = ordinal
        self.value = value


# Why a series is admissible or not. Returned as an ordinal so a caller can
# branch, and rendered by `series_reject_reason_name` so a human sees a word.
comptime SERIES_OK: Int = 0
comptime SERIES_REJECT_NONFINITE: Int = 1
comptime SERIES_REJECT_UNORDERED: Int = 2
comptime SERIES_REJECT_EMPTY_KEY: Int = 3


def series_reject_reason_name(reason: Int) -> StaticString:
    """The reject ordinal as a word, for a verdict a human reads.

    ⚠ `StaticString`, NOT `String` — `scripts/lint_literal_return_ladder.py`."""
    if reason == SERIES_OK:
        return "OK"
    if reason == SERIES_REJECT_NONFINITE:
        return "NONFINITE_VALUE"
    if reason == SERIES_REJECT_UNORDERED:
        return "ORDINALS_NOT_STRICTLY_INCREASING"
    if reason == SERIES_REJECT_EMPTY_KEY:
        return "EMPTY_SERIES_KEY"
    return "UNKNOWN_REJECT_REASON"


struct Series(Copyable, Movable, Deinitable):
    """An identified, ordered run of observations.

    ⚠ CONSTRUCTION DOES NOT VALIDATE, `validate()` DOES, AND THE DETECTOR CALLS
    IT. A `Series` is a plain carrier so a producer can build one incrementally
    without every `append` re-scanning; admissibility is a question the
    consumer asks, once, at the point it is about to compute on the data.
    """

    var key: String
    var points: List[SeriesPoint]

    def __init__(out self, key: String):
        self.key = key
        self.points = []

    def append(mut self, ordinal: Int64, value: Float64):
        self.points.append(SeriesPoint(ordinal, value))

    def count(self) -> Int:
        """Number of points. Spelled as a method rather than `__len__` so a
        `Series` is never silently treated as a generic container by code that
        does not know an ordinal from an index."""
        return len(self.points)

    def validate(self) -> Int:
        """`SERIES_OK`, or the first reason this series cannot be computed on.

        ⛔ STRICTLY increasing, not merely non-decreasing. Two points sharing an
        ordinal are two readings of ONE position on the X axis, which means
        either the series key is under-specified (two different things are
        being pooled into one series) or the same measurement was ingested
        twice. Both corrupt a change-point fit — the first by mixing
        distributions, the second by inflating n with a duplicate that carries
        no new information — and neither is repairable by guessing an order.
        Refusing names the defect at the point it can still be fixed; averaging
        the pair, or sorting and hoping, hides it forever.
        """
        if self.key.byte_length() == 0:
            return SERIES_REJECT_EMPTY_KEY
        for i in range(len(self.points)):
            if not isfinite(self.points[i].value):
                return SERIES_REJECT_NONFINITE
            if i > 0 and self.points[i].ordinal <= self.points[i - 1].ordinal:
                return SERIES_REJECT_UNORDERED
        return SERIES_OK

    def values(self) -> List[Float64]:
        """The values alone, in ordinal order — what the estimators consume."""
        var out = List[Float64]()
        for i in range(len(self.points)):
            out.append(self.points[i].value)
        return out^

    def since(self, baseline_ordinal: Int64) -> Series:
        """The sub-series at or after `baseline_ordinal`, same key.

        This is how an ACKNOWLEDGED change point narrows the in-control window:
        the detector keeps a baseline ordinal, not a copy of the data, so a
        refit always reads whatever the source now holds.
        """
        var out = Series(self.key)
        for i in range(len(self.points)):
            if self.points[i].ordinal >= baseline_ordinal:
                out.points.append(self.points[i].copy())
        return out^


trait SeriesSource(Movable, Deinitable):
    """THE SEAM. What the detector needs from whatever produces series.

    ★ THIS IS THE WHOLE CONTRACT WITH THE METRICS SYSTEM, AND IT NAMES NOTHING
    THAT SYSTEM OWNS. Three verbs over `Int`, `String` and `Series` — no metric
    point type, no attribute set, no table, no format, no catalog, no engine. A
    metrics-backed implementation, a bench-artifact-backed one and an in-memory
    fake are all the same shape to the detector, so the detector can be
    validated against the third while the first is still being designed.

    ⚠ THE KEY IS THE PRODUCER'S TO COMPOSE, AND THIS PACKAGE WILL NEVER PARSE
    IT. A series key means 'everything that, if it changed, would start a new
    series'. Composing it is the producer's judgement, because only the
    producer knows what its own dimensions are. If this package ever grew a
    key parser it would have taken over that judgement, and a change to the
    producer's dimensions would then be a change here.

    `mut self` throughout: a real source holds a cursor, a connection or a read
    session, and enumerating is allowed to advance it.
    """

    def series_count(mut self) raises -> Int:
        """How many series this source can produce. RAISES if it cannot say —
        never 0, which is indistinguishable from 'the source is empty'."""
        ...

    def series_key_at(mut self, index: Int) raises -> String:
        """The opaque key of series `index`, `0 <= index < series_count()`."""
        ...

    def load_series(mut self, key: String) raises -> Series:
        """The full series for `key`, in ordinal order. RAISES if `key` is not
        one this source produces — an empty series is a real answer only for a
        key that exists."""
        ...
