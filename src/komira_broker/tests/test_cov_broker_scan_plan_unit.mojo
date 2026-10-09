# =============================================================================
# tests/test_cov_broker_scan_plan_unit.mojo
#   The broker scan kind's binding validation and plan / open refusals, the
#   read_committed aborted list, and the start clamp at the log start.
# =============================================================================
#
#   1. broker_parse_i64_list / broker_canonical_partitions /
#      broker_topic_binding refuse an empty element, a non-integer, an empty
#      partition list, a negative partition, an empty topic, and a missing or
#      mistyped required param.
#   2. build_binding refuses a missing topic and a topic that declares the
#      column the scan appends.
#   3. plan_splits refuses a binding with no partition, misaligned start
#      offsets, a schema that does not end in __partition, and a topic whose
#      column count changed; discover_splits is refused by name.
#   4. open_split refuses a split key with no partition, a partition the
#      scan does not name, and a split with no stop.
#   5. read_committed: two aborted transactions are listed once each, in
#      offset order, separated by ';'.
#   6. A start offset below the log start is planned from the log start.
# =============================================================================

from std.testing import assert_equal, assert_raises, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Schema
from komira_scan_resolver.scan_source_resolver import ScanRequest
from komira_scan_resolver.scan_split import ScanSplit
from komira_scan_source.scan_params import ScanParams
from komira_scan_source.scan_resolver import resolve_for_execution

from komira_broker.broker_core import BrokerCore, BrokerTopicConfig, _topic_config_key
from komira_broker.broker_scan_binding import (
    BROKER_ISOLATION_READ_COMMITTED,
    BROKER_PARAM_ISOLATION,
    BROKER_PARAM_PARTITIONS,
    BROKER_PARAM_START_OFFSET,
    BROKER_PARAM_START_OFFSETS,
    BROKER_PARAM_TOPIC,
    BROKER_PARTITION_COLUMN,
    broker_canonical_partitions,
    broker_parse_i64_list,
    broker_scan_binding,
    broker_topic_binding,
)
from komira_broker.broker_scan_kind import (
    BROKER_RESOLVED_ABORTED,
    BrokerScanRuntime,
    _partition_of_split_key,
    broker_resolved_key,
)
from komira_broker.broker_split_reader import (
    broker_position_offset,
    broker_split_position,
)
from komira_broker.txn_control import TxnControlStore
from komira_objectstore.cas_manifest import CasManifestStore, RetryPolicy
from komira_objectstore.path import Path
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)


comptime _Store = SharedInMemoryConditionalStore
comptime _C = "bsp"


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


def _config(store: _Store, topic: String, var schema: Schema) raises:
    var cfg = BrokerTopicConfig(1, List[String](), schema^)
    _ = store.put(Path.parse(_topic_config_key(String(_C), topic)), cfg.encode())


def _manifest(store: _Store, topic: String) -> CasManifestStore[_Store]:
    return CasManifestStore[_Store](
        store=store.clone(),
        prefix=String(_C) + "/_meta/topics/" + topic + "/0",
        retry=RetryPolicy.fast_test(),
    )


def _core(store: _Store, topic: String) -> BrokerCore[_Store]:
    return BrokerCore[_Store](
        segment_store=store.clone(),
        manifest=_manifest(store, topic),
        cluster=String(_C),
        topic=topic,
        partition=Int64(0),
        broker_id=String("b"),
    )


def _rt(store: _Store) -> BrokerScanRuntime[_Store]:
    return BrokerScanRuntime[_Store](store.clone(), String(_C))


def _params(topic: String) -> ScanParams:
    var p = ScanParams()
    p.put_str(String(BROKER_PARAM_TOPIC), String(topic))
    return p^


# ---- 1. binding validation ------------------------------------------------------------


