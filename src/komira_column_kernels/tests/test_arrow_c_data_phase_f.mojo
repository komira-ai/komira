# =============================================================================
# Arrow Type Coverage — Timestamp-tz fidelity through compute paths
#
# The C-Data round-trip carries tz via `Field._tz`; tz must also survive
# THROUGH the engine's compute / passthrough paths.
#
# The hazard: a passthrough site that rebuilds the output Field via the bare
# 3-arg `Field(name, arrow_type, nullable)` constructor zero-fills `_tz`,
# `_dict_index_type`, `_union_type_ids`, `_flags`, decimal `(p,s)`, and the
# per-field kv-metadata. Any TIMESTAMP-tz column flowing through such a site
# (`copy_batch` / `gather_batch` / `project_batch_by_names` /
# `empty_batch_like(_schema)` in `helpers/compiler_helpers.mojo`, or the
# filter's column gather) arrives at the next operator with the tz silently
# dropped, and a Decimal128 loses its `(p, s)`. The passthrough sites clone
# the whole Field instead (`schema.field_at(idx)`).
#
# ⚠ A HEADER LIST OF "THE PASSTHROUGH SITES" GOES STALE. A select-AND-RENAME
# arm (`project_batch_by_src_out_pairs`) added later is exactly as able to
# ship the bare 3-arg rebuild while every cell below tests its sibling and
# stays green; that returns a DECIMAL as `decimal128(38, 0)` carrying the
# unscaled integer (`40.00` -> `4000`). So do not count the sites here —
# derive them by searching the source for
#     Field(<name>, <x>.arrow_type, <x>.nullable)
# and add a cell per PRIMITIVE, not per site-list entry.
#
# The contract "schema passthrough preserves tz/decimal/dict-idx/flags/
# metadata", pinned column-by-column:
#
#   1. `copy_batch` preserves TIMESTAMP_US + tz "America/New_York"
#   2. `gather_batch` preserves TIMESTAMP_US + tz "UTC"
#   3. `project_batch_by_names` preserves tz on the selected column
#   4. `empty_batch_like` preserves tz on a zero-row clone
#   5. `empty_batch_like_schema` preserves tz from a bare Schema
#   6. `copy_batch` preserves DECIMAL128 (precision, scale)
#   7. `gather_batch` preserves DECIMAL128 (p,s)
#   8. `gather_batch` preserves DECIMAL128 (p,s)
#   9. `field_for_expr(EXPR_ALIAS)` preserves tz from the child column
#
# No kernel allocates a TIMESTAMP output Column, so the schema-passthrough
# layer is the entire fidelity surface.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.bitmap import Bitmap
from komira_arrow.column import Column
from komira_arrow.schema import Field, RecordBatch, RecordBatchBuilder, Schema, SchemaBuilder
from komira_arrow.primitive_array import PrimitiveArray
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_column_kernels.compiler_helpers import (
    copy_batch,
    gather_batch,
    project_batch_by_names,
    project_batch_by_src_out_pairs,
    empty_batch_like,
    empty_batch_like_schema,
    field_for_expr,
)
from komira_plan_expr.expr import Expr
from komira_buffer.heap_region import HeapRegion


# --- Helpers -----------------------------------------------------------------


def _make_ts_us_column_two_rows() raises -> Column[HeapRegion]:
    """Build a 2-row TIMESTAMP_US Column[HeapRegion] with two distinct instants."""
    var values = [Int64(1_700_000_000_000_000), Int64(1_700_000_001_000_000)]
    var n = len(values)
    var buf = OwnedAlignedBuffer(max(n * 8, 1))
    for i in range(n):
        buf.write_i64_le_at(i * 8, values[i])
    buf.set_length(Int64(n * 8))

    return Column[HeapRegion](
        arrow_type=ArrowType.TIMESTAMP_US,
        data=buf^,
        offsets=None,
        validity=None,
        length=n,
        null_count=0,
        offset=0,
    )


