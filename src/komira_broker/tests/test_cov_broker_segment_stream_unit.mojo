# =============================================================================
# tests/test_cov_broker_segment_stream_unit.mojo
#   The broker split reader's segment-stream decoder: every malformed
#   stream is refused by name.
# =============================================================================
#
#   One flushed segment is overwritten with a crafted stream (and a valid
#   footer) before each scan: no continuation marker, metadata past the
#   end, a frame past the end, a DictionaryBatch frame, an unknown message
#   header, and no EOS marker are each refused.
# =============================================================================

from std.testing import assert_equal, assert_raises, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Schema
from komira_scan_resolver.scan_source_resolver import ScanRequest
from komira_scan_source.scan_params import ScanParams
from komira_scan_source.scan_resolver import resolve_for_execution

from komira_broker.broker_core import (
    BrokerCore,
    BrokerTopicConfig,
    SegmentFooter,
    _topic_config_key,
)
from komira_broker.broker_scan_binding import BROKER_PARAM_TOPIC
from komira_broker.broker_scan_kind import BrokerScanRuntime
from komira_broker.consume_core import ConsumeCore
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


def _poll_once(store: _Store, topic: String) raises:
    var rt = BrokerScanRuntime[_Store](store.clone(), String(_C))
    var req = _req(store, topic)
    var plan = rt.plan_splits(req)
    var reader = rt.open_split(req, plan.splits[0])
    _ = reader.poll(Int64(1 << 20), Int64(1 << 30))


# ---- malformed segment streams ------------------------------------------------------------


def _u32_at(b: List[UInt8], at: Int) -> Int:
    return (
        Int(b[at])
        | (Int(b[at + 1]) << 8)
        | (Int(b[at + 2]) << 16)
        | (Int(b[at + 3]) << 24)
    )


def _prefix(b: List[UInt8], n: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(n):
        out.append(b[i])
    return out^


def _header_type_at(stream: List[UInt8], frame: Int) raises -> Int:
    """The byte offset of the Message `header_type` field of the frame at
    `frame` (flatbuffer: root offset -> table -> vtable slot 1)."""
    var meta = frame + 8
    var table = meta + _u32_at(stream, meta)
    var soff = _u32_at(stream, table)
    var vtable = table - soff
    var field = Int(stream[vtable + 6]) | (Int(stream[vtable + 7]) << 8)
    assert_true(field > 0)
    return table + field


def _with_stream(store: _Store, key: String, var stream: List[UInt8]) raises:
    var obj = stream^
    var footer = SegmentFooter(Int64(0), Int64(0), Int64(0), UInt32(0)).encode()
    for i in range(len(footer)):
        obj.append(footer[i])
    _ = store.put(Path.parse(key), obj)


def test_malformed_segment_streams() raises:
    var store = _Store()
    var core = _topic(store, "t")
    core.buffer_batch(_batch(Int64(0), 4), Int64(1))
    _ = core.flush(Int64(1))
    var cc = ConsumeCore[_Store](
        segment_store=store.clone(),
        manifest=_manifest(store, "t"),
        cluster=String(_C),
        topic=String("t"),
        partition=Int64(0),
    )
    var seg = cc.resolve_index()[0].copy()
    var key = String(seg.object_key)
    var stream = cc.read_segment(seg)^.take_stream_bytes()
    # Layout: schema frame, record-batch frame, 8-byte EOS.
    var schema_meta = _u32_at(stream, 4)
    var rb = 8 + schema_meta
    assert_equal(_u32_at(stream, rb), 0xFFFFFFFF)
    var rb_meta = _u32_at(stream, rb + 4)

    var zero = List[UInt8]()
    for _ in range(8):
        zero.append(UInt8(0))
    _with_stream(store, key, zero^)
    with assert_raises(contains="no continuation marker at byte 0"):
        _poll_once(store, "t")

    var past = List[UInt8]()
    for _ in range(4):
        past.append(UInt8(0xFF))
    past.append(UInt8(100))
    for _ in range(3):
        past.append(UInt8(0))
    _with_stream(store, key, past^)
    with assert_raises(contains="metadata past end at byte 0"):
        _poll_once(store, "t")

    _with_stream(store, key, _prefix(stream, rb + 8 + rb_meta + 1))
    with assert_raises(contains="frame past end at byte " + String(rb)):
        _poll_once(store, "t")

    var ht = _header_type_at(stream, rb)
    assert_equal(Int(stream[ht]), 3)
    var dict_frame = stream.copy()
    dict_frame[ht] = UInt8(2)
    _with_stream(store, key, dict_frame^)
    with assert_raises(contains="a broker segment carried a DictionaryBatch frame"):
        _poll_once(store, "t")
    var tensor = stream.copy()
    tensor[ht] = UInt8(4)
    _with_stream(store, key, tensor^)
    with assert_raises(contains="unexpected message tag 4"):
        _poll_once(store, "t")

    _with_stream(store, key, _prefix(stream, len(stream) - 8))
    with assert_raises(contains="stream ended without EOS"):
        _poll_once(store, "t")


def main() raises:
    test_malformed_segment_streams()
    print("[OK] test_cov_broker_segment_stream_unit")
