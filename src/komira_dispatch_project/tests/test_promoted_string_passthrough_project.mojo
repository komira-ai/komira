# =============================================================================
# test_promoted_string_passthrough_project.mojo: a passthrough of a promoted
# (`large_string`) column through a projection that declared `string`
# =============================================================================
#
# SUBJECT: `compute_project.eval_project_exprs_over_batch`'s passthrough arm
# and the predicates it consults, `_passthrough_storage_compatible` and
# `_varlen_offset_width_alias`.
#
# The shape: an aggregate's group-key drain promotes a string key to
# `large_string` when the staged bytes pass the int32 offset limit
# (`Column.from_strings_with_validity_promoting`), while the projection above
# it declared `string` when it was planned. The values are the same; only the
# offset width differs. The query is `SELECT 1, url, count(*) AS c FROM t
# GROUP BY 1, url`: a literal, the `url` key and the count.
#
# 0. CONTROL: a narrow passthrough (a `string` column under a `string`
#    declaration) is served.
# 1. A promoted column under a `string` declaration is served. The check
#    that the promotion fired comes first: a fixture that stayed narrow would
#    make every later assertion a repeat of case 0.
# 2. The values: every row is read back. The fixture holds an empty string,
#    a NULL, and a one-byte value right after a NULL, the rows that merge or
#    shift if 64-bit offsets are read at a 4-byte stride.
# 3. The output field states `large_string`, the storage the emitted column
#    has, not the declared `string`.
# 4. `StringColumnView` (which takes its stride from the column's layout)
#    reads the same bytes as the typed accessor.
# 5. The reverse: a narrow column under a `large_string` declaration.
# 6. The declines: INT32 under an INT64 declaration and INT64 under a STRING
#    declaration still decline.
#
# The promotion is reached through the producer's own threshold parameter
# (`offset_promote_at`), lowered from the 2 GiB limit to 16 bytes: the same
# buffers and the same type as a production promotion.
# =============================================================================

from std.testing import TestSuite, assert_true, assert_equal, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.batch_view import batch_view_over
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Schema, SchemaBuilder, Field
from komira_arrow.string_column_view import StringColumnView
from komira_buffer.heap_region import HeapRegion
from komira_plan_expr.expr import Expr
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_ir.logical_plan import ExprArray

from komira_dispatch_project.compute_project import (
    eval_project_exprs_over_batch,
)


# =============================================================================
# FIXTURE: the batch an aggregate hands its parent projection: the group key
# (`url`, nullable) and the count (`c`, INT64).
# =============================================================================
#
# The seven rows are chosen. A NULL string slot and an empty string are both a
# zero-length byte span, told apart only by the validity bitmap, so offsets
# read at the wrong stride make rows 1/2 and 4/5 indistinguishable while
# `length()` stays right. Row 6 is a one-byte value right after a NULL, the
# shortest span with content.
# =============================================================================

comptime _N_ROWS: Int = 7

# The producer's promotion threshold for the promoted cases: 16 bytes. The
# fixture stages 39 bytes, so the producer promotes.
comptime _PROMOTE_AT: Int = 16


def _url_values() -> List[String]:
    var v = List[String]()
    v.append(String("https://a.example/0"))  # 19 bytes
    v.append(String(""))  # EMPTY, not null
    v.append(String(""))  # placeholder under a NULL slot
    v.append(String("https://b.example/3"))  # 19 bytes
    v.append(String(""))  # EMPTY again, right after a long value
    v.append(String(""))  # placeholder under a NULL slot
    v.append(String("z"))  # 1 byte, right after a NULL
    return v^


def _url_valid() -> List[Bool]:
    var v = List[Bool]()
    v.append(True)
    v.append(True)  # the EMPTY STRING is VALID
    v.append(False)  # NULL
    v.append(True)
    v.append(True)  # the EMPTY STRING is VALID
    v.append(False)  # NULL
    v.append(True)
    return v^


def _agg_out_schema(url_at: ArrowType) raises -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field(String("url"), url_at, True))
    sb.add_field(Field(String("c"), ArrowType.INT64, False))
    return sb.build()


def _agg_out_batch(promote: Bool) raises -> RecordBatch:
    """The aggregate's drain output. The `url` column is built by the
    promoting producer (`Column.from_strings_with_validity_promoting`), so
    whether it comes out `string` or `large_string` is decided by the
    producer's own predicate. `promote` lowers its threshold to
    `_PROMOTE_AT`; otherwise it keeps the 2 GiB default."""
    var counts = PrimitiveArray[DType.int64].allocate(_N_ROWS)
    for i in range(_N_ROWS):
        counts.store[1](i, SIMD[DType.int64, 1](Int64(100 + i)))
    var url_col: Column[HeapRegion]
    if promote:
        url_col = Column.from_strings_with_validity_promoting(
            _url_values(), _url_valid(), offset_promote_at=_PROMOTE_AT
        )
    else:
        url_col = Column.from_strings_with_validity_promoting(
            _url_values(), _url_valid()
        )
    var url_at = url_col.arrow_type
    var rbb = RecordBatchBuilder.with_capacity(2)
    rbb.add_column(url_col^)
    rbb.add_column(Column.from_primitive[DType.int64](counts))
    return rbb.build(_agg_out_schema(url_at))