def _make_ts_us_batch(tz: String) raises -> RecordBatch:
    """Build a 1-column, 2-row RecordBatch with TIMESTAMP_US + given tz."""
    var col = _make_ts_us_column_two_rows()
    var f = Field.timestamp("ts", ArrowType.TIMESTAMP_US, tz, nullable=False)
    var sb = SchemaBuilder()
    sb.add_field(f^)
    var schema = sb.build()
    var rbb = RecordBatchBuilder.with_capacity(1)
    rbb.add_column(col^)
    return rbb.build(schema^)


def _make_dec128_column_two_rows() raises -> Column[HeapRegion]:
    """Build a 2-row DECIMAL128 Column[HeapRegion] with two values stored as 16-byte LE."""
    var n = 2
    var buf = OwnedAlignedBuffer(max(n * 16, 1))
    # value 12345 — write as Int64 low half, Int64 high half = 0
    buf.write_i64_le_at(0, Int64(12345))
    buf.write_i64_le_at(8, Int64(0))
    buf.write_i64_le_at(16, Int64(67890))
    buf.write_i64_le_at(24, Int64(0))
    buf.set_length(Int64(n * 16))

    return Column[HeapRegion](
        arrow_type=ArrowType.DECIMAL128,
        data=buf^,
        offsets=None,
        validity=None,
        length=n,
        null_count=0,
        offset=0,
    )


def _make_dec128_batch(precision: Int, scale: Int) raises -> RecordBatch:
    """Build a 1-column, 2-row RecordBatch with DECIMAL128(p, s)."""
    var col = _make_dec128_column_two_rows()
    var f = Field.decimal128("amount", precision, scale, nullable=False)
    var sb = SchemaBuilder()
    sb.add_field(f^)
    var schema = sb.build()
    var rbb = RecordBatchBuilder.with_capacity(1)
    rbb.add_column(col^)
    return rbb.build(schema^)


# --- Tests -------------------------------------------------------------------


def test_copy_batch_preserves_timestamp_tz() raises:
    """`copy_batch` must preserve `Field._tz` end-to-end. Rebuilding the field
    via the bare `Field(name, arrow_type, nullable)` ctor zero-fills `_tz`,
    so the output tz would come out empty."""
    var batch = _make_ts_us_batch(String("America/New_York"))
    var copied = copy_batch(batch^)
    var f_out = copied.schema.field_at(0)
    assert_true(
        f_out.arrow_type == ArrowType.TIMESTAMP_US,
        "TIMESTAMP_US type preserved through copy_batch",
    )
    assert_true(
        f_out.timezone() == String("America/New_York"),
        "tz preserved through copy_batch",
    )


def test_copy_batch_zero_row_preserves_timestamp_tz() raises:
    """The zero-row short-circuit branch of `copy_batch` also goes through the
    Field-rebuild path; verify tz is preserved on a zero-row input batch."""
    # Build a 0-row TIMESTAMP_US column with tz.
    var buf = OwnedAlignedBuffer(1)
    buf.set_length(0)

    var col = Column[HeapRegion](
        arrow_type=ArrowType.TIMESTAMP_US,
        data=buf^,
        offsets=None,
        validity=None,
        length=0,
        null_count=0,
        offset=0,
    )
    var f = Field.timestamp("ts", ArrowType.TIMESTAMP_US, String("UTC"), nullable=False)
    var sb = SchemaBuilder()
    sb.add_field(f^)
    var schema = sb.build()
    var rbb = RecordBatchBuilder.with_capacity(1)
    rbb.add_column(col^)
    var batch = rbb.build(schema^)

    var copied = copy_batch(batch^)
    var f_out = copied.schema.field_at(0)
    assert_true(
        f_out.timezone() == String("UTC"),
        "tz preserved through copy_batch zero-row path",
    )


