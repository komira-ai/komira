"""`FlightBrokerData` on its own: produce acknowledgement, refusals, read-back.

  * a batch large enough to trip the broker's size flush inside `produce` is
    acknowledged with the offset of the segment that flush wrote, and its rows
    read back once (the size-triggered flush and the explicit flush `produce`
    forces must not turn a durable write into an error);
  * successive produces to a partition get consecutive base offsets;
  * every accessor refuses a topic that was never registered.
"""

from std.testing import assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Schema

from komira_flight_server import FlightBrokerData

# `_estimate_batch_bytes` counts 8 bytes per value plus 256: this many rows
# reach the 8 MiB size flush on their own.
comptime _ROWS_FOR_SIZE_FLUSH = 1024 * 1024


def _schema() -> Schema:
    return Schema(
        names=[String("val")],
        arrow_types=[ArrowType.INT64.type_id],
        dtypes=[DType.int64],
        nullables=[False],
    )


def _batch(base: Int64, n: Int) raises -> RecordBatch:
    var values = List[Int64]()
    for i in range(n):
        values.append(base + Int64(i))
    var arr = PrimitiveArray[DType.int64].from_list(values)
    var col = Column.from_primitive[DType.int64](arr^)
    return RecordBatch.from_typed_columns_1(_schema(), col^)


def _total_rows(mut data: FlightBrokerData, topic: String) raises -> Int:
    var batches = data.read_batches(topic, 0, Int64(0))
    var n = 0
    for i in range(len(batches)):
        n += batches[i].num_rows()
    _ = batches^
    return n


def test_size_triggered_flush_is_acknowledged() raises:
    print("  test_size_triggered_flush_is_acknowledged...")
    var data = FlightBrokerData(String("flight-big"))
    data.add_topic(String("big"))
    var base = data.produce(String("big"), 0, _batch(Int64(0), _ROWS_FOR_SIZE_FLUSH), Int64(0))
    assert_equal(base, Int64(0))
    assert_equal(data.high_watermark(String("big"), 0), Int64(_ROWS_FOR_SIZE_FLUSH))
    assert_equal(_total_rows(data, String("big")), _ROWS_FOR_SIZE_FLUSH)
    print("    OK: a size-flushed batch is acknowledged once and stored once")


def test_consecutive_base_offsets() raises:
    print("  test_consecutive_base_offsets...")
    var data = FlightBrokerData(String("flight-offsets"))
    data.add_topic(String("t"))
    assert_equal(data.produce(String("t"), 0, _batch(Int64(0), 3), Int64(0)), Int64(0))
    assert_equal(data.produce(String("t"), 0, _batch(Int64(3), 4), Int64(0)), Int64(3))
    assert_equal(data.high_watermark(String("t"), 0), Int64(7))
    print("    OK: base offsets are 0 then 3; the watermark is 7")


def _raises_produce(mut data: FlightBrokerData) -> Bool:
    try:
        _ = data.produce(String("missing"), 0, _batch(Int64(0), 1), Int64(0))
    except:
        return True
    return False


def _raises_read(mut data: FlightBrokerData) -> Bool:
    try:
        _ = data.read_batches(String("missing"), 0, Int64(0))
    except:
        return True
    return False


def _raises_watermark(mut data: FlightBrokerData) -> Bool:
    try:
        _ = data.high_watermark(String("missing"), 0)
    except:
        return True
    return False


def _raises_schema_copy(data: FlightBrokerData) -> Bool:
    try:
        _ = data.schema_copy(String("missing"))
    except:
        return True
    return False


def test_unknown_topic_is_refused_everywhere() raises:
    print("  test_unknown_topic_is_refused_everywhere...")
    var data = FlightBrokerData(String("flight-unknown"))
    assert_true(_raises_produce(data), "produce")
    assert_true(_raises_read(data), "read_batches")
    assert_true(_raises_watermark(data), "high_watermark")
    assert_true(_raises_schema_copy(data), "schema_copy")
    print("    OK: produce, read_batches, high_watermark, schema_copy all raise")


def main() raises:
    print("== FlightBrokerData ==")
    test_size_triggered_flush_is_acknowledged()
    test_consecutive_base_offsets()
    test_unknown_topic_is_refused_everywhere()
    print("== FlightBrokerData PASSED (3 tests) ==")
