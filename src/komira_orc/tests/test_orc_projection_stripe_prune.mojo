# =============================================================================
# test_orc_projection_stripe_prune.mojo — ORC cascade levels 1-2:
#   (1) column-projection   (2) stripe-stats prune.
# =============================================================================
#
# These are the two coarsest scan-side skip levels, sitting ABOVE stride-stats
# (level 3) and stride-bloom (level 4):
#
#   (1) column-projection — decode only the referenced leaf columns. A read of
#       a subset {a, c} of a 4-column file must produce exactly those columns
#       (right schema, right values) and decode only them.
#   (2) stripe-stats prune — before decoding a stripe, evaluate the predicate
#       against the stripe's footer/metadata ColumnStatistics; skip whole
#       stripes proven disjoint. Coarser than stride-skip; composes above it.
#
# NEITHER feature reinterprets bytes: projection reads a subset of already-
# correctly-decoded columns; stripe-prune reuses the same per-stripe min/max
# the stride path already trusts (at coarser granularity). So a full
# scan (read_orc_bytes) is a VALID ORACLE for both — no orc-cpp / pyarrow.
#
# These tests FAIL without read_orc_bytes_projected / read_orc_bytes_pruned /
# OrcPrunedResult / the per-stripe Metadata.parse.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.column import Column
from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.arrow.string_array import StringArray
from komira_core.arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_core.arrow.schema import Schema, SchemaBuilder, Field

from komira_core.plan.expr import (
    Expr,
    BIN_AND,
    BIN_GE,
    BIN_LT,
)
from komira_core.plan.scalar_value import ScalarValue

from komira_orc import (
    OrcWriterOptions,
    write_orc_bytes,
    read_orc_bytes,
    read_orc_bytes_projected,
    read_orc_bytes_pruned,
    ORC_COMPRESSION_NONE,
    ORC_COMPRESSION_ZSTD,
)


# =============================================================================
# Fixtures.
# =============================================================================


def _build_4col_batch(n: Int) raises -> RecordBatch:
    """4 columns: a (=i), b (=i*2), c-name (="r<i>"), d (=i*10)."""
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, True))
    sb.add_field(Field("b", ArrowType.INT64, True))
    sb.add_field(Field("c", ArrowType.STRING, True))
    sb.add_field(Field("d", ArrowType.INT64, True))

    var aa = PrimitiveArray[DType.int64].allocate(n)
    var bb = PrimitiveArray[DType.int64].allocate(n)
    var dd = PrimitiveArray[DType.int64].allocate(n)
    for i in range(n):
        aa.set(i, Int64(i))
        bb.set(i, Int64(i * 2))
        dd.set(i, Int64(i * 10))
    var ss = List[String]()
    for i in range(n):
        ss.append(String("r") + String(i))
    var sarr = StringArray.from_strings(ss)

    var builder = RecordBatchBuilder.with_capacity(4)
    builder.add_column(
        Column.from_primitive_with_arrow_type[DType.int64](aa^, ArrowType.INT64)
    )
    builder.add_column(
        Column.from_primitive_with_arrow_type[DType.int64](bb^, ArrowType.INT64)
    )
    builder.add_column(Column.from_string(sarr^))
    builder.add_column(
        Column.from_primitive_with_arrow_type[DType.int64](dd^, ArrowType.INT64)
    )
    return builder.build(sb.build())


def _range_predicate(col: String, lo: Int64, hi: Int64) raises -> Expr:
    """`col >= lo AND col < hi` (half-open, Q6-shaped)."""
    var ge = Expr.binary(
        BIN_GE,
        Expr.col_ref(col),
        Expr.literal(ScalarValue.from_int64(lo)),
    )
    var lt = Expr.binary(
        BIN_LT,
        Expr.col_ref(col),
        Expr.literal(ScalarValue.from_int64(hi)),
    )
    return Expr.binary(BIN_AND, ge^, lt^)


# =============================================================================
# (1) Column-projection.
# =============================================================================