def _lit_url_count_exprs() raises -> ExprArray:
    """The re-projected constant, then the two columns the aggregate produced.
    `url` is a bare `EXPR_COL_REF`."""
    var exprs = ExprArray()
    var one = ScalarValue.from_int64(Int64(1))
    exprs.append(Expr.alias(Expr.literal(one^), String("1")))
    exprs.append(Expr.col_ref(String("url")))
    exprs.append(Expr.col_ref(String("c")))
    return exprs^


def _plan_out_schema(declared_url_at: ArrowType) raises -> Schema:
    """The schema the plan declared for that projection, with `url` declared
    `declared_url_at`."""
    var sb = SchemaBuilder()
    sb.add_field(Field(String("1"), ArrowType.INT64, False))
    sb.add_field(Field(String("url"), declared_url_at, True))
    sb.add_field(Field(String("c"), ArrowType.INT64, False))
    return sb.build()


# =============================================================================
# The value oracle: a passthrough is an identity.
# =============================================================================


def _assert_url_values_survived(imm out: RecordBatch) raises:
    """Every row is read back: `num_rows()` comes from the Column and stays
    right however the offsets are decoded."""
    assert_equal(out.num_rows(), _N_ROWS, "a projection keeps every row")
    var vals = _url_values()
    var valid = _url_valid()
    var wide = out.schema.field_arrow_type(1) == ArrowType.LARGE_STRING

    if wide:
        var arr = out.column_as_large_string(1)
        assert_equal(arr.length, _N_ROWS, "every row survives the passthrough")
        for i in range(_N_ROWS):
            assert_equal(
                arr.is_null(i),
                not valid[i],
                "NULL and empty must stay apart: both are a zero-length span,"
                " told apart only by the validity bitmap",
            )
            if valid[i]:
                assert_equal(arr.get(i), vals[i], "the value itself")
    else:
        var arr = out.column_as_string(1)
        assert_equal(arr.length, _N_ROWS, "every row survives the passthrough")
        for i in range(_N_ROWS):
            assert_equal(arr.is_null(i), not valid[i])
            if valid[i]:
                assert_equal(arr.get(i), vals[i])

    var counts = out.column_as_primitive_int64(2)
    assert_equal(counts.length, _N_ROWS)
    for i in range(_N_ROWS):
        assert_equal(Int(counts.get(i)), 100 + i)

    var lit = out.column_as_primitive_int64(0)
    assert_equal(lit.length, _N_ROWS, "one constant per row of this batch")
    for i in range(_N_ROWS):
        assert_equal(Int(lit.get(i)), 1)


# =============================================================================
# 0. CONTROL: the narrow passthrough.
# =============================================================================


def test_a_narrow_string_passthrough_is_served_control() raises:
    """At the default threshold the fixture's 39 bytes stay `string`, the
    declared type agrees, and the passthrough is served. A failure in case 1
    then cannot be blamed on the fixture, the expressions or the oracle."""
    var batch = _agg_out_batch(False)
    assert_true(
        batch.schema.field_arrow_type(0) == ArrowType.STRING,
        "at the default threshold the producer must not promote",
    )
    var out_opt = eval_project_exprs_over_batch(
        batch^, _lit_url_count_exprs(), _plan_out_schema(ArrowType.STRING)
    )
    assert_true(Bool(out_opt), "a narrow string passthrough must be served")
    var out = out_opt.take()
    assert_true(
        out.schema.field_arrow_type(1) == ArrowType.STRING,
        "and it stays narrow",
    )
    _assert_url_values_survived(out)


# =============================================================================
# 1, 2, 3. A promoted column under a `string` declaration.
# =============================================================================


def test_a_promoted_large_string_passthrough_is_served() raises:
    """A bare column reference to `url`, declared `string` over a
    `large_string` source. `_passthrough_storage_compatible(large_string,
    string)` is False (the buffers differ); `_varlen_offset_width_alias`
    admits the pair. Without it the projection declines."""
    var batch = _agg_out_batch(True)
    # The fixture check first: if the promotion did not fire, every assertion
    # below would repeat case 0.
    assert_true(
        batch.schema.field_arrow_type(0) == ArrowType.LARGE_STRING,
        "the promotion did not fire, and every assertion below would be"
        " vacuous",
    )
    var out_opt = eval_project_exprs_over_batch(
        batch^, _lit_url_count_exprs(), _plan_out_schema(ArrowType.STRING)
    )
    assert_true(
        Bool(out_opt),
        "a bare column reference to a promoted string column must pass"
        " through: string and large_string hold the same values at two"
        " offset widths",
    )
    var out = out_opt.take()

    # 3. The output field states the storage the emitted column has. The
    # declared `string` here would tell a reader 32-bit offsets over a 64-bit
    # buffer: wrong values, a right row count, nothing raised.
    assert_equal(out.num_columns(), 3)
    assert_equal(out.schema.field_name(1), String("url"))
    assert_true(
        out.schema.field_arrow_type(1) == ArrowType.LARGE_STRING,
        "the emitted field must state large_string, the storage the column"
        " has, not the string the plan declared",
    )
    assert_true(
        out.schema.field_nullable(1),
        "the source's nullability is carried through",
    )

    # 2. The values.
    _assert_url_values_survived(out)