def test_binding_validation() raises:
    assert_equal(len(broker_parse_i64_list("", "partitions")), 0)
    with assert_raises(contains="'partitions' has an empty element in '1,,2'"):
        _ = broker_parse_i64_list("1,,2", "partitions")
    with assert_raises(contains="'partitions' element 'x' is not an integer"):
        _ = broker_parse_i64_list("1, x", "partitions")
    with assert_raises(contains="'partitions' names no partition"):
        _ = broker_canonical_partitions(List[Int64]())
    var neg = List[Int64]()
    neg.append(Int64(2))
    neg.append(Int64(-1))
    with assert_raises(contains="partition -1 is negative"):
        _ = broker_canonical_partitions(neg)
    var p = ScanParams()
    p.put_str(String(BROKER_PARAM_TOPIC), "")
    p.put_str(String(BROKER_PARAM_PARTITIONS), "0")
    with assert_raises(contains="'topic' is empty"):
        _ = broker_topic_binding(p, _schema())
    var missing = ScanParams()
    missing.put_str(String(BROKER_PARAM_TOPIC), "t")
    with assert_raises(contains="required param 'partitions' is missing"):
        _ = broker_topic_binding(missing, _schema())
    var typed = ScanParams()
    typed.put_i64(String(BROKER_PARAM_TOPIC), Int64(4))
    typed.put_str(String(BROKER_PARAM_PARTITIONS), "0")
    with assert_raises(contains="param 'topic' has the wrong type"):
        _ = broker_topic_binding(typed, _schema())
    with assert_raises(contains="split key 'nokey' names no partition"):
        _ = _partition_of_split_key("nokey")
    assert_equal(_partition_of_split_key("a/b/12"), Int64(12))


# ---- 2-4. build, plan and open refusals -------------------------------------------------


def test_build_plan_and_open_refusals() raises:
    var store = _Store()
    _config(store, "t", _schema())
    var core = _core(store, "t")
    _ = core.produce(_batch(Int64(0), 3), Int64(1000))
    _ = core.flush_if_buffered(Int64(1000))
    var rt = _rt(store)
    with assert_raises(contains="required param 'topic' is missing"):
        _ = rt.build_binding(ScanParams())
    var bad_schema = Schema(
        names=[String("val"), String(BROKER_PARTITION_COLUMN)],
        arrow_types=[ArrowType.INT64.type_id, ArrowType.INT64.type_id],
        dtypes=[DType.int64, DType.int64],
        nullables=[False, False],
    )
    _config(store, "own_part", bad_schema^)
    with assert_raises(contains="topic 'own_part' declares a column named '__partition'"):
        _ = rt.build_binding(_params("own_part"))

    var good = rt.build_binding(_params("t"))
    var none = good.copy()
    none.params.put_str(String(BROKER_PARAM_PARTITIONS), "")
    with assert_raises(contains="binding 't' names no partition"):
        _ = rt.plan_splits(ScanRequest(none^))
    var mis = good.copy()
    mis.params.put_str(String(BROKER_PARAM_START_OFFSETS), "0,1")
    with assert_raises(contains="'start_offsets' is not aligned with 'partitions'"):
        _ = rt.plan_splits(ScanRequest(mis^))
    var plain = broker_scan_binding("t", Int64(0), Int64(0), _schema())
    with assert_raises(contains="does not end in the __partition INT64 column"):
        _ = rt.plan_splits(ScanRequest(plain^))
    with assert_raises(contains="is planned at a snapshot"):
        _ = rt.discover_splits(ScanRequest(good.copy()), List[String]())

    var req = ScanRequest(resolve_for_execution(rt, good.copy()))
    var plan = rt.plan_splits(req)
    assert_equal(len(plan.splits), 1)
    var nokey = ScanSplit("nokey", broker_split_position(Int64(0), List[Int64]()))
    with assert_raises(contains="split key 'nokey' names no partition"):
        _ = rt.open_split(req, nokey)
    var other = ScanSplit("t/7", broker_split_position(Int64(0), List[Int64]()))
    with assert_raises(contains="split 't/7' is not a partition of scan 't'"):
        _ = rt.open_split(req, other)
    var renamed = ScanSplit("u/0", broker_split_position(Int64(0), List[Int64]()))
    with assert_raises(contains="split 'u/0' is not a partition of scan 't'"):
        _ = rt.open_split(req, renamed)
    var open_ended = ScanSplit("t/0", broker_split_position(Int64(0), List[Int64]()))
    with assert_raises(contains="split 't/0' has no stop"):
        _ = rt.open_split(req, open_ended)

    # The topic gains a column after the binding was built.
    var wider = Schema(
        names=[String("val"), String("extra")],
        arrow_types=[ArrowType.INT64.type_id, ArrowType.INT64.type_id],
        dtypes=[DType.int64, DType.int64],
        nullables=[False, False],
    )
    _config(store, "t", wider^)
    with assert_raises(contains="binding 't' declares 1 topic columns; topic 't' has 2"):
        _ = rt.plan_splits(req)