def test_orc_projection_subset() raises:
    """Projecting {a, c} of {a, b, c, d} -> exactly those 2 columns, with
    values byte-equal to a full-read-then-select."""
    var n = 25
    var rb = _build_4col_batch(n)
    var opts = OrcWriterOptions(ORC_COMPRESSION_NONE, 10000, String(""))
    var bytes = write_orc_bytes(rb, opts)

    var full = read_orc_bytes(Span(bytes))
    assert_equal(full.num_columns(), 4, "full: 4 columns")
    assert_equal(full.num_rows(), n, "full: n rows")

    # Project output columns 0 (a) and 2 (c).
    var proj = List[Int]()
    proj.append(0)
    proj.append(2)
    var got = read_orc_bytes_projected(Span(bytes), proj)

    # Acceptance gate 1a: only the projected columns are decoded.
    assert_equal(got.num_columns(), 2, "proj: 2 columns decoded")
    assert_equal(got.num_rows(), n, "proj: n rows")
    assert_equal(got.schema.field_name(0), String("a"), "proj: col0 == a")
    assert_equal(got.schema.field_name(1), String("c"), "proj: col1 == c")

    # Acceptance gate 1b: values byte-equal full-read-then-select.
    var fa = full.column_as_primitive_int64(0)  # a
    var fc = full.column_as_string(2)  # c
    var ga = got.column_as_primitive_int64(0)
    var gc = got.column_as_string(1)
    for i in range(n):
        assert_equal(Int(ga.get(i)), Int(fa.get(i)), "proj: a row " + String(i))
        assert_equal(gc.get(i), fc.get(i), "proj: c row " + String(i))


def test_orc_projection_single_int_col() raises:
    """Projecting a single int column {d} preserves values."""
    var n = 17
    var rb = _build_4col_batch(n)
    var opts = OrcWriterOptions(ORC_COMPRESSION_ZSTD, 10000, String(""))
    var bytes = write_orc_bytes(rb, opts)

    var full = read_orc_bytes(Span(bytes))
    var proj = List[Int]()
    proj.append(3)  # d
    var got = read_orc_bytes_projected(Span(bytes), proj)

    assert_equal(got.num_columns(), 1, "single-proj: 1 column")
    assert_equal(got.schema.field_name(0), String("d"), "single-proj: col0 == d")
    var fd = full.column_as_primitive_int64(3)
    var gd = got.column_as_primitive_int64(0)
    for i in range(n):
        assert_equal(Int(gd.get(i)), Int(fd.get(i)), "single-proj: d row " + String(i))


# =============================================================================
# (2) Stripe-stats prune.
# =============================================================================


def _run_stripe_prune_for_codec(codec: Int, label: String) raises:
    var n = 30
    var rb = _build_4col_batch(n)
    # 3 stripes of 10 rows each (stripe_size_rows == row_index_stride == 10).
    # Column `a` is monotone (= row index), so per-stripe a-stats are disjoint:
    #   stripe 0: a in [0,9], stripe 1: [10,19], stripe 2: [20,29].
    var opts = OrcWriterOptions.with_stride(codec, 10, 10, True)
    var bytes = write_orc_bytes(rb, opts)

    var full = read_orc_bytes(Span(bytes))
    assert_equal(full.num_rows(), n, label + ": full 30 rows")

    # Selective predicate landing entirely in stripe 2 (a in [20,29]):
    #   a >= 20 AND a < 30.
    var pred = _range_predicate(String("a"), Int64(20), Int64(30))
    var res = read_orc_bytes_pruned(Span(bytes), pred, List[Int]())

    # Acceptance gate 2a: stripe-skip count > 0 (stripes 0 and 1 skipped).
    assert_equal(res.stripes_total, 3, label + ": 3 stripes total")
    assert_true(
        res.stripes_skipped >= 2,
        label
        + ": >= 2 stripes skipped (got "
        + String(res.stripes_skipped)
        + ")",
    )

    # Acceptance gate 2b: surviving rows byte-equal the full-scan rows matching.
    var fa = full.column_as_primitive_int64(0)
    var ref_a = List[Int64]()
    for i in range(full.num_rows()):
        var v = fa.get(i)
        if v >= 20 and v < 30:
            ref_a.append(v)
    assert_equal(
        res.batch.num_rows(),
        len(ref_a),
        label + ": filtered row count matches reference",
    )
    var ra = res.batch.column_as_primitive_int64(0)
    for i in range(res.batch.num_rows()):
        assert_equal(
            Int(ra.get(i)), Int(ref_a[i]), label + ": a row " + String(i)
        )