def test_gather_batch_preserves_timestamp_tz() raises:
    """`gather_batch` (used by filter / sort permutations / late-mat fallback)
    must preserve `Field._tz` on selected rows."""
    var batch = _make_ts_us_batch(String("UTC"))
    var indices = List[Int]()
    indices.append(1)  # gather just row 1
    var gathered = gather_batch(batch, indices)
    var f_out = gathered.schema.field_at(0)
    assert_true(
        f_out.timezone() == String("UTC"),
        "tz preserved through gather_batch",
    )


def test_project_batch_by_names_preserves_timestamp_tz() raises:
    """`project_batch_by_names` is used for projection pushdown; it must
    preserve `Field._tz` on the projected column."""
    var batch = _make_ts_us_batch(String("Europe/London"))
    var names = List[String]()
    names.append(String("ts"))
    var projected = project_batch_by_names(batch, names)
    var f_out = projected.schema.field_at(0)
    assert_true(
        f_out.timezone() == String("Europe/London"),
        "tz preserved through project_batch_by_names",
    )


def test_empty_batch_like_preserves_timestamp_tz() raises:
    """`empty_batch_like` builds a 0-row clone for empty-input branches; it
    must preserve `Field._tz` on the clone."""
    var batch = _make_ts_us_batch(String("Asia/Tokyo"))
    var empty = empty_batch_like(batch)
    var f_out = empty.schema.field_at(0)
    assert_true(
        f_out.timezone() == String("Asia/Tokyo"),
        "tz preserved through empty_batch_like",
    )


def test_empty_batch_like_schema_preserves_timestamp_tz() raises:
    """`empty_batch_like_schema` builds a 0-row batch from a bare Schema; it
    must preserve `Field._tz` on the resulting batch."""
    var f = Field.timestamp(
        "ts", ArrowType.TIMESTAMP_US, String("America/Los_Angeles"), nullable=False
    )
    var sb = SchemaBuilder()
    sb.add_field(f^)
    var schema = sb.build()
    var empty = empty_batch_like_schema(schema)
    var f_out = empty.schema.field_at(0)
    assert_true(
        f_out.timezone() == String("America/Los_Angeles"),
        "tz preserved through empty_batch_like_schema",
    )


def test_copy_batch_preserves_decimal_precision_scale() raises:
    """`copy_batch` must not drop decimal (precision, scale) either. A
    TIMESTAMP-only fix that does not use `field_at` (e.g., copying `_tz`
    alone) would leave the decimal precision dropped."""
    var batch = _make_dec128_batch(precision=18, scale=4)
    var copied = copy_batch(batch^)
    var f_out = copied.schema.field_at(0)
    assert_true(
        f_out.arrow_type == ArrowType.DECIMAL128,
        "DECIMAL128 type preserved through copy_batch",
    )
    assert_equal(f_out.decimal_precision, 18, "decimal precision preserved")
    assert_equal(f_out.decimal_scale, 4, "decimal scale preserved")


def test_gather_batch_preserves_decimal_precision_scale() raises:
    """The same decimal pin on the `gather_batch` path."""
    var batch = _make_dec128_batch(precision=20, scale=6)
    var indices = List[Int]()
    indices.append(0)
    var gathered = gather_batch(batch, indices)
    var f_out = gathered.schema.field_at(0)
    assert_equal(f_out.decimal_precision, 20, "decimal precision preserved through gather_batch")
    assert_equal(f_out.decimal_scale, 6, "decimal scale preserved through gather_batch")


def test_field_for_expr_alias_preserves_timestamp_tz() raises:
    """`field_for_expr` for an EXPR_ALIAS wrapping a TIMESTAMP-tz col_ref
    must keep `_tz`. An EXPR_ALIAS arm that rebuilds the Field via the 3-arg
    ctor and copies only decimal (p,s) drops the tz, and the result schema
    appears tz-less downstream."""
    var f = Field.timestamp("ts", ArrowType.TIMESTAMP_US, String("UTC"), nullable=False)
    var sb = SchemaBuilder()
    sb.add_field(f^)
    var schema = sb.build()
    var col_ref = Expr.col_ref(String("ts"))
    var alias_expr = Expr.alias(col_ref^, String("ts_alias"))
    var out_field = field_for_expr(alias_expr, schema)
    assert_true(
        out_field.name == String("ts_alias"),
        "alias renamed the field",
    )
    assert_true(
        out_field.arrow_type == ArrowType.TIMESTAMP_US,
        "alias preserved arrow_type",
    )
    assert_true(
        out_field.timezone() == String("UTC"),
        "alias preserved tz",
    )


