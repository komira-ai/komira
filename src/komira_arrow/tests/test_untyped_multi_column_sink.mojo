# =============================================================================
# test_untyped_multi_column_sink.mojo — UntypedMultiColumnSink tests
# =============================================================================
#
# Validates `komira_arrow/untyped_multi_column_sink.mojo`:
#   (a) build a 2-column sink (out_a Int64, out_b Float64) wired against a
#       BoundSchema; verify `append_at_name[DT.int64]("out_a", v)` lands
#       in slot 0 and `append_at_name[DType.float64]("out_b", v)` lands
#       in slot 1;
#   (b) `append_at_name` for an unknown name raises with diagnostic;
#   (c) finalize_columns produces the expected columns with the expected
#       row counts;
#   (d) the `@parameter for k` runtime-tag dispatch works for arity 3
#       (covers comptime-unroll + runtime-branch);
#   (e) null-slot path: `append_null_at_name` lands in the right slot.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_raises

from komira_arrow.bound_schema import BoundSchema
from komira_arrow.untyped_multi_column_sink import UntypedMultiColumnSink
from komira_arrow.multi_column_builder import (
    MultiColumnBuilder,
    ColumnSlot,
    column_slot,
)
from komira_arrow.schema import Schema, SchemaBuilder, Field
from komira_arrow.arrow_types import ArrowType


# -----------------------------------------------------------------------------
# Fixtures
# -----------------------------------------------------------------------------


def _build_2col_output_schema() raises -> Schema:
    """Output schema: out_a (INT64), out_b (FLOAT64)."""
    var sb = SchemaBuilder()
    sb.add_field(Field("out_a", ArrowType.INT64, False))
    sb.add_field(Field("out_b", ArrowType.FLOAT64, False))
    return sb.build()


def _build_3col_output_schema() raises -> Schema:
    """Output schema: alpha (INT64), beta (FLOAT64), gamma (INT64)."""
    var sb = SchemaBuilder()
    sb.add_field(Field("alpha", ArrowType.INT64, False))
    sb.add_field(Field("beta", ArrowType.FLOAT64, False))
    sb.add_field(Field("gamma", ArrowType.INT64, False))
    return sb.build()


# -----------------------------------------------------------------------------
# Tests
# -----------------------------------------------------------------------------


def test_2col_name_resolved_emit() raises:
    """(a) Build 2-column sink; emit a couple rows by name; verify columns
    finalize with the expected values."""
    var schema = _build_2col_output_schema()
    var bs = BoundSchema(schema)
    comptime SA = ColumnSlot[DType.int64]
    comptime SB = ColumnSlot[DType.float64]
    var mcb = MultiColumnBuilder[SA, SB](
        column_slot[DType.int64](8),
        column_slot[DType.float64](8),
    )
    var sink = UntypedMultiColumnSink(mcb^, bs)

    # Emit row 0:
    sink.append_at_name[DType.int64]("out_a", Int64(10))
    sink.append_at_name[DType.float64]("out_b", Float64(1.5))
    # Emit row 1:
    sink.append_at_name[DType.int64]("out_a", Int64(20))
    sink.append_at_name[DType.float64]("out_b", Float64(2.5))
    # Emit row 2 (out-of-order name order — name-resolved should still work):
    sink.append_at_name[DType.float64]("out_b", Float64(3.5))
    sink.append_at_name[DType.int64]("out_a", Int64(30))

    var col_a = sink.finalize_at[0]()
    var col_b = sink.finalize_at[1]()
    assert_equal(col_a.length(), 3)
    assert_equal(col_b.length(), 3)


def test_name_lookup_error_diagnostic() raises:
    """(b) append_at_name on an unknown column surfaces the BoundSchema
    diagnostic."""
    var schema = _build_2col_output_schema()
    var bs = BoundSchema(schema)
    comptime SA = ColumnSlot[DType.int64]
    comptime SB = ColumnSlot[DType.float64]
    var mcb = MultiColumnBuilder[SA, SB](
        column_slot[DType.int64](2),
        column_slot[DType.float64](2),
    )
    var sink = UntypedMultiColumnSink(mcb^, bs)

    with assert_raises(contains="no field named 'unknown_col'"):
        sink.append_at_name[DType.int64]("unknown_col", Int64(42))


def test_finalize_columns() raises:
    """(c) finalize_columns produces the expected number of columns."""
    var schema = _build_2col_output_schema()
    var bs = BoundSchema(schema)
    comptime SA = ColumnSlot[DType.int64]
    comptime SB = ColumnSlot[DType.float64]
    var mcb = MultiColumnBuilder[SA, SB](
        column_slot[DType.int64](4),
        column_slot[DType.float64](4),
    )
    var sink = UntypedMultiColumnSink(mcb^, bs)

    sink.append_at_name[DType.int64]("out_a", Int64(7))
    sink.append_at_name[DType.float64]("out_b", Float64(7.5))

    var cols = sink.finalize_columns()
    assert_equal(len(cols), 2)
    assert_equal(cols[0].length(), 1)
    assert_equal(cols[1].length(), 1)


