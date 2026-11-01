# =============================================================================
# test_asof_join_probe_column_native_transparency.mojo
#
# Bridge round-trip gate for the output shape of the asof_join_probe breaker. It builds
# a RecordBatch shaped like that breaker's output by hand (no operator state is
# reached: this package depends on no operator), moves it through
# column_native_from_record_batch and record_batch_from_column_native, and
# asserts the result is byte-equal to the input. It proves the bridge keeps
# values, validity, offsets and schema flags for this shape; it does not prove
# that an operator's column-native result equals its RecordBatch result.
#
# ASOF mirrors the JOIN scope (B.1): the build's drain is None; the breaker
# OUTPUT is the per-batch probe emit. The asof probe emits the probe temporal
# key (Int64 @0) ⊕ each build-payload column (Int64), in payload-pack order
# (0..3 payloads). The bridge round-trip is checked for those output shapes.
# =============================================================================

from std.testing import TestSuite, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import SchemaBuilder, Field, RecordBatchBuilder

from komira_arrow_ipc.record_batch_compare import record_batch_byte_equal

from komira_engine_runtime.spill.column_native_shims import (
    column_native_from_record_batch,
    record_batch_from_column_native,
)


def _i64_prim(
    var vals: List[Scalar[DType.int64]]
) raises -> PrimitiveArray[DType.int64]:
    return PrimitiveArray[DType.int64].from_list(vals^)


def test_bridge_byte_identical_asof_temp_only() raises:
    """The 0-payload asof emit (temporal key only — INNER forward match, no
    build payload) round-trips byte-identical through the breaker-output
    bridge."""
    var sb = SchemaBuilder()
    sb.add_field(Field(String("atemp"), ArrowType.INT64, False))
    var schema = sb.build()
    var sb2 = SchemaBuilder()
    sb2.add_field(Field(String("atemp"), ArrowType.INT64, False))
    var schema2 = sb2.build()
    var temp: List[Scalar[DType.int64]] = [100, 200, 250, 300]
    var temp2: List[Scalar[DType.int64]] = [100, 200, 250, 300]
    var rbb = RecordBatchBuilder.with_capacity(1)
    rbb.add_column(Column.from_primitive[DType.int64](_i64_prim(temp^)))
    var golden = rbb.build(schema^)
    var rbb2 = RecordBatchBuilder.with_capacity(1)
    rbb2.add_column(Column.from_primitive[DType.int64](_i64_prim(temp2^)))
    var to_bridge = rbb2.build(schema2^)

    var native = column_native_from_record_batch(to_bridge^)
    assert_true(native.num_rows() == 4, "row count preserved")
    assert_true(native.num_columns() == 1, "col count preserved")
    var restored = record_batch_from_column_native(native^)
    assert_true(
        record_batch_byte_equal(golden, restored),
        "asof probe emit bridge (temporal key only) must be byte-identical",
    )


def _asof_3col(
    var t: List[Scalar[DType.int64]],
    var p0: List[Scalar[DType.int64]],
    var p1: List[Scalar[DType.int64]],
) raises -> RecordBatch:
    """(atemp, p0, p1) Int64 emit shape (2-payload asof)."""
    var sb = SchemaBuilder()
    sb.add_field(Field(String("atemp"), ArrowType.INT64, False))
    sb.add_field(Field(String("p0"), ArrowType.INT64, False))
    sb.add_field(Field(String("p1"), ArrowType.INT64, False))
    var schema = sb.build()
    var rbb = RecordBatchBuilder.with_capacity(3)
    rbb.add_column(Column.from_primitive[DType.int64](_i64_prim(t^)))
    rbb.add_column(Column.from_primitive[DType.int64](_i64_prim(p0^)))
    rbb.add_column(Column.from_primitive[DType.int64](_i64_prim(p1^)))
    return rbb.build(schema^)


def test_bridge_byte_identical_asof_two_payloads() raises:
    """The 2-payload asof emit (temporal key ⊕ p0,p1) round-trips
    byte-identical — the multi-payload pack shape."""
    var t: List[Scalar[DType.int64]] = [10, 20, 30, 40, 50]
    var p0: List[Scalar[DType.int64]] = [1, 2, 3, 4, 5]
    var p1: List[Scalar[DType.int64]] = [100, 200, 300, 400, 500]
    var t2: List[Scalar[DType.int64]] = [10, 20, 30, 40, 50]
    var p02: List[Scalar[DType.int64]] = [1, 2, 3, 4, 5]
    var p12: List[Scalar[DType.int64]] = [100, 200, 300, 400, 500]
    var golden = _asof_3col(t^, p0^, p1^)
    var to_bridge = _asof_3col(t2^, p02^, p12^)
    var native = column_native_from_record_batch(to_bridge^)
    assert_true(native.num_columns() == 3, "3 cols (temp + 2 payload)")
    var restored = record_batch_from_column_native(native^)
    assert_true(
        record_batch_byte_equal(golden, restored),
        "asof probe emit bridge (temporal key + 2 payloads) byte-identical",
    )


def test_bridge_byte_identical_asof_single_match() raises:
    """A single forward-match output row round-trips byte-identical — the
    smallest non-empty asof emit shape (`probe_asof_batch` returns None for
    zero matches, so 1 row is the minimum emitted batch)."""
    var t: List[Scalar[DType.int64]] = [42]
    var p0: List[Scalar[DType.int64]] = [7]
    var p1: List[Scalar[DType.int64]] = [70]
    var t2: List[Scalar[DType.int64]] = [42]
    var p02: List[Scalar[DType.int64]] = [7]
    var p12: List[Scalar[DType.int64]] = [70]
    var golden = _asof_3col(t^, p0^, p1^)
    var to_bridge = _asof_3col(t2^, p02^, p12^)
    var native = column_native_from_record_batch(to_bridge^)
    var restored = record_batch_from_column_native(native^)
    assert_true(
        record_batch_byte_equal(golden, restored),
        "asof probe emit bridge (single forward match) byte-identical",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