# =============================================================================
# 4. The untyped view reads the promoted passthrough at the right stride.
# =============================================================================


def test_the_untyped_view_reads_the_promoted_passthrough_at_the_right_stride(
) raises:
    """`StringColumnView` takes its offset stride from the column's layout
    (`ARROW_LAYOUT_OFFSETS_I64` for a `large_string`). It is a consumer of
    whatever the projection emits, so it must read the promoted column's
    offsets at the 8-byte stride."""
    var batch = _agg_out_batch(True)
    assert_true(batch.schema.field_arrow_type(0) == ArrowType.LARGE_STRING)
    var out_opt = eval_project_exprs_over_batch(
        batch^, _lit_url_count_exprs(), _plan_out_schema(ArrowType.STRING)
    )
    assert_true(Bool(out_opt))
    var out = out_opt.take()

    var bv = batch_view_over(out)
    var sv = StringColumnView(bv._batch, 1)
    assert_equal(sv.length(), _N_ROWS)
    var vals = _url_values()
    var valid = _url_valid()
    var running = 0
    for i in range(_N_ROWS):
        assert_equal(
            sv.offset_at(i),
            running,
            "cumulative offsets read at the INT64 stride",
        )
        var cell = sv.get(i)
        var expect_len = 0 if not valid[i] else vals[i].byte_length()
        assert_equal(cell.length(), expect_len, "the cell's byte span")
        if valid[i] and expect_len > 0:
            assert_equal(cell.to_string(), vals[i])
        running += expect_len


# =============================================================================
# 5. The reverse direction.
# =============================================================================


def test_a_narrow_source_under_a_large_string_declaration_is_served() raises:
    """A plan that declared `large_string` over a source that did not
    promote. Admitted for the same reason, and the emitted field states
    `string`, the storage the column has."""
    var batch = _agg_out_batch(False)
    assert_true(batch.schema.field_arrow_type(0) == ArrowType.STRING)
    var out_opt = eval_project_exprs_over_batch(
        batch^, _lit_url_count_exprs(), _plan_out_schema(ArrowType.LARGE_STRING)
    )
    assert_true(
        Bool(out_opt), "a narrow source under a wide declaration is served"
    )
    var out = out_opt.take()
    assert_true(
        out.schema.field_arrow_type(1) == ArrowType.STRING,
        "the emitted field states the STORAGE, which here is narrow",
    )
    _assert_url_values_survived(out)


# =============================================================================
# 6. The declines.
# =============================================================================


def test_a_genuine_int_width_divergence_still_declines() raises:
    """INT32 under an INT64 declaration is a width divergence, and it still
    declines: a column at the wrong width misleads every kernel that reads it
    at the declared stride."""
    var narrow = PrimitiveArray[DType.int32].allocate(3)
    for i in range(3):
        narrow.store[1](i, SIMD[DType.int32, 1](Int32(7 + i)))
    var sb = SchemaBuilder()
    sb.add_field(Field(String("k"), ArrowType.INT32, False))
    var rbb = RecordBatchBuilder.with_capacity(1)
    rbb.add_column(Column.from_primitive[DType.int32](narrow))
    var batch = rbb.build(sb.build())

    var exprs = ExprArray()
    exprs.append(Expr.col_ref(String("k")))
    var osb = SchemaBuilder()
    osb.add_field(Field(String("k"), ArrowType.INT64, False))
    var out_opt = eval_project_exprs_over_batch(batch^, exprs, osb.build())
    assert_false(
        Bool(out_opt),
        "an INT32 column under an INT64 declaration must STILL decline",
    )


def test_a_cross_family_passthrough_still_declines() raises:
    """The admission is the offset width of one variable-length type. An
    INT64 column under a STRING declaration shares neither values nor buffers,
    and declines."""
    var batch = _agg_out_batch(False)
    var exprs = ExprArray()
    exprs.append(Expr.col_ref(String("c")))
    var osb = SchemaBuilder()
    osb.add_field(Field(String("c"), ArrowType.STRING, False))
    var out_opt = eval_project_exprs_over_batch(batch^, exprs, osb.build())
    assert_false(
        Bool(out_opt),
        "an INT64 column under a STRING declaration must STILL decline",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