# ---- 5. the read_committed aborted list ------------------------------------------------------


def test_read_committed_lists_each_aborted_txn_once() raises:
    var store = _Store()
    _config(store, "t", _schema())
    var ctl = TxnControlStore[_Store](store.clone(), String(_C))
    _ = ctl.begin("A", Int64(1), Int64(0))
    _ = ctl.begin("B", Int64(2), Int64(0))
    var core = _core(store, "t")
    # A@0 (2 rows), A@2 (2 rows), B@4 (1 row), a plain chunk @5.
    core.buffer_batch(_batch(Int64(0), 2), Int64(1))
    _ = core.flush_with_producer_txn(Int64(1), Int64(1), Int64(0), Int64(0), Int64(1), "A")
    core.buffer_batch(_batch(Int64(2), 2), Int64(2))
    _ = core.flush_with_producer_txn(Int64(2), Int64(1), Int64(0), Int64(2), Int64(3), "A")
    core.buffer_batch(_batch(Int64(4), 1), Int64(3))
    _ = core.flush_with_producer_txn(Int64(3), Int64(2), Int64(0), Int64(0), Int64(0), "B")
    core.buffer_batch(_batch(Int64(5), 1), Int64(4))
    _ = core.flush(Int64(4))
    _ = ctl.abort("A")
    _ = ctl.abort("B")
    var p = _params("t")
    p.put_str(String(BROKER_PARAM_ISOLATION), String(BROKER_ISOLATION_READ_COMMITTED))
    var rt = _rt(store)
    var plan = rt.plan_splits(ScanRequest(resolve_for_execution(rt, rt.build_binding(p))))
    assert_equal(
        plan.resolved.get_str(broker_resolved_key(String(BROKER_RESOLVED_ABORTED), Int64(0))),
        "A@0;B@4",
    )


# ---- 6. the start clamp -----------------------------------------------------------------------


def test_start_below_log_start_is_clamped() raises:
    var store = _Store()
    _config(store, "t", _schema())
    var core = _core(store, "t")
    for i in range(3):
        core.buffer_batch(_batch(Int64(3 * i), 3), Int64(i))
        _ = core.flush(Int64(i))
    var m = _manifest(store, "t")
    _ = m.advance_log_start(Int64(1), Int64(3), String(""))
    var p = _params("t")
    p.put_i64(String(BROKER_PARAM_START_OFFSET), Int64(1))
    var rt = _rt(store)
    var plan = rt.plan_splits(ScanRequest(resolve_for_execution(rt, rt.build_binding(p))))
    assert_equal(len(plan.splits), 1)
    assert_equal(broker_position_offset(plan.splits[0].start, "start"), Int64(3))
    assert_equal(plan.splits[0].est_rows, Int64(6))


def main() raises:
    test_binding_validation()
    test_build_plan_and_open_refusals()
    test_read_committed_lists_each_aborted_txn_once()
    test_start_below_log_start_is_clamped()
    print("[OK] test_cov_broker_scan_plan_unit")
