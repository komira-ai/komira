# =============================================================================
# test_distinct_column_native_transparency.mojo
#
# Bridge round-trip gate for the output shape of the distinct breaker. It builds
# a RecordBatch shaped like that breaker's output by hand (no operator state is
# reached: this package depends on no operator), moves it through
# column_native_from_record_batch and record_batch_from_column_native, and
# asserts the result is byte-equal to the input. It proves the bridge keeps
# values, validity, offsets and schema flags for this shape; it does not prove
# that an operator's column-native result equals its RecordBatch result.
#
# The bridge round-trip is checked for distinct-output shapes (single
# Int64 key; composite (Int64, Int64) keys; + a STRING key to exercise the
# var-width path the distinct breaker carries as a key column).
# =============================================================================

from std.testing import TestSuite, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.string_array import StringArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import SchemaBuilder, Field

from komira_arrow_ipc.record_batch_compare import record_batch_byte_equal

from komira_engine_runtime.spill.column_native_shims import (
    column_native_from_record_batch,
    record_batch_from_column_native,
)


# =============================================================================
# §1 — Golden builders (distinct-drain-shaped output batches)
# =============================================================================


def _distinct_i64_key(keys: List[Int64]) raises -> RecordBatch:
    """One Int64 key column @0 — the shape DistinctState drains for a single
    Int64 distinct key."""
    var sb = SchemaBuilder()
    sb.add_field(Field(String("k0"), ArrowType.INT64, True))
    var schema = sb.build()
    var kl: List[Scalar[DType.int64]] = []
    for i in range(len(keys)):
        kl.append(keys[i])
    var kcol = Column.from_primitive[DType.int64](
        PrimitiveArray[DType.int64].from_list(kl)
    )
    return RecordBatch.from_typed_columns_1(schema^, kcol^)


def _distinct_composite_key(
    k0: List[Int64], k1: List[Int64]
) raises -> RecordBatch:
    """Two Int64 key columns — composite distinct key shape."""
    var sb = SchemaBuilder()
    sb.add_field(Field(String("k0"), ArrowType.INT64, True))
    sb.add_field(Field(String("k1"), ArrowType.INT64, True))
    var schema = sb.build()
    var l0: List[Scalar[DType.int64]] = []
    var l1: List[Scalar[DType.int64]] = []
    for i in range(len(k0)):
        l0.append(k0[i])
        l1.append(k1[i])
    var c0 = Column.from_primitive[DType.int64](
        PrimitiveArray[DType.int64].from_list(l0)
    )
    var c1 = Column.from_primitive[DType.int64](
        PrimitiveArray[DType.int64].from_list(l1)
    )
    return RecordBatch.from_typed_columns_2(schema^, c0^, c1^)


# =============================================================================
# §2 — BRIDGE TRANSPARENCY (byte-identity of the bridge round-trip adds)
# =============================================================================


def test_bridge_byte_identical_single_i64_key() raises:
    """Single Int64 distinct key round-trips byte-identical through the
    breaker-output bridge."""
    var keys: List[Int64] = [5, 10, 20, 25, 30]
    var golden = _distinct_i64_key(keys)
    var to_bridge = _distinct_i64_key(keys)
    var native = column_native_from_record_batch(to_bridge^)
    assert_true(native.num_rows() == 5, "row count preserved")
    assert_true(native.num_columns() == 1, "col count preserved")
    var restored = record_batch_from_column_native(native^)
    assert_true(
        record_batch_byte_equal(golden, restored),
        "Distinct drain bridge (single i64 key) must be byte-identical",
    )


def test_bridge_byte_identical_composite_key() raises:
    """Composite (Int64, Int64) distinct keys round-trip byte-identical."""
    var k0: List[Int64] = [1, 1, 2, 2, 3]
    var k1: List[Int64] = [1, 2, 0, 1, 9]
    var golden = _distinct_composite_key(k0, k1)
    var to_bridge = _distinct_composite_key(k0, k1)
    var native = column_native_from_record_batch(to_bridge^)
    assert_true(native.num_columns() == 2, "col count preserved")
    var restored = record_batch_from_column_native(native^)
    assert_true(
        record_batch_byte_equal(golden, restored),
        "Distinct drain bridge (composite i64 keys) byte-identical",
    )


def test_bridge_byte_identical_string_key() raises:
    """STRING distinct key (var-width) round-trips byte-identical through the
    breaker-output bridge — exercises the THSPLC var-width region path the
    distinct breaker carries as a key column."""

    def build() raises -> RecordBatch:
        var s = SchemaBuilder()
        s.add_field(Field(String("k0"), ArrowType.STRING, True))
        var schema = s.build()
        var names: List[String] = [
            String("alpha"),
            String(""),
            String("gamma"),
            String("delta"),
        ]
        var scol = Column.from_string(StringArray.from_strings(names))
        return RecordBatch.from_typed_columns_1(schema^, scol^)

    var golden = build()
    var to_bridge = build()
    var native = column_native_from_record_batch(to_bridge^)
    var restored = record_batch_from_column_native(native^)
    assert_true(
        record_batch_byte_equal(golden, restored),
        "Distinct drain bridge (string key) must be byte-identical",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