def test_orc_stripe_prune_none() raises:
    _run_stripe_prune_for_codec(ORC_COMPRESSION_NONE, String("NONE"))


def test_orc_stripe_prune_zstd() raises:
    _run_stripe_prune_for_codec(ORC_COMPRESSION_ZSTD, String("ZSTD"))


def test_orc_stripe_prune_no_skip_when_all_match() raises:
    """A predicate every stripe satisfies => 0 stripe-skips, all rows."""
    var n = 30
    var rb = _build_4col_batch(n)
    var opts = OrcWriterOptions.with_stride(ORC_COMPRESSION_NONE, 10, 10, True)
    var bytes = write_orc_bytes(rb, opts)
    # a >= 0 AND a < 1000 — covers every stripe.
    var pred = _range_predicate(String("a"), Int64(0), Int64(1000))
    var res = read_orc_bytes_pruned(Span(bytes), pred, List[Int]())
    assert_equal(res.stripes_skipped, 0, "all-match: 0 stripes skipped")
    assert_equal(res.batch.num_rows(), n, "all-match: all 30 rows survive")


def test_orc_stripe_prune_with_projection() raises:
    """Stripe-prune + projection compose: skip stripes 0/1, project {a, c}."""
    var n = 30
    var rb = _build_4col_batch(n)
    var opts = OrcWriterOptions.with_stride(ORC_COMPRESSION_NONE, 10, 10, True)
    var bytes = write_orc_bytes(rb, opts)
    var full = read_orc_bytes(Span(bytes))

    var pred = _range_predicate(String("a"), Int64(20), Int64(30))
    var proj = List[Int]()
    proj.append(0)  # a
    proj.append(2)  # c
    var res = read_orc_bytes_pruned(Span(bytes), pred, proj)

    assert_equal(res.stripes_total, 3, "compose: 3 stripes")
    assert_true(res.stripes_skipped >= 2, "compose: >= 2 stripes skipped")
    assert_equal(res.batch.num_columns(), 2, "compose: 2 projected columns")
    assert_equal(res.batch.schema.field_name(0), String("a"), "compose: col0 == a")
    assert_equal(res.batch.schema.field_name(1), String("c"), "compose: col1 == c")

    # Surviving rows: a in [20,29], values match full-then-select.
    var fa = full.column_as_primitive_int64(0)
    var fc = full.column_as_string(2)
    var ref_a = List[Int64]()
    var ref_c = List[String]()
    for i in range(full.num_rows()):
        var v = fa.get(i)
        if v >= 20 and v < 30:
            ref_a.append(v)
            ref_c.append(fc.get(i))
    assert_equal(res.batch.num_rows(), len(ref_a), "compose: row count")
    var ra = res.batch.column_as_primitive_int64(0)
    var rc = res.batch.column_as_string(1)
    for i in range(res.batch.num_rows()):
        assert_equal(Int(ra.get(i)), Int(ref_a[i]), "compose: a row " + String(i))
        assert_equal(rc.get(i), ref_c[i], "compose: c row " + String(i))


def main() raises:
    test_orc_projection_subset()
    test_orc_projection_single_int_col()
    test_orc_stripe_prune_none()
    test_orc_stripe_prune_zstd()
    test_orc_stripe_prune_no_skip_when_all_match()
    test_orc_stripe_prune_with_projection()
    print("test_orc_projection_stripe_prune: ALL PASS")
