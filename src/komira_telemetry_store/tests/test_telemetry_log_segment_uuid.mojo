# =============================================================================
# komira_telemetry_store/tests/test_telemetry_log_segment_uuid.mojo
#   A re-created log writer mints a fresh segment uuid, and the construction
#   nonce is the field that makes it fresh.
# =============================================================================
#
# Split out of test_telemetry_log_segment_writer.mojo to keep each file under
# 1000 lines. `_log_batch` and `_one_batch` are copies of the helpers there.
#
# HERMETIC: `SharedInMemoryConditionalStore`, no files, no cloud.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_collections.slab import Slab

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder
from komira_arrow.string_array import StringArray

from komira_objectstore.cas_manifest import RetryPolicy
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)

from komira_telemetry_store.keys import TELEMETRY_ROOT
from komira_telemetry_store.log_writer import (
    TELEMETRY_DEFAULT_CODEC,
    TELEMETRY_LOG_ROWS_PER_ROW_GROUP,
    TelemetryLogSegmentWriter,
)
from komira_telemetry_store.segment_entry import (
    TELEMETRY_UUID_BYTES,
    TelemetrySegmentEntry,
)


comptime _DAY_T0: Int64 = 1790812800_000_000_000  # 2026-10-01T00:00:00Z


def _log_batch(
    var messages: List[String], var ts_ns: List[Int64]
) raises -> RecordBatch:
    """A log batch of 8 columns: message, _source, timestamp, level, module,
    corr_id, flags, site_id. The writer needs only the `timestamp` column."""
    var n = len(messages)
    var sb = SchemaBuilder()
    sb.add_field(Field(String("message"), ArrowType.STRING, False))
    sb.add_field(Field(String("_source"), ArrowType.STRING, False))
    sb.add_field(Field(String("timestamp"), ArrowType.TIMESTAMP_NS, False))
    sb.add_field(Field(String("level"), ArrowType.STRING, False))
    sb.add_field(Field(String("module"), ArrowType.STRING, False))
    sb.add_field(Field(String("corr_id"), ArrowType.INT64, False))
    sb.add_field(Field(String("flags"), ArrowType.INT64, False))
    sb.add_field(Field(String("site_id"), ArrowType.INT64, False))
    var schema = sb.build()

    var sources = List[String](capacity=n)
    var levels = List[String](capacity=n)
    var modules = List[String](capacity=n)
    var i64s = List[Int64](capacity=n)
    for i in range(n):
        sources.append(String('{"m":"') + messages[i] + String('"}'))
        levels.append(String("INFO"))
        modules.append(String("telemetry"))
        i64s.append(Int64(i))

    var rb = RecordBatchBuilder.with_capacity(8)
    rb.add_column(Column.from_string(StringArray.from_strings(messages)))
    rb.add_column(Column.from_string(StringArray.from_strings(sources)))
    rb.add_column(
        Column.from_primitive_with_arrow_type[DType.int64](
            PrimitiveArray[DType.int64].from_list(ts_ns), ArrowType.TIMESTAMP_NS
        )
    )
    rb.add_column(Column.from_string(StringArray.from_strings(levels)))
    rb.add_column(Column.from_string(StringArray.from_strings(modules)))
    rb.add_column(
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(i64s.copy())
        )
    )
    rb.add_column(
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(i64s.copy())
        )
    )
    rb.add_column(
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(i64s^)
        )
    )
    return rb.build(schema^)


def _one_batch(var rb: RecordBatch) -> Slab[RecordBatch]:
    var s = Slab[RecordBatch](capacity=1)
    s.append(rb^)
    return s^



