# =============================================================================
# test_literal_project_output_column.mojo: a literal as a projection output
# over a resident post-aggregate batch
# =============================================================================
#
# SUBJECT: `compute_project.eval_project_exprs_over_batch`'s literal arm
# (`is_literal_output_expr`, then `broadcast_scalar`).
#
# The shape: `SELECT 1, url, count(*) FROM t GROUP BY 1, url` binds to an
# aggregate with the constant key elided and the literal re-projected above it
# as `Expr.alias(Expr.literal(...), "1")`. `SELECT 'lit', count(*) FROM t
# GROUP BY k` and `SELECT 1 FROM t` put a literal in a projection's output list
# too.
#
# An INT64 literal is served on the walker route as well (its EXPR_LIT_I64
# node broadcasts the value), so case 1 is a control. The walkers have I64,
# F64 and I32 channels only, so without the literal arm every other literal
# type declines: a STRING and a BOOL have no channel, and a DATE32, INT32 or
# FLOAT32 literal comes out on the I64 or F64 channel against a narrower
# declared type (cases 2 to 6).
#
# The values are closed-form (a constant is a constant). The length (one
# value per row of THIS batch) is what a multi-batch drain can break, so
# case 7 drives three row counts through one projection.
# =============================================================================

from std.testing import TestSuite, assert_true, assert_equal, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Schema, SchemaBuilder, Field
from komira_arrow.string_array import StringArray
from komira_plan_expr.expr import Expr, BIN_MUL
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_ir.logical_plan import ExprArray

from komira_dispatch_project.compute_project import (
    eval_project_exprs_over_batch,
)


# =============================================================================
# FIXTURE: the batch an aggregate hands its parent projection: the group key
# (`url`, STRING) and the count (`c`, INT64).
# =============================================================================


def _agg_out_schema() raises -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field(String("url"), ArrowType.STRING, False))
    sb.add_field(Field(String("c"), ArrowType.INT64, False))
    return sb.build()


def _agg_out_batch(n_rows: Int) raises -> RecordBatch:
    """`n_rows` groups. The VALUES are distinct per row so a projection that
    dropped or duplicated a row is visible, not just a length change."""
    var urls = List[String](capacity=n_rows)
    var counts = PrimitiveArray[DType.int64].allocate(n_rows)
    for i in range(n_rows):
        urls.append(String("https://u.example/") + String(i))
        counts.store[1](i, SIMD[DType.int64, 1](Int64(100 + i)))
    var rbb = RecordBatchBuilder.with_capacity(2)
    rbb.add_column(Column.from_string(StringArray.from_strings(urls)))
    rbb.add_column(Column.from_primitive[DType.int64](counts))
    return rbb.build(_agg_out_schema())


def _lit_plus_passthroughs(var sv: ScalarValue, out_name: String) raises -> ExprArray:
    """The re-projected literal under its own name, then the two columns the
    aggregate produced."""
    var exprs = ExprArray()
    exprs.append(Expr.alias(Expr.literal(sv^), out_name))
    exprs.append(Expr.col_ref(String("url")))
    exprs.append(Expr.col_ref(String("c")))
    return exprs^


def _out_schema_for(lit_at: ArrowType, out_name: String) raises -> Schema:
    """The schema a binder declares for that projection: the literal's own
    type, renamed by the alias, non-nullable (a literal is never null)."""
    var sb = SchemaBuilder()
    sb.add_field(Field(out_name, lit_at, False))
    sb.add_field(Field(String("url"), ArrowType.STRING, False))
    sb.add_field(Field(String("c"), ArrowType.INT64, False))
    return sb.build()


def _assert_passthroughs_intact(imm out: RecordBatch, n_rows: Int) raises:
    """The two passthrough columns are unchanged by the literal arm."""
    assert_equal(out.num_columns(), 3, "three output columns")
    assert_equal(out.num_rows(), n_rows, "a Project is ROW-PRESERVING")
    var urls = out.column_as_string(1)
    var counts = out.column_as_primitive_int64(2)
    assert_equal(urls.length, n_rows, "the url column keeps every row")
    assert_equal(counts.length, n_rows, "the count column keeps every row")
    for i in range(n_rows):
        assert_equal(urls.get(i), String("https://u.example/") + String(i))
        assert_equal(Int(counts.get(i)), 100 + i)


