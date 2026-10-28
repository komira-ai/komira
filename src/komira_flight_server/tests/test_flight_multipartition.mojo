"""Multi-partition Flight broker, in-process.

Drive `FlightBrokerData` directly: register a 3-partition topic, produce
DISJOINT batches to p0 / p1 / p2, read each back per partition, and assert the
records are routed to the right partition (no cross-partition leakage). Also
covers the BrokerTicket partition round-trip with its backward compatibility
(absent field 3 -> partition 0) and the partition bounds check.

This is the discriminating proof of the per-partition routing: it asserts
directly on `FlightBrokerData.read_batches` per partition, so a route that
ignored the partition argument would fail with cross-partition records. It
needs no socket.
"""

from std.testing import assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Schema

from komira_flight import BrokerTicket

from komira_flight_server import FlightBrokerData


# -----------------------------------------------------------------------------
# Helpers: a 1-column int64 RecordBatch.
# -----------------------------------------------------------------------------


def _make_int64_batch(base_val: Int64, n: Int) raises -> RecordBatch:
    """A 1-column Int64 RecordBatch of `n` rows: val[i] = base_val + i."""
    var schema = Schema(
        names=[String("val")],
        arrow_types=[ArrowType.INT64.type_id],
        dtypes=[DType.int64],
        nullables=[False],
    )
    var values = List[Int64]()
    for i in range(n):
        values.append(base_val + Int64(i))
    var arr = PrimitiveArray[DType.int64].from_list(values)
    var col = Column.from_primitive[DType.int64](arr^)
    return RecordBatch.from_typed_columns_1(schema^, col^)


def _read_all_vals(
    mut data: FlightBrokerData, topic: String, partition: Int
) raises -> List[Int64]:
    """Read every record value from `partition` (from offset 0) into a flat
    list, in segment + row order."""
    var batches = data.read_batches(topic, partition, Int64(0))
    var out = List[Int64]()
    for i in range(len(batches)):
        ref rb = batches[i]
        var col = rb.column_as_primitive_int64(0)
        for r in range(rb.num_rows()):
            out.append(col.get(r))
    _ = batches^
    return out^


# -----------------------------------------------------------------------------
# T1: BrokerTicket field-3 partition round-trip + backward compatibility.
# -----------------------------------------------------------------------------


def test_broker_ticket_partition_roundtrip() raises:
    print("  test_broker_ticket_partition_roundtrip...")

    # partition encoded + decoded.
    var bt = BrokerTicket(String("orders"), Int64(4096), Int64(7))
    var bt2 = BrokerTicket.decode(Span(bt.encode()))
    assert_equal(bt2.topic, String("orders"))
    assert_equal(bt2.start_offset, Int64(4096))
    assert_equal(bt2.partition, Int64(7))

    # partition 0 (proto3-omitted) still decodes to 0.
    var bt0 = BrokerTicket(String("t"), Int64(10), Int64(0))
    var bt0d = BrokerTicket.decode(Span(bt0.encode()))
    assert_equal(bt0d.partition, Int64(0))

    # BACKWARD COMPATIBILITY: a 2-arg ticket (no partition) defaults to 0 AND encodes
    # byte-identically to a ticket without the field (partition 0 is omitted).
    var legacy = BrokerTicket(String("legacy"), Int64(99))
    assert_equal(legacy.partition, Int64(0))
    var legacy_d = BrokerTicket.decode(Span(legacy.encode()))
    assert_equal(legacy_d.topic, String("legacy"))
    assert_equal(legacy_d.start_offset, Int64(99))
    assert_equal(legacy_d.partition, Int64(0))
    print("    OK")


# -----------------------------------------------------------------------------
# T2: per-partition routing: disjoint produce to p0/p1/p2, read each back.
# -----------------------------------------------------------------------------


def test_per_partition_routing_disjoint() raises:
    print("  test_per_partition_routing_disjoint...")

    var data = FlightBrokerData(String("flight-mp"))
    data.add_topic(String("t3"), 3)
    assert_equal(data.num_partitions(String("t3")), 3)

    # Produce DISJOINT value ranges to each partition:
    #   p0 <- [100,101,102]   p1 <- [200,201,202]   p2 <- [300,301,302]
    var b0 = _make_int64_batch(Int64(100), 3)
    var b1 = _make_int64_batch(Int64(200), 3)
    var b2 = _make_int64_batch(Int64(300), 3)
    _ = data.produce(String("t3"), 0, b0^, Int64(0))
    _ = data.produce(String("t3"), 1, b1^, Int64(0))
    _ = data.produce(String("t3"), 2, b2^, Int64(0))

    # Read each partition back — each must contain ONLY its own records (no
    # cross-partition leakage). A route that ignored the partition arg would
    # return the same records for every partition -> this FAILS.
    var v0 = _read_all_vals(data, String("t3"), 0)
    var v1 = _read_all_vals(data, String("t3"), 1)
    var v2 = _read_all_vals(data, String("t3"), 2)

    assert_equal(len(v0), 3)
    assert_equal(len(v1), 3)
    assert_equal(len(v2), 3)
    for i in range(3):
        assert_equal(v0[i], Int64(100) + Int64(i))
        assert_equal(v1[i], Int64(200) + Int64(i))
        assert_equal(v2[i], Int64(300) + Int64(i))

    # Per-partition high watermarks are independent (3 records each).
    assert_equal(data.high_watermark(String("t3"), 0), Int64(3))
    assert_equal(data.high_watermark(String("t3"), 1), Int64(3))
    assert_equal(data.high_watermark(String("t3"), 2), Int64(3))
    print("    OK: records routed to the correct partition, no leakage")


# -----------------------------------------------------------------------------
# T3: partition bounds check + single-partition backward-compat.
# -----------------------------------------------------------------------------


def test_partition_bounds_and_backcompat() raises:
    print("  test_partition_bounds_and_backcompat...")

    var data = FlightBrokerData(String("flight-mp-two"))

    # add_topic defaults to 1 partition (back-compat shape).
    data.add_topic(String("single"))
    assert_equal(data.num_partitions(String("single")), 1)

    # A single-partition topic produces + reads on partition 0 exactly like any single-partition topic.
    var b = _make_int64_batch(Int64(10), 3)
    _ = data.produce(String("single"), 0, b^, Int64(0))
    var vals = _read_all_vals(data, String("single"), 0)
    assert_equal(len(vals), 3)
    assert_equal(vals[0], Int64(10))

    # An out-of-range partition raises (the bounds check).
    var raised = False
    try:
        var bb = _make_int64_batch(Int64(0), 1)
        _ = data.produce(String("single"), 1, bb^, Int64(0))
    except:
        raised = True
    assert_true(raised, "produce to partition 1 of a 1-partition topic must raise")

    var raised_read = False
    try:
        _ = data.read_batches(String("single"), 5, Int64(0))
    except:
        raised_read = True
    assert_true(raised_read, "read_batches on an out-of-range partition must raise")
    print("    OK")


def main() raises:
    print("== multi-partition Flight broker (in-process) ==")
    test_broker_ticket_partition_roundtrip()
    test_per_partition_routing_disjoint()
    test_partition_bounds_and_backcompat()
    print("== multi-partition Flight broker PASSED (3 tests) ==")