# =============================================================================
# ★ `project_batch_by_src_out_pairs` — the select-AND-RENAME arm
# =============================================================================
#
# A select-and-rename arm that rebuilds its output Field with the 3-arg ctor
#
#     Field(out_names[i], src_field.arrow_type, src_field.nullable)
#
# is invisible to every cell above, because those call
# `project_batch_by_names`, which copies `field_at(idx)` whole. A corpus keyed
# to a SITE LIST cannot see a site added later; these cells are keyed to the
# PRIMITIVE.
#
# The user-visible cost of that defect: a PROJECT over a pipeline breaker
# (for example `df.sort_values(k)[[...]]` over a decimal column) returns
# `decimal128(38, 0)` holding the UNSCALED integer — `40.00` as `4000`,
# silently.
#
# ⚠ THE RENAME IS ASSERTED IN EVERY CELL, not just the type. The obvious wrong
# fix — copy `field_at(idx)` and forget `.name` — makes the select-and-rename
# path emit the SOURCE name, which is a different silent wrong answer (the
# scalar-broadcast decorrelation depends on the rename landing).


def test_project_pairs_preserves_decimal_precision_scale_under_a_RENAME() raises:
    """★ THE DEFECT, at the primitive: the scale must not drop to `decimal128(38, 0)`.

    A dropped scale is not a type nit — the 16-byte payload is carried through
    unchanged, so the SAME BYTES are reinterpreted 100x larger. `12345` at
    scale 4 is `1.2345`; at scale 0 it is `12345`.
    """
    var batch = _make_dec128_batch(precision=18, scale=4)
    var srcs = List[String]()
    srcs.append(String("amount"))
    var outs = List[String]()
    outs.append(String("renamed_amount"))
    var projected = project_batch_by_src_out_pairs(batch, srcs, outs)
    var f_out = projected.schema.field_at(0)
    assert_true(
        f_out.name == String("renamed_amount"),
        "the RENAME must still happen — copying the field whole and forgetting"
        " `.name` is the other silent wrong answer",
    )
    assert_true(
        f_out.arrow_type == ArrowType.DECIMAL128,
        "DECIMAL128 type preserved through project_batch_by_src_out_pairs",
    )
    assert_equal(
        f_out.decimal_precision, 18,
        "decimal precision preserved through project_batch_by_src_out_pairs",
    )
    assert_equal(
        f_out.decimal_scale, 4,
        "decimal scale preserved through project_batch_by_src_out_pairs",
    )


def test_project_pairs_preserves_decimal_on_a_PASS_THROUGH_name() raises:
    """The src == out arm. VARIED OFF THE CELL ABOVE BY ONE PROPERTY.

    This is the shape a plain `.select()` (no alias) produces for
    `df.sort_values(k)[[...]]`, so a fix verified only on the renaming arm
    would prove nothing about it.
    """
    var batch = _make_dec128_batch(precision=12, scale=2)
    var srcs = List[String]()
    srcs.append(String("amount"))
    var outs = List[String]()
    outs.append(String("amount"))
    var projected = project_batch_by_src_out_pairs(batch, srcs, outs)
    var f_out = projected.schema.field_at(0)
    assert_true(f_out.name == String("amount"), "pass-through keeps the name")
    assert_equal(f_out.decimal_precision, 12, "precision preserved (pass-through)")
    assert_equal(f_out.decimal_scale, 2, "scale preserved (pass-through)")