# =============================================================================
# 1. CONTROL: the INT64 literal.
# =============================================================================


def test_an_int64_literal_output_was_already_served_and_still_is() raises:
    """An INT64 literal is served by the walker route too (EXPR_LIT_I64
    broadcasts it). This case pins that the literal arm gives the same
    answer."""
    var out_opt = eval_project_exprs_over_batch(
        _agg_out_batch(4),
        _lit_plus_passthroughs(ScalarValue.from_int64(Int64(1)), String("1")),
        _out_schema_for(ArrowType.INT64, String("1")),
    )
    assert_true(Bool(out_opt), "an INT64 literal output must be served")
    var out = out_opt.take()
    _assert_passthroughs_intact(out, 4)
    assert_equal(out.schema.field_name(0), String("1"), "named by the alias")
    assert_true(
        out.schema.field_arrow_type(0) == ArrowType.INT64,
        "the type the binder declared, not one inferred from the spelling",
    )
    var lit = out.column_as_primitive_int64(0)
    assert_equal(lit.length, 4, "one value per row of this batch")
    for i in range(4):
        assert_equal(Int(lit.get(i)), 1)


def test_a_literal_output_column_is_declared_non_nullable() raises:
    """The walker route declares every computed column nullable; the literal
    arm reads nullability off the broadcast column, which has no validity
    bitmap, so the field is non-nullable, as the plan declared."""
    var out_opt = eval_project_exprs_over_batch(
        _agg_out_batch(3),
        _lit_plus_passthroughs(ScalarValue.from_int64(Int64(7)), String("k")),
        _out_schema_for(ArrowType.INT64, String("k")),
    )
    assert_true(Bool(out_opt))
    var out = out_opt.take()
    assert_false(
        out.schema.field_nullable(0),
        "a literal is never null: the emitted field must not claim a"
        " validity buffer the broadcast column does not have",
    )


# =============================================================================
# 2-6. The five literal types the walker route cannot serve.
# =============================================================================


def test_a_string_literal_output_is_served() raises:
    """2. `SELECT 'lit', url, count(*) FROM t GROUP BY url`. The walkers have
    no STRING channel (`_infer_computed_family` answers RUNTIME_DTYPE_STRING,
    which the I64/F64/I32 ladder does not take)."""
    var out_opt = eval_project_exprs_over_batch(
        _agg_out_batch(5),
        _lit_plus_passthroughs(
            ScalarValue.from_string(String("lit")), String("lit")
        ),
        _out_schema_for(ArrowType.STRING, String("lit")),
    )
    assert_true(Bool(out_opt), "a STRING literal output must be served")
    var out = out_opt.take()
    _assert_passthroughs_intact(out, 5)
    assert_true(out.schema.field_arrow_type(0) == ArrowType.STRING)
    var lit = out.column_as_string(0)
    assert_equal(lit.length, 5, "one value per row of this batch")
    for i in range(5):
        assert_equal(lit.get(i), String("lit"))


def test_a_bool_literal_output_is_served() raises:
    """3. `SELECT TRUE, ...`. BOOL is bit-packed and is not a walker family;
    `broadcast_scalar` writes it through `BooleanArray.set`."""
    var out_opt = eval_project_exprs_over_batch(
        _agg_out_batch(3),
        _lit_plus_passthroughs(ScalarValue.from_bool(True), String("b")),
        _out_schema_for(ArrowType.BOOL, String("b")),
    )
    assert_true(Bool(out_opt), "a BOOL literal output must be served")
    var out = out_opt.take()
    _assert_passthroughs_intact(out, 3)
    assert_true(out.schema.field_arrow_type(0) == ArrowType.BOOL)
    var lit = out.column_as_boolean(0)
    assert_equal(lit.length, 3, "one value per row of this batch")
    for i in range(3):
        assert_true(lit.get(i), "TRUE broadcasts as TRUE")


