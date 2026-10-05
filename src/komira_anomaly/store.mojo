# =============================================================================
# komira_anomaly.store — THE STORE SEAM: WHERE A POSTED POINT GOES TO REST.
# =============================================================================
#
# ★ WHY THERE IS A SECOND SEAM WHEN `SeriesSource` ALREADY EXISTS.
# `SeriesSource` is a READ seam: it answers 'what series do you have, and what
# is in them'. The post-a-point path needs one more verb — APPEND — and it needs
# it for a reason that is not convenience:
#
#   ⛔ A POINT THAT WAS JUDGED BUT NOT STORED IS INVISIBLE TO REPLAY, AND A
#   MONITOR REBUILT FROM THE STORE WILL THEN HOLD DIFFERENT STATE FROM THE ONE
#   THAT JUDGED IT. Running bounds are accumulated state; if the accumulation
#   and the durable record can disagree, then after any restart the detector's
#   idea of normal is a thing no stored data supports, and no reader can ever
#   reconstruct why an anomaly was reported. So the order is STORE, THEN JUDGE, and a
#   store that raises means nothing was judged — see
#   `AnomalyMonitor.observe_and_store`.
#
# ── ⛔ WHAT THIS FILE DELIBERATELY DOES NOT NAME ─────────────────────────────
#
# The at-rest format belongs to the producer — time-partitioned Parquet in
# object store with manifest replay, say. NOTHING HERE NAMES ANY OF THAT.
# No file, no partition, no manifest, no bucket, no catalog, no engine, no
# compression, no schema. The seam is three verbs over `Int64`, `Float64` and an
# opaque `String`, exactly as `SeriesSource` is, because a seam that named the
# format would have to be redesigned the week the format lands.
#
# What the seam DOES assume, and it is the whole of what it assumes:
#
#   * an appended point is durable enough that `load_series` will return it;
#   * `load_series` returns points IN ORDINAL ORDER;
#   * replaying a series through the monitor reconstructs the same state the
#     live path built. That is the manifest-replay property stated without the
#     word manifest, and `tests/test_store_seam.mojo` proves it by running both
#     and comparing.
#
# ── ⚠ AND WHAT IT IS NOT: A RETENTION POLICY ────────────────────────────────
#
# `load_series` may legitimately return FEWER points than were appended — a
# store with retention, or a partition that has aged out. That is not an error
# and the seam does not forbid it. It IS a fact a rehydrated monitor has to live
# with: bounds rebuilt from a truncated replay are bounds over a shorter
# history, and `rehydrate` reports how many points it actually replayed so a
# caller can tell the difference rather than assume.
#
# Encapsulation: value types only, ZERO UnsafePointer, no wildcard origins.
# =============================================================================

from std.collections.dict import Dict

from komira_anomaly.series import Series, SeriesSource


trait MeasurementStore(SeriesSource):
    """THE WRITE HALF. A `MeasurementStore` is a `SeriesSource` that also
    accepts points, so anything that can be written can be replayed and driven
    through the existing generic `evaluate_source` with no adapter.

    ⚠ `append_point` MAY REJECT, AND REJECTING IS THE POINT. A store that
    silently drops a point it could not write hands the caller a judgement about
    data nobody will ever be able to find again.
    """

    def append_point(
        mut self, key: String, ordinal: Int64, value: Float64
    ) raises:
        """Durably record one observation of `key`.

        RAISES rather than returning a status: this is on the path where the
        alternative is a judged-but-unstored point, and a status code is a
        thing a caller can forget to read.
        """
        ...


struct InMemoryPointStore(MeasurementStore, Copyable):
    """The reference conformer: everything the seam promises, in a Dict.

    ⚠ THIS IS NOT A STORAGE IMPLEMENTATION AND MUST NEVER BECOME ONE. It exists
    so the online detector is testable, and so the track building the real
    at-rest format has an executable statement of what its own conformer has to
    do. It keeps every point in memory forever, has no durability of any kind,
    and would be a serious bug in production.

    It lives in the LIBRARY rather than in a test file on purpose: a conformer
    that only exists inside one test proves the trait is implementable by that
    test, not that it is implementable.
    """

    var _keys: List[String]
    var _index: Dict[String, Int]
    var _series: List[Series]
    var appended: Int

    def __init__(out self):
        self._keys = []
        self._index = Dict[String, Int]()
        self._series = []
        self.appended = 0

    def append_point(
        mut self, key: String, ordinal: Int64, value: Float64
    ) raises:
        if key.byte_length() == 0:
            # The same refusal `Series.validate` makes, made EARLIER — an empty
            # key cannot address a series, so there is nowhere for this point to
            # go and inventing a place for it is worse than refusing.
            raise Error(
                String("komira_anomaly: append_point with an empty series key")
            )
        if key in self._index:
            var at = self._index[key]
            var n = self._series[at].count()
            if n > 0 and ordinal <= self._series[at].points[n - 1].ordinal:
                # ⛔ ORDER IS THE SEAM'S PROMISE, SO IT IS CHECKED ON THE WAY IN.
                # `load_series` promises ordinal order; a store that accepted an
                # out-of-order append would either have to sort on read (hiding
                # a producer bug forever) or break the promise.
                raise Error(
                    String("komira_anomaly: append_point out of order for '")
                    + key
                    + String("': ordinal ")
                    + String(ordinal)
                    + String(" is not after ")
                    + String(self._series[at].points[n - 1].ordinal)
                )
            self._series[at].append(ordinal, value)
        else:
            var s = Series(key)
            s.append(ordinal, value)
            self._index[key] = len(self._keys)
            self._keys.append(key)
            self._series.append(s^)
        self.appended += 1

    def series_count(mut self) raises -> Int:
        return len(self._keys)

    def series_key_at(mut self, index: Int) raises -> String:
        if index < 0 or index >= len(self._keys):
            raise Error(
                String("komira_anomaly: series index ")
                + String(index)
                + String(" out of range 0..")
                + String(len(self._keys))
            )
        return self._keys[index]

    def load_series(mut self, key: String) raises -> Series:
        if key not in self._index:
            # An empty series is a real answer for a key that EXISTS; for one
            # that does not it would be a lie the caller cannot detect.
            raise Error(
                String("komira_anomaly: no series '")
                + key
                + String("' in this store")
            )
        return self._series[self._index[key]].copy()
