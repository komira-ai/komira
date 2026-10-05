# =============================================================================
# tests/test_broker_segment_key_collision_offline.mojo
#   Segment-PUT collision by default
# =============================================================================
#
# `broker_id` DEFAULTS to the shared literal "kafka-broker". If the `.seg`
# segment object were PUT UNCONDITIONALLY (`store.put`, last-writer-wins), two
# broker nodes left on the default `broker_id`, producing the SAME partition
# with the SAME `flush_ts` and a `_seg_counter` that BOTH start at 0, would
# mint an IDENTICAL segment key → one node's segment SILENTLY OVERWRITES the
# other's → one record set is LOST (a no-dup / no-loss VIOLATION).
#
# Segment-key uniqueness is STRUCTURAL (not by convention):
#   (a) a per-process `getpid` nonce is folded into every segment key, and
#   (b) the PUT is a CREATE (`If-None-Match: *`) that FAILS LOUD on a collision
#       and RE-KEYS (bumps `_seg_counter`) — never a silent overwrite.
#
# The case: two BrokerCores in ONE process (same pid → same nonce, so the
# in-process collision is faithfully reproducible) writing the SAME partition
# with the SAME `broker_id` ("kafka-broker") and the SAME flush_ts. An
# unconditional put with no nonce would leave ONE `.seg` object (overwrite) +
# one record set lost; the broker must leave TWO distinct `.seg` objects, both
# record sets independently readable.
#
# Hard-rule audit: no UnsafePointer in any signature, no wildcard origins,
# no unsafe_from_address / take_pointee.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Schema

from komira_broker.broker_core import BrokerCore
from komira_broker.consume_core import ConsumeCore

from komira_objectstore.cas_manifest import CasManifestStore, RetryPolicy
from komira_objectstore.path import Path
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)


comptime _Store = SharedInMemoryConditionalStore


def _partition_prefix(cluster: String, topic: String, pid: Int64) -> String:
    return cluster + "/_meta/topics/" + topic + "/" + String(pid)


def _make_int64_batch(base_val: Int64, n: Int) raises -> RecordBatch:
    var schema = Schema(
        names=[String("val")],
        arrow_types=[ArrowType.INT64.type_id],
        dtypes=[DType.int64],
        nullables=[False],
    )
    var arr = PrimitiveArray[DType.int64].allocate(n)
    var p = arr._typed_ptr_mut()
    for i in range(n):
        p.store[width=1](i, base_val + Int64(i))
    var col = Column.from_primitive[DType.int64](arr^)
    return RecordBatch.from_typed_columns_1(schema^, col^)


def _make_broker(
    store: _Store, cluster: String, topic: String, pid: Int64, broker_id: String
) raises -> BrokerCore[_Store]:
    var prefix = _partition_prefix(cluster, topic, pid)
    var manifest = CasManifestStore[_Store](
        store=store.clone(), prefix=prefix^, retry=RetryPolicy.fast_test()
    )
    return BrokerCore[_Store](
        segment_store=store.clone(),
        manifest=manifest^,
        cluster=cluster,
        topic=topic,
        partition=pid,
        broker_id=broker_id,
    )


def _count_seg_objects(
    store: _Store, cluster: String, topic: String, pid: Int64
) raises -> Int:
    """Count distinct `.seg` segment objects under the partition's segments
    prefix (`<cluster>/topics/<topic>/<pid>/segments/`)."""
    var seg_prefix = (
        cluster + "/topics/" + topic + "/" + String(pid) + "/segments/"
    )
    var res = store.list_with_delimiter(Path.parse(seg_prefix))
    var n = 0
    for i in range(len(res.objects)):
        if res.objects[i].location.endswith(".seg"):
            n += 1
    return n


# =============================================================================
# (1) Two same-default-broker_id flushes at the SAME ts must NOT collide:
#     both segments survive as distinct objects (an overwrite would leave one).
# =============================================================================