def test_a_false_bool_literal_is_not_the_same_column_as_true() raises:
    """FALSE separately: `broadcast_scalar` writes nothing for FALSE (an
    allocated bitmap is zero), so a check of TRUE alone could not tell a
    working arm from one that ignored the value."""
    var out_opt = eval_project_exprs_over_batch(
        _agg_out_batch(3),
        _lit_plus_passthroughs(ScalarValue.from_bool(False), String("b")),
        _out_schema_for(ArrowType.BOOL, String("b")),
    )
    assert_true(Bool(out_opt))
    var out = out_opt.take()
    var lit = out.column_as_boolean(0)
    assert_equal(lit.length, 3)
    for i in range(3):
        assert_false(lit.get(i), "FALSE broadcasts as FALSE")


def test_a_date32_literal_output_is_served() raises:
    """4. `SELECT DATE '1995-03-15', ...`. The walker route carries a date on
    the I64 channel while the plan declares DATE32. `broadcast_scalar` builds
    the int32 buffer and labels it DATE32, the layout DATE32 has."""
    var out_opt = eval_project_exprs_over_batch(
        _agg_out_batch(2),
        _lit_plus_passthroughs(
            ScalarValue.date32(Int32(9204)), String("d")
        ),
        _out_schema_for(ArrowType.DATE32, String("d")),
    )
    assert_true(Bool(out_opt), "a DATE32 literal output must be served")
    var out = out_opt.take()
    _assert_passthroughs_intact(out, 2)
    assert_true(
        out.schema.field_arrow_type(0) == ArrowType.DATE32,
        "DATE32, not the int64 the walker route would produce",
    )
    var lit = out.column_as_primitive_int32(0)
    assert_equal(lit.length, 2, "one value per row of this batch")
    for i in range(2):
        assert_equal(Int(lit.get(i)), 9204, "1995-03-15 as days since epoch")


def test_an_int32_literal_output_is_served_at_its_own_width() raises:
    """5. `_infer_runtime_dtype` puts every integer that fits int64 on the I64
    channel, so on the walker route an INT32 literal comes out INT64 against
    an INT32 declaration and declines. DuckDB types an unaliased `SELECT 1` as
    int32, so a binder that follows it produces this shape."""
    var out_opt = eval_project_exprs_over_batch(
        _agg_out_batch(4),
        _lit_plus_passthroughs(ScalarValue.from_int32(Int32(1)), String("1")),
        _out_schema_for(ArrowType.INT32, String("1")),
    )
    assert_true(Bool(out_opt), "an INT32 literal output must be served")
    var out = out_opt.take()
    _assert_passthroughs_intact(out, 4)
    assert_true(
        out.schema.field_arrow_type(0) == ArrowType.INT32,
        "the width the binder declared, not widened to int64",
    )
    var lit = out.column_as_primitive_int32(0)
    assert_equal(lit.length, 4)
    for i in range(4):
        assert_equal(Int(lit.get(i)), 1)


def test_a_float32_literal_output_is_served_at_its_own_width() raises:
    """6. The float sibling of case 5: on the walker route a float32 literal
    comes out FLOAT64 against a FLOAT32 declaration."""
    var out_opt = eval_project_exprs_over_batch(
        _agg_out_batch(3),
        _lit_plus_passthroughs(
            ScalarValue.from_float32(Float32(2.5)), String("f")
        ),
        _out_schema_for(ArrowType.FLOAT32, String("f")),
    )
    assert_true(Bool(out_opt), "a FLOAT32 literal output must be served")
    var out = out_opt.take()
    _assert_passthroughs_intact(out, 3)
    assert_true(out.schema.field_arrow_type(0) == ArrowType.FLOAT32)
    var lit = out.column_as_primitive_float32(0)
    assert_equal(lit.length, 3)
    for i in range(3):
        assert_equal(Float64(lit.get(i)), 2.5)


# =============================================================================
# 7. The length: one value per row of this batch, across a drain.
# =============================================================================


