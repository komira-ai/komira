# =============================================================================
# test_object_store_metric_sink_days.mojo
#   A flush that spans UTC days and fails on a later day retries only the days
#   that did not commit.
# =============================================================================
#
# Defect caught: a sink that keeps the whole buffer when the writer raises on
# day 2 after day 1 was committed. The retry then publishes day 1 again, and a
# duplicated counter delta is a wrong rate. Every claim is read back out of the
# manifests and the published Parquet row counts, not out of the sink's counters.
#
# Hermetic: an in-memory store with an injected, counted PUT failure.
# =============================================================================

from std.memory import ArcPointer
from std.testing import assert_equal, assert_true

from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)
from komira_objectstore import (
    CloneableConditionalWriteStore,
    CoalescePolicy,
    ConditionalWriteStore,
    ListResult,
    ObjectMeta,
    ObjectStore,
    WritePrecondition,
)
from komira_objectstore.path import Path

from komira_metrics.metric_point import MetricPoint, counter_point

from komira_telemetry_store.keys import (
    NS_PER_DAY,
    TELEMETRY_DATASET_METRICS,
    TELEMETRY_ROOT,
    day_string_from_ns,
)
from komira_telemetry_store.manifest import open_partition_manifest

from komira_log_index.object_store_metric_sink import ObjectStoreMetricSink


comptime _DAY_T0: Int64 = 1788307200_000_000_000  # 2026-09-02T00:00:00Z


struct _State(Movable):
    var log: List[String]
    var fail_put_from: Int
    var puts: Int

    def __init__(out self):
        self.log = List[String]()
        self.fail_put_from = -1
        self.puts = 0


struct DayStore(
    CloneableConditionalWriteStore,
    ConditionalWriteStore,
    ObjectStore,
    Movable,
    Deinitable,
):
    var _inner: SharedInMemoryConditionalStore
    var _st: ArcPointer[_State]

    def __init__(out self):
        self._inner = SharedInMemoryConditionalStore()
        self._st = ArcPointer[_State](_State())

    def __init__(
        out self,
        var inner: SharedInMemoryConditionalStore,
        var st: ArcPointer[_State],
    ):
        self._inner = inner^
        self._st = st^

    def clone(self) -> Self:
        return Self(self._inner.clone(), self._st.copy())

    def head(self, path: Path) raises -> ObjectMeta:
        return self._inner.head(path)

    def list_with_delimiter(self, prefix: Path) raises -> ListResult:
        return self._inner.list_with_delimiter(prefix)

    def coalesce_policy(self) -> CoalescePolicy:
        return self._inner.coalesce_policy()

    def conditional_put(
        self, path: Path, bytes: List[UInt8], precond: WritePrecondition
    ) raises -> ObjectMeta:
        self._st[].log.append(String("cond:") + path.raw())
        return self._inner.conditional_put(path, bytes, precond)

    def compare_and_swap(
        self, path: Path, bytes: List[UInt8], expected_version: String
    ) raises -> ObjectMeta:
        return self.conditional_put(
            path, bytes, WritePrecondition.if_match(expected_version)
        )

    def put(self, path: Path, bytes: List[UInt8]) raises -> ObjectMeta:
        self._st[].log.append(String("put:") + path.raw())
        var is_object = path.raw().endswith(String(".parquet"))
        if is_object:
            self._st[].puts += 1
        if (
            is_object
            and self._st[].fail_put_from >= 0
            and self._st[].puts > self._st[].fail_put_from
        ):
            raise Error("DayStore: injected put failure")
        return self._inner.put(path, bytes)

    def get_range(
        self, path: Path, start: Int64, length: Int64
    ) raises -> List[UInt8]:
        return self._inner.get_range(path, start, length)

    def get(self, path: Path) raises -> List[UInt8]:
        return self._inner.get(path)

    def delete(self, path: Path) raises -> None:
        self._inner.delete(path)

    def log(self) -> List[String]:
        return self._st[].log.copy()

    def fail_puts_after(self, n: Int):
        """Every object PUT after the first `n` fails."""
        self._st[].fail_put_from = n
        self._st[].puts = 0

    def heal(self):
        self._st[].fail_put_from = -1



def _live_rows(store: DayStore, day_ns: Int64) raises -> Int64:
    var m = open_partition_manifest[DayStore](
        store,
        TELEMETRY_ROOT,
        TELEMETRY_DATASET_METRICS,
        day_string_from_ns(day_ns),
        String("node-a"),
    )
    var live = m.live_segments()
    var rows = Int64(0)
    for i in range(len(live)):
        rows += live[i].row_count
    return rows


def _two_day_points() -> List[MetricPoint]:
    var pts = List[MetricPoint]()
    var a = UInt64(_DAY_T0 + Int64(1_000_000))
    var b = UInt64(_DAY_T0 + NS_PER_DAY + Int64(1_000_000))
    # Interleaved on purpose: the day split must not depend on arrival order.
    pts.append(counter_point(UInt32(1), UInt32(1), UInt32(0), Int64(1), b, b))
    pts.append(counter_point(UInt32(2), UInt32(1), UInt32(0), Int64(2), a, a))
    return pts^


def test_01_a_failed_second_day_does_not_republish_the_first() raises:
    var store = DayStore()
    var sink = ObjectStoreMetricSink[DayStore](
        store.clone(), String("node-a")
    )
    _ = sink.offer_points(_two_day_points())
    # The first object PUT (the older day) lands; the second one fails.
    store.fail_puts_after(1)
    var raised = False
    try:
        _ = sink.flush_pending_now()
    except:
        raised = True
    assert_true(raised, "1: the day-2 PUT failure surfaces as a raise")
    assert_equal(_live_rows(store, _DAY_T0), Int64(1), "1: day 1 committed")
    assert_equal(
        _live_rows(store, _DAY_T0 + NS_PER_DAY),
        Int64(0),
        "1: day 2 did not",
    )
    assert_equal(
        sink.buffered_points(),
        1,
        "1: only the uncommitted day's point is still pending",
    )
    assert_equal(
        sink.points_published(), Int64(1), "1: and the committed one is counted"
    )

    store.heal()
    assert_equal(sink.flush_pending_now(), 1, "1: the retry publishes day 2")
    assert_equal(
        _live_rows(store, _DAY_T0),
        Int64(1),
        "1: day 1 holds ONE row after the retry, not a duplicate",
    )
    assert_equal(_live_rows(store, _DAY_T0 + NS_PER_DAY), Int64(1), "1: day 2")
    assert_equal(sink.buffered_points(), 0, "1: the buffer is drained")
    assert_equal(sink.points_published(), Int64(2), "1: two points in all")


def main() raises:
    test_01_a_failed_second_day_does_not_republish_the_first()