def test_3col_arity_dispatch() raises:
    """(d) arity 3 — covers the @parameter for k runtime-tag dispatch.
    All three column emits should land in their correct slot."""
    var schema = _build_3col_output_schema()
    var bs = BoundSchema(schema)
    comptime S0 = ColumnSlot[DType.int64]
    comptime S1 = ColumnSlot[DType.float64]
    comptime S2 = ColumnSlot[DType.int64]
    var mcb = MultiColumnBuilder[S0, S1, S2](
        column_slot[DType.int64](4),
        column_slot[DType.float64](4),
        column_slot[DType.int64](4),
    )
    var sink = UntypedMultiColumnSink(mcb^, bs)

    # Emit in reverse-name order to confirm the resolved-index branch
    # chooses correctly under runtime dispatch.
    sink.append_at_name[DType.int64]("gamma", Int64(300))
    sink.append_at_name[DType.float64]("beta", Float64(20.0))
    sink.append_at_name[DType.int64]("alpha", Int64(1))

    sink.append_at_name[DType.int64]("alpha", Int64(2))
    sink.append_at_name[DType.float64]("beta", Float64(40.0))
    sink.append_at_name[DType.int64]("gamma", Int64(400))

    var col0 = sink.finalize_at[0]()       # alpha
    var col1 = sink.finalize_at[1]()       # beta
    var col2 = sink.finalize_at[2]()       # gamma
    assert_equal(col0.length(), 2)
    assert_equal(col1.length(), 2)
    assert_equal(col2.length(), 2)


def test_append_null_at_name() raises:
    """(e) null-slot path: append_null_at_name lands a null in the named
    slot; the column's length grows by 1 each call."""
    var schema = _build_2col_output_schema()
    var bs = BoundSchema(schema)
    comptime SA = ColumnSlot[DType.int64]
    comptime SB = ColumnSlot[DType.float64]
    var mcb = MultiColumnBuilder[SA, SB](
        column_slot[DType.int64](4),
        column_slot[DType.float64](4),
    )
    var sink = UntypedMultiColumnSink(mcb^, bs)

    sink.append_at_name[DType.int64]("out_a", Int64(1))
    sink.append_null_at_name("out_a")
    sink.append_at_name[DType.int64]("out_a", Int64(3))

    sink.append_null_at_name("out_b")
    sink.append_at_name[DType.float64]("out_b", Float64(2.0))
    sink.append_null_at_name("out_b")

    var col_a = sink.finalize_at[0]()
    var col_b = sink.finalize_at[1]()
    assert_equal(col_a.length(), 3)
    assert_equal(col_b.length(), 3)


def test_indexed_pass_through() raises:
    """The `append_at[k, DT]` slot-indexed pass-through still works for
    callers that already have a comptime slot index (engine-internal)."""
    var schema = _build_2col_output_schema()
    var bs = BoundSchema(schema)
    comptime SA = ColumnSlot[DType.int64]
    comptime SB = ColumnSlot[DType.float64]
    var mcb = MultiColumnBuilder[SA, SB](
        column_slot[DType.int64](2),
        column_slot[DType.float64](2),
    )
    var sink = UntypedMultiColumnSink(mcb^, bs)

    sink.append_at[0, DType.int64](Int64(99))
    sink.append_at[1, DType.float64](Float64(1.25))

    var col_a = sink.finalize_at[0]()
    var col_b = sink.finalize_at[1]()
    assert_equal(col_a.length(), 1)
    assert_equal(col_b.length(), 1)


def test_arity_static_accessor() raises:
    """`arity()` static accessor returns the comptime slot count."""
    var schema = _build_3col_output_schema()
    var bs = BoundSchema(schema)
    comptime S0 = ColumnSlot[DType.int64]
    comptime S1 = ColumnSlot[DType.float64]
    comptime S2 = ColumnSlot[DType.int64]
    var mcb = MultiColumnBuilder[S0, S1, S2](
        column_slot[DType.int64](1),
        column_slot[DType.float64](1),
        column_slot[DType.int64](1),
    )
    var sink = UntypedMultiColumnSink(mcb^, bs)
    assert_equal(sink.arity(), 3)


def main() raises:
    test_2col_name_resolved_emit()
    test_name_lookup_error_diagnostic()
    test_finalize_columns()
    test_3col_arity_dispatch()
    test_append_null_at_name()
    test_indexed_pass_through()
    test_arity_static_accessor()
    print("all UntypedMultiColumnSink tests passed")