def test_the_constant_column_length_follows_each_batch_not_the_first() raises:
    """The same projection over three batches of different heights, the way a
    chunked drain applies one project operator to every morsel. An arm that
    cached a row count would be right on the first batch only. A fixed-width
    and a variable-width literal, because `broadcast_scalar` builds them
    differently."""
    var heights = List[Int]()
    heights.append(7)
    heights.append(3)
    heights.append(11)
    for hi in range(len(heights)):
        var n = heights[hi]

        var i_opt = eval_project_exprs_over_batch(
            _agg_out_batch(n),
            _lit_plus_passthroughs(
                ScalarValue.from_int64(Int64(42)), String("k")
            ),
            _out_schema_for(ArrowType.INT64, String("k")),
        )
        assert_true(Bool(i_opt), "served at every height")
        var iout = i_opt.take()
        _assert_passthroughs_intact(iout, n)
        var icol = iout.column_as_primitive_int64(0)
        assert_equal(
            icol.length, n, "the constant column is as tall as its batch"
        )
        for r in range(n):
            assert_equal(Int(icol.get(r)), 42)

        var s_opt = eval_project_exprs_over_batch(
            _agg_out_batch(n),
            _lit_plus_passthroughs(
                ScalarValue.from_string(String("z")), String("s")
            ),
            _out_schema_for(ArrowType.STRING, String("s")),
        )
        assert_true(Bool(s_opt))
        var sout = s_opt.take()
        var scol = sout.column_as_string(0)
        assert_equal(
            scol.length, n, "the STRING constant is as tall as its batch"
        )
        for r in range(n):
            assert_equal(scol.get(r), String("z"))


def test_a_literal_over_an_empty_batch_yields_an_empty_column() raises:
    """The extreme of case 7: a GROUP BY over an empty input emits no rows, so
    the projection above it sees a zero-row batch."""
    var out_opt = eval_project_exprs_over_batch(
        _agg_out_batch(0),
        _lit_plus_passthroughs(ScalarValue.from_int64(Int64(1)), String("1")),
        _out_schema_for(ArrowType.INT64, String("1")),
    )
    assert_true(Bool(out_opt), "an empty batch is still in the envelope")
    var out = out_opt.take()
    assert_equal(out.num_rows(), 0, "no rows in, no rows out")
    assert_equal(out.column_as_primitive_int64(0).length, 0)


# =============================================================================
# 8. The declines.
# =============================================================================


def test_a_null_literal_output_still_declines() raises:
    """A NULL literal declines. The plan declares a literal non-nullable while
    `broadcast_scalar` builds an all-NULL buffer with a validity bitmap, and
    the evaluator's contract is to match the plan or decline. (The walker
    route's `_translate_literal` raises on a NULL too.)"""
    var out_opt = eval_project_exprs_over_batch(
        _agg_out_batch(3),
        _lit_plus_passthroughs(
            ScalarValue.null(DType.int64), String("n")
        ),
        _out_schema_for(ArrowType.INT64, String("n")),
    )
    assert_false(
        Bool(out_opt),
        "a NULL literal must decline: the declared field is non-nullable and"
        " the broadcast buffer is all-null",
    )


def test_a_literal_whose_declared_type_disagrees_still_declines() raises:
    """The arm compares the broadcast column with the declared type and
    declines on any divergence: here an INT64 broadcast under a DECIMAL128
    declaration."""
    var sv = ScalarValue.from_int64(Int64(1250))
    var out_opt = eval_project_exprs_over_batch(
        _agg_out_batch(3),
        _lit_plus_passthroughs(sv^, String("d")),
        _out_schema_for(ArrowType.DECIMAL128, String("d")),
    )
    assert_false(
        Bool(out_opt),
        "an INT64 broadcast under a DECIMAL128 declaration must decline",
    )


def test_a_genuinely_untranslatable_expr_still_declines() raises:
    """`col("nope") * 2` names a column the batch does not hold, so
    `translate_expr` raises and the projection declines."""
    var exprs = ExprArray()
    exprs.append(
        Expr.alias(
            Expr.binary(
                BIN_MUL,
                Expr.col_ref(String("nope")),
                Expr.literal(ScalarValue.from_int64(Int64(2))),
            ),
            String("x"),
        )
    )
    exprs.append(Expr.col_ref(String("url")))
    exprs.append(Expr.col_ref(String("c")))
    var out_opt = eval_project_exprs_over_batch(
        _agg_out_batch(3), exprs, _out_schema_for(ArrowType.INT64, String("x"))
    )
    assert_false(
        Bool(out_opt),
        "an expr over a missing column is still out of the envelope",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