def test_default_broker_id_no_silent_overwrite() raises:
    print("[test_default_broker_id_no_silent_overwrite] starting...")
    var store = _Store()
    var cluster = String("c1")
    var topic = String("orders")
    var pid = Int64(0)
    var flush_ts = Int64(5000)

    # TWO brokers, BOTH on the default "kafka-broker" id (the trap), sharing
    # the backing store, producing the SAME partition.
    var broker_a = _make_broker(store, cluster, topic, pid, String("kafka-broker"))
    var broker_b = _make_broker(store, cluster, topic, pid, String("kafka-broker"))

    # Each produces ONE record set and flushes at the IDENTICAL flush_ts. Both
    # cores' `_seg_counter` start at 0 → both first-flushes mint counter 1 → the
    # legacy `<ts>-<broker_id>-<counter>` key is IDENTICAL.
    _ = broker_a.produce(_make_int64_batch(Int64(100), 4), flush_ts)
    var ack_a = broker_a.flush_if_buffered(flush_ts)
    _ = broker_b.produce(_make_int64_batch(Int64(200), 4), flush_ts)
    var ack_b = broker_b.flush_if_buffered(flush_ts)

    assert_true(ack_a, "broker A produced an ack")
    assert_true(ack_b, "broker B produced an ack")

    # FIX invariant: TWO distinct `.seg` objects exist (no silent overwrite).
    # An unconditional put would leave 1 (broker B's PUT clobbering broker A's
    # at the identical key) → RED.
    var seg_count = _count_seg_objects(store, cluster, topic, pid)
    assert_equal(seg_count, 2, "both segments survived as distinct objects")

    # The two acks reference DIFFERENT segment keys (re-key diverged them).
    var key_a = ack_a.value().segment_key
    var key_b = ack_b.value().segment_key
    assert_true(key_a != key_b, "the two acks landed at DISTINCT segment keys")
    print("[test_default_broker_id_no_silent_overwrite] PASS")


# =============================================================================
# (2) Both record sets are independently readable end-to-end (no loss). The
#     manifest of partition pid sees BOTH chunks; each segment's bytes survive.
# =============================================================================


def test_both_record_sets_readable_after_collision_avoidance() raises:
    print("[test_both_record_sets_readable...] starting...")
    var store = _Store()
    var cluster = String("c2")
    var topic = String("events")
    var pid = Int64(0)
    var flush_ts = Int64(9000)

    var broker_a = _make_broker(store, cluster, topic, pid, String("kafka-broker"))
    var broker_b = _make_broker(store, cluster, topic, pid, String("kafka-broker"))

    _ = broker_a.produce(_make_int64_batch(Int64(0), 3), flush_ts)
    var ack_a = broker_a.flush_if_buffered(flush_ts)
    _ = broker_b.produce(_make_int64_batch(Int64(50), 3), flush_ts)
    var ack_b = broker_b.flush_if_buffered(flush_ts)

    assert_true(ack_a, "A acked")
    assert_true(ack_b, "B acked")

    # Both segment objects are present + non-empty (B did not clobber A).
    var ka = ack_a.value().segment_key
    var kb = ack_b.value().segment_key
    var ba = store.get(Path.parse(ka))
    var bb = store.get(Path.parse(kb))
    assert_true(len(ba) > 0, "segment A bytes survive")
    assert_true(len(bb) > 0, "segment B bytes survive")

    # The partition manifest committed BOTH chunks (6 records total, no loss).
    var consume = ConsumeCore[_Store](
        segment_store=store.clone(),
        manifest=CasManifestStore[_Store](
            store=store.clone(),
            prefix=_partition_prefix(cluster, topic, pid),
            retry=RetryPolicy.fast_test(),
        ),
        cluster=cluster,
        topic=topic,
        partition=pid,
    )
    var hwm = consume.next_offset()
    assert_equal(hwm, Int64(6), "both 3-record chunks committed (no loss)")
    print("[test_both_record_sets_readable...] PASS")


def main() raises:
    test_default_broker_id_no_silent_overwrite()
    test_both_record_sets_readable_after_collision_avoidance()
    print("ALL test_broker_segment_key_collision_offline TESTS PASSED")
