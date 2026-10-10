# =============================================================================
# tests/test_cov_broker_split_reader_unit.mojo
#   The broker split reader: a segment of several frames is returned one
#   frame per poll, a poll after the end is the end again, the log start
#   moving past the cursor mid-read is refused, and a malformed position is
#   refused.
# =============================================================================
#
#   1. Two producer batches flushed together make one segment of two frames:
#      the first poll returns the first frame (its position the second
#      frame's first offset), the second poll the pending frame, then END,
#      and END again.
#   2. Retention moving the log start past the cursor between two polls is
#      BROKER_SCAN_LOG_START_MOVED.
#   3. A position whose length is not "offset + count + chunks" is
#      BROKER_SCAN_BAD_POSITION.
#   (The malformed segment streams are test_cov_broker_segment_stream_unit.)
# =============================================================================

from std.testing import assert_equal, assert_raises, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Schema
from komira_scan_resolver.scan_source_resolver import ScanRequest
from komira_scan_resolver.scan_split import (
    SPLIT_POLL_END,
    SPLIT_POLL_ROWS,
    SplitPosition,
)
from komira_scan_source.scan_params import ScanParams
from komira_scan_source.scan_resolver import resolve_for_execution

from komira_broker.broker_core import (
    BrokerCore,
    BrokerTopicConfig,
    _topic_config_key,
)
from komira_broker.broker_scan_binding import BROKER_PARAM_TOPIC, broker_scan_kind_id
from komira_broker.broker_scan_kind import BrokerScanRuntime
from komira_broker.broker_split_reader import (
    BROKER_POSITION_VERSION,
    broker_position_offset,
)
from komira_objectstore.cas_manifest import CasManifestStore, RetryPolicy
from komira_objectstore.path import Path
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)


comptime _Store = SharedInMemoryConditionalStore
comptime _C = "bsr"


def _schema() -> Schema:
    return Schema(
        names=[String("val")],
        arrow_types=[ArrowType.INT64.type_id],
        dtypes=[DType.int64],
        nullables=[False],
    )


def _batch(base_val: Int64, n: Int) raises -> RecordBatch:
    var arr = PrimitiveArray[DType.int64].allocate(n)
    var p = arr._typed_ptr_mut()
    for i in range(n):
        p.store[width=1](i, base_val + Int64(i))
    var col = Column.from_primitive[DType.int64](arr^)
    return RecordBatch.from_typed_columns_1(_schema(), col^)


def _manifest(store: _Store, topic: String) -> CasManifestStore[_Store]:
    return CasManifestStore[_Store](
        store=store.clone(),
        prefix=String(_C) + "/_meta/topics/" + topic + "/0",
        retry=RetryPolicy.fast_test(),
    )


def _topic(store: _Store, topic: String) raises -> BrokerCore[_Store]:
    var cfg = BrokerTopicConfig(1, List[String](), _schema())
    _ = store.put(Path.parse(_topic_config_key(String(_C), topic)), cfg.encode())
    return BrokerCore[_Store](
        segment_store=store.clone(),
        manifest=_manifest(store, topic),
        cluster=String(_C),
        topic=topic,
        partition=Int64(0),
        broker_id=String("b"),
    )


def _req(store: _Store, topic: String) raises -> ScanRequest:
    var p = ScanParams()
    p.put_str(String(BROKER_PARAM_TOPIC), String(topic))
    var rt = BrokerScanRuntime[_Store](store.clone(), String(_C))
    return ScanRequest(resolve_for_execution(rt, rt.build_binding(p)))


# ---- 1-2. frames, end, log start ------------------------------------------------------


def test_frames_end_and_log_start_moved() raises:
    var store = _Store()
    var core = _topic(store, "t")
    # Chunk 0: one segment of two frames (rows 0..2, 3..4); chunk 1: 5..6.
    core.buffer_batch(_batch(Int64(0), 3), Int64(1))
    core.buffer_batch(_batch(Int64(3), 2), Int64(1))
    _ = core.flush(Int64(1))
    core.buffer_batch(_batch(Int64(5), 2), Int64(2))
    _ = core.flush(Int64(2))
    var rt = BrokerScanRuntime[_Store](store.clone(), String(_C))
    var req = _req(store, "t")
    var plan = rt.plan_splits(req)
    var reader = rt.open_split(req, plan.splits[0])
    var a = reader.poll(Int64(1 << 20), Int64(1 << 30))
    assert_equal(a.status, SPLIT_POLL_ROWS)
    assert_equal(a.num_rows(), 3)
    assert_equal(broker_position_offset(a.position, "a"), Int64(3))
    var b = reader.poll(Int64(1 << 20), Int64(1 << 30))
    assert_equal(b.status, SPLIT_POLL_ROWS)
    assert_equal(b.num_rows(), 2)
    assert_equal(broker_position_offset(b.position, "b"), Int64(5))
    assert_equal(b.source_bytes, Int64(0))
    var c = reader.poll(Int64(1 << 20), Int64(1 << 30))
    assert_equal(c.num_rows(), 2)
    var d = reader.poll(Int64(1 << 20), Int64(1 << 30))
    assert_equal(d.status, SPLIT_POLL_END)
    assert_equal(broker_position_offset(d.position, "d"), Int64(7))
    var e = reader.poll(Int64(1 << 20), Int64(1 << 30))
    assert_equal(e.status, SPLIT_POLL_END)
    assert_equal(broker_position_offset(e.position, "e"), Int64(7))

    # The log start moves past the cursor (5, after chunk 0's two frames)
    # before chunk 1 is read.
    var r2 = rt.open_split(req, plan.splits[0])
    _ = r2.poll(Int64(1 << 20), Int64(1 << 30))
    _ = r2.poll(Int64(1 << 20), Int64(1 << 30))
    var m = _manifest(store, "t")
    _ = m.advance_log_start(Int64(2), Int64(7), String(""))
    with assert_raises(contains="BROKER_SCAN_LOG_START_MOVED"):
        _ = r2.poll(Int64(1 << 20), Int64(1 << 30))


# ---- 3. positions ------------------------------------------------------------------------


def test_malformed_position() raises:
    var b = List[UInt8]()
    for _ in range(13):
        b.append(UInt8(0))
    var pos = SplitPosition(broker_scan_kind_id(), BROKER_POSITION_VERSION, b^)
    with assert_raises(contains="BROKER_SCAN_BAD_POSITION: the cut position holds 13 bytes"):
        _ = broker_position_offset(pos, "cut")
    var short = SplitPosition(broker_scan_kind_id(), BROKER_POSITION_VERSION, List[UInt8]())
    with assert_raises(contains="the cut position holds 0 bytes"):
        _ = broker_position_offset(short, "cut")


def main() raises:
    test_frames_end_and_log_start_moved()
    test_malformed_position()
    print("[OK] test_cov_broker_split_reader_unit")