# =============================================================================
# CASE 12 — TWO WRITER LIFETIMES DO NOT SHARE A SEGMENT-UUID NAMESPACE.
#
# THE SHAPE THIS PREVENTS IS A PROCESS RESTART. `_next_uuid`'s counter starts at
# 0 in every process, so `(worker_disc, counter)` alone re-mints byte-identical
# uuids after a restart with the same `writer_id`, as happens when `writer_id`
# is derived from a stable node id. `merge_input_uuids` / `uuid_in_flat` key on
# this uuid, so a collision makes the dup-window skip drop the WRONG live
# segment.
#
# The two writers below differ in EXACTLY ONE FIELD — the nonce — and CASE 13 is
# the negative control that shows it is the field doing the work.
# =============================================================================


def _uuid_hex(u: InlineArray[UInt8, TELEMETRY_UUID_BYTES]) -> String:
    var hexd = "0123456789abcdef"
    var hb = hexd.as_bytes()
    var out = String("")
    for i in range(TELEMETRY_UUID_BYTES):
        out += chr(Int(hb[(Int(u[i]) >> 4) & 0xF]))
        out += chr(Int(hb[Int(u[i]) & 0xF]))
    return out^


def _one_line_publish(
    store: SharedInMemoryConditionalStore, writer_id: String, nonce: Int64
) raises -> TelemetrySegmentEntry:
    var w = TelemetryLogSegmentWriter[SharedInMemoryConditionalStore](
        store.clone(), writer_id.copy(), TELEMETRY_ROOT,
        TELEMETRY_DEFAULT_CODEC, TELEMETRY_LOG_ROWS_PER_ROW_GROUP,
        RetryPolicy.default(), UInt8(0), nonce,
    )
    var msgs = List[String]()
    var ts = List[Int64]()
    msgs.append(String("restart-line"))
    ts.append(_DAY_T0 + Int64(7))
    var entries = w.publish_batches(
        _one_batch(_log_batch(msgs^, ts^))
    )
    var e = entries[0].copy()
    _ = w^
    return e^


def test_12_a_recreated_writer_does_not_remint_the_same_segment_uuid() raises:
    var store = SharedInMemoryConditionalStore()
    # SAME writer_id, SAME worker_disc, SAME row content, SAME timestamp — the
    # restart shape. Only the construction nonce differs.
    var first = _one_line_publish(store, String("restarted"), Int64(1_000))
    var second = _one_line_publish(store, String("restarted"), Int64(2_000))
    assert_true(
        _uuid_hex(first.segment_uuid) != _uuid_hex(second.segment_uuid),
        "12: a writer re-created with the SAME writer_id and worker_disc must"
        " NOT re-mint the same segment uuid. The dup-window skip keys on this"
        " uuid, so a collision drops the wrong live segment's rows from every"
        " read. Got the same uuid twice: " + _uuid_hex(first.segment_uuid),
    )
    assert_true(
        first.object_key != second.object_key,
        "12: ...and therefore the object keys differ too. Identical uuids AND"
        " identical timestamps produce the same key, which is the second"
        " process OVERWRITING the first's data object",
    )
    _ = store^


def test_13_the_nonce_is_the_field_that_separates_them() raises:
    """NEGATIVE CONTROL for CASE 12. With the nonce held EQUAL, the two writers
    collide exactly as they did before the fix — which is what proves CASE 12
    measures the nonce and not some incidental difference between two
    constructions."""
    var store = SharedInMemoryConditionalStore()
    var first = _one_line_publish(store, String("collide"), Int64(4_242))
    var second = _one_line_publish(store, String("collide"), Int64(4_242))
    assert_equal(
        _uuid_hex(first.segment_uuid),
        _uuid_hex(second.segment_uuid),
        "13: with the SAME nonce the two writers MUST collide. If they do not,"
        " something other than the nonce is separating them and CASE 12 is not"
        " measuring what it claims",
    )
    _ = store^




def main() raises:
    test_12_a_recreated_writer_does_not_remint_the_same_segment_uuid()
    test_13_the_nonce_is_the_field_that_separates_them()
    print("PASS komira_telemetry_store.test_telemetry_log_segment_uuid (a")
    print("     re-created writer mints a fresh segment uuid; the nonce is the")
    print("     field that separates them)")