def test_project_pairs_preserves_timestamp_tz() raises:
    """A SECOND dropped slot, varied off decimal: `_tz`.

    The 3-arg ctor zero-fills every optional Field slot, so decimal (p,s) was one
    symptom of one mechanism. A fix that special-cased decimal would leave a
    `TIMESTAMP WITH TIME ZONE` column arriving tz-less — the exact regression
    `test_field_for_expr_alias_preserves_timestamp_tz` above pins for the alias
    arm, which is this same rename in the expression layer.
    """
    var batch = _make_ts_us_batch(String("Europe/London"))
    var srcs = List[String]()
    srcs.append(String("ts"))
    var outs = List[String]()
    outs.append(String("ts_renamed"))
    var projected = project_batch_by_src_out_pairs(batch, srcs, outs)
    var f_out = projected.schema.field_at(0)
    assert_true(f_out.name == String("ts_renamed"), "alias-style rename applied")
    assert_true(
        f_out.arrow_type == ArrowType.TIMESTAMP_US,
        "TIMESTAMP_US preserved through project_batch_by_src_out_pairs",
    )
    assert_true(
        f_out.timezone() == String("Europe/London"),
        "tz preserved through project_batch_by_src_out_pairs",
    )


def test_project_pairs_preserves_dict_index_type_and_field_metadata() raises:
    """A THIRD and FOURTH dropped slot: `_dict_index_type` and kv-metadata.

    `_dict_index_type` DEFAULTS to INT32, so a dictionary column whose indices
    are INT8 is the only one that can falsify it — an INT32 fixture would pass
    against the zero-filling ctor and prove nothing. Chosen deliberately.
    """
    var f = Field.dictionary("code", ArrowType.INT8, nullable=False)
    f.set_metadata(String("PARQUET:field_id"), String("7"))
    var sb = SchemaBuilder()
    sb.add_field(f^)
    var schema = sb.build()

    # A 2-row INT8 index buffer is the physical payload of a DICTIONARY column.
    var buf = OwnedAlignedBuffer(2)
    buf.set_length(2)
    var col = Column[HeapRegion](
        arrow_type=ArrowType.DICTIONARY,
        data=buf^,
        offsets=None,
        validity=None,
        length=2,
        null_count=0,
        offset=0,
    )
    var rbb = RecordBatchBuilder.with_capacity(1)
    rbb.add_column(col^)
    var batch = rbb.build(schema^)

    var srcs = List[String]()
    srcs.append(String("code"))
    var outs = List[String]()
    outs.append(String("code_out"))
    var projected = project_batch_by_src_out_pairs(batch, srcs, outs)
    var f_out = projected.schema.field_at(0)
    assert_true(f_out.name == String("code_out"), "rename applied")
    assert_true(
        f_out.dict_index_type() == ArrowType.INT8,
        "DICTIONARY index type preserved (INT8, not the INT32 default)",
    )
    var meta = f_out.get_metadata(String("PARQUET:field_id"))
    assert_true(Bool(meta), "per-field kv-metadata survived the projection")
    assert_true(meta.value() == String("7"), "kv-metadata VALUE survived")


def main() raises:
    var suite = TestSuite()
    suite.test[test_copy_batch_preserves_timestamp_tz]()
    suite.test[test_copy_batch_zero_row_preserves_timestamp_tz]()
    suite.test[test_gather_batch_preserves_timestamp_tz]()
    suite.test[test_project_batch_by_names_preserves_timestamp_tz]()
    suite.test[test_empty_batch_like_preserves_timestamp_tz]()
    suite.test[test_empty_batch_like_schema_preserves_timestamp_tz]()
    suite.test[test_copy_batch_preserves_decimal_precision_scale]()
    suite.test[test_gather_batch_preserves_decimal_precision_scale]()
    suite.test[test_field_for_expr_alias_preserves_timestamp_tz]()
    suite.test[test_project_pairs_preserves_decimal_precision_scale_under_a_RENAME]()
    suite.test[test_project_pairs_preserves_decimal_on_a_PASS_THROUGH_name]()
    suite.test[test_project_pairs_preserves_timestamp_tz]()
    suite.test[test_project_pairs_preserves_dict_index_type_and_field_metadata]()
    suite^.run()
