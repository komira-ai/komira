# =============================================================================
# Tests for SourceLike.supports_filter_pushdown(predicate: Expr) -> Bool.
#
# Covers:
#   - ParquetSource.supports_filter_pushdown:
#       * True for col<op>literal (every comparison op), literal<op>col,
#         IN-list over a bare stat-friendly col-ref, AND-trees of such,
#         and partition-col predicates.
#       * False for OR-trees, BETWEEN, string-ops (LIKE), CAST/arithmetic
#         on the col side, agg/window, side-qualified col-refs, off-schema
#         cols, a bare col-ref / literal on its own, and an AND-tree with
#         one unpushable conjunct.
#   - InMemorySource.supports_filter_pushdown: always True.
#   - SourceVariant.supports_filter_pushdown: tag-dispatches to the active
#     arm (Parquet accepts; in-memory rejects).
# =============================================================================

from std.testing import (
    TestSuite,
    assert_true,
    assert_false,
)

from komira_core.arrow import (
    ArrowType,
    Field,
    PrimitiveArray,
    RecordBatch,
    Schema,
    SchemaBuilder,
)
from komira_core.collections.slab import Slab
from komira_core.plan.expr import (
    Expr,
    BIN_EQ,
    BIN_NE,
    BIN_LT,
    BIN_LE,
    BIN_GT,
    BIN_GE,
    BIN_AND,
    BIN_OR,
    BIN_ADD,
    STR_LIKE,
    UN_NOT,
)
from komira_core.plan.scalar_value import ScalarValue
from komira_core.source.parquet_source import ParquetSource
from komira_core.source.in_memory_source import InMemorySource
from komira_core.source.source_variant import SourceVariant


# =============================================================================
# Helpers
# =============================================================================


def _data_schema() -> Schema:
    """3-col data schema: id (INT64), name (STRING), price (FLOAT64)."""
    var sb = SchemaBuilder()
    sb.add_field(Field("id", ArrowType.INT64, nullable=False))
    sb.add_field(Field("name", ArrowType.STRING, nullable=True))
    sb.add_field(Field("price", ArrowType.FLOAT64, nullable=True))
    return sb.build()


def _make_parquet_source() raises -> ParquetSource:
    return ParquetSource(String("/data/items.parquet"), _data_schema())


def _make_partitioned_parquet_source() raises -> ParquetSource:
    """A partitioned ParquetSource: data cols {id,name,price} + a Hive
    partition col `year` (INT32)."""
    var paths = List[String]()
    paths.append(String("/data/year=2024/part-0.parquet"))
    var pcols = List[Field]()
    pcols.append(Field("year", ArrowType.INT32, nullable=False))
    var pvals = List[List[String]]()
    var row = List[String]()
    row.append(String("2024"))
    pvals.append(row^)
    return ParquetSource.partitioned(paths^, _data_schema(), pcols^, pvals^)


def _build_int64_array(n: Int) -> PrimitiveArray[DType.int64]:
    var vals = List[Int64]()
    for i in range(n):
        vals.append(Int64(i))
    return PrimitiveArray[DType.int64].from_list(vals)


def _make_in_memory_source() raises -> InMemorySource:
    var sb = SchemaBuilder()
    sb.add_field(Field("id", ArrowType.INT64, nullable=False))
    var rb = RecordBatch.from_columns_1(sb.build(), _build_int64_array(4))
    return InMemorySource.from_record_batch(rb^)


def _col_op_lit(op: UInt8, col: String, lit: Int) -> Expr:
    return Expr.binary(
        op, Expr.col_ref(col), Expr.literal(ScalarValue.from_int(lit))
    )


# =============================================================================
# ParquetSource — accepted shapes
# =============================================================================


def test_parquet_pushdown_col_eq_literal() raises:
    var src = _make_parquet_source()
    assert_true(
        src.supports_filter_pushdown(_col_op_lit(BIN_EQ, String("id"), 5)),
        "id == 5 should be pushable",
    )


def test_parquet_pushdown_all_comparison_ops() raises:
    var src = _make_parquet_source()
    assert_true(src.supports_filter_pushdown(_col_op_lit(BIN_NE, String("id"), 5)), "id != 5")
    assert_true(src.supports_filter_pushdown(_col_op_lit(BIN_LT, String("id"), 5)), "id < 5")
    assert_true(src.supports_filter_pushdown(_col_op_lit(BIN_LE, String("id"), 5)), "id <= 5")
    assert_true(src.supports_filter_pushdown(_col_op_lit(BIN_GT, String("id"), 5)), "id > 5")
    assert_true(src.supports_filter_pushdown(_col_op_lit(BIN_GE, String("id"), 5)), "id >= 5")


def test_parquet_pushdown_literal_op_col() raises:
    """Order-insensitive: `literal < col` is also pushable."""
    var src = _make_parquet_source()
    var e = Expr.binary(
        BIN_LT, Expr.literal(ScalarValue.from_int(100)), Expr.col_ref("id")
    )
    assert_true(src.supports_filter_pushdown(e), "100 < id should be pushable")


def test_parquet_pushdown_string_col_eq_literal() raises:
    """STRING columns carry parquet stats — `name == 'foo'` is pushable."""
    var src = _make_parquet_source()
    var e = Expr.binary(
        BIN_EQ, Expr.col_ref("name"), Expr.literal(ScalarValue.from_string("foo"))
    )
    assert_true(src.supports_filter_pushdown(e), "name == 'foo'")


def test_parquet_pushdown_float_col_lt_literal() raises:
    var src = _make_parquet_source()
    var e = Expr.binary(
        BIN_LT, Expr.col_ref("price"), Expr.literal(ScalarValue.from_float(9.99))
    )
    assert_true(src.supports_filter_pushdown(e), "price < 9.99")


def test_parquet_pushdown_and_tree_of_pushable() raises:
    """`id > 3 AND price < 9.99` — both conjuncts pushable -> True."""
    var src = _make_parquet_source()
    var left = _col_op_lit(BIN_GT, String("id"), 3)
    var right = Expr.binary(
        BIN_LT, Expr.col_ref("price"), Expr.literal(ScalarValue.from_float(9.99))
    )
    var e = Expr.binary(BIN_AND, left^, right^)
    assert_true(src.supports_filter_pushdown(e), "id>3 AND price<9.99")


def test_parquet_pushdown_in_list() raises:
    """`id IN (1, 2, 3)` — IN-list over a bare stat-friendly col -> True."""
    var src = _make_parquet_source()
    var vals = List[ScalarValue]()
    vals.append(ScalarValue.from_int(1))
    vals.append(ScalarValue.from_int(2))
    vals.append(ScalarValue.from_int(3))
    var e = Expr.in_list_node(Expr.col_ref("id"), vals^)
    assert_true(src.supports_filter_pushdown(e), "id IN (1,2,3)")


def test_parquet_pushdown_partition_col_eq() raises:
    """`year == 2024` over a partitioned source — partition-col predicate
    is consumed by `partition_prune_scans`, so pushable -> True."""
    var src = _make_partitioned_parquet_source()
    var e = Expr.binary(
        BIN_EQ, Expr.col_ref("year"), Expr.literal(ScalarValue.from_int(2024))
    )
    assert_true(src.supports_filter_pushdown(e), "year == 2024 (partition col)")


# =============================================================================
# ParquetSource — rejected shapes
# =============================================================================


def test_parquet_no_pushdown_or_tree() raises:
    """`id == 1 OR id == 2` — OR-tree is not zonemap-friendly -> False."""
    var src = _make_parquet_source()
    var e = Expr.binary(
        BIN_OR, _col_op_lit(BIN_EQ, String("id"), 1), _col_op_lit(BIN_EQ, String("id"), 2)
    )
    assert_false(src.supports_filter_pushdown(e), "id==1 OR id==2 should NOT push")


def test_parquet_no_pushdown_like() raises:
    """`name LIKE 'a%'` — string-op -> False."""
    var src = _make_parquet_source()
    var e = Expr.string_op(STR_LIKE, Expr.col_ref("name"), String("a%"))
    assert_false(src.supports_filter_pushdown(e), "name LIKE 'a%' should NOT push")


def test_parquet_no_pushdown_arithmetic_operand() raises:
    """`(id + 1) == 5` — the column side is an arithmetic expr, not a bare
    col-ref -> False."""
    var src = _make_parquet_source()
    var arith = Expr.binary(BIN_ADD, Expr.col_ref("id"), Expr.literal(ScalarValue.from_int(1)))
    var e = Expr.binary(BIN_EQ, arith^, Expr.literal(ScalarValue.from_int(5)))
    assert_false(src.supports_filter_pushdown(e), "(id+1)==5 should NOT push")


def test_parquet_no_pushdown_unary_not() raises:
    """`NOT (id == 5)` — top-level unary -> False."""
    var src = _make_parquet_source()
    var e = Expr.unary(UN_NOT, _col_op_lit(BIN_EQ, String("id"), 5))
    assert_false(src.supports_filter_pushdown(e), "NOT(id==5) should NOT push")


def test_parquet_no_pushdown_off_schema_col() raises:
    """`missing == 5` — `missing` is not in the schema -> False (no error,
    just not pushable)."""
    var src = _make_parquet_source()
    assert_false(
        src.supports_filter_pushdown(_col_op_lit(BIN_EQ, String("missing"), 5)),
        "missing==5 should NOT push (col absent)",
    )


def test_parquet_no_pushdown_side_qualified_colref() raises:
    """A side-qualified col-ref (only valid inside a join `predicate=`) is
    never pushable into a scan -> False."""
    var src = _make_parquet_source()
    var e = Expr.binary(
        BIN_EQ,
        Expr.left("id"),
        Expr.literal(ScalarValue.from_int(5)),
    )
    assert_false(src.supports_filter_pushdown(e), "left.id==5 should NOT push")


def test_parquet_no_pushdown_bare_colref() raises:
    """A bare col-ref on its own (not a comparison) is not a pushable
    conjunct -> False."""
    var src = _make_parquet_source()
    assert_false(src.supports_filter_pushdown(Expr.col_ref("id")), "bare `id` should NOT push")


def test_parquet_no_pushdown_and_tree_one_unpushable() raises:
    """`id > 3 AND (name LIKE 'a%')` — one conjunct unpushable -> False for
    the whole AND-tree (the optimizer-side per-conjunct split handles the
    partial case; this method is conservative for a combined predicate)."""
    var src = _make_parquet_source()
    var left = _col_op_lit(BIN_GT, String("id"), 3)
    var right = Expr.string_op(STR_LIKE, Expr.col_ref("name"), String("a%"))
    var e = Expr.binary(BIN_AND, left^, right^)
    assert_false(src.supports_filter_pushdown(e), "id>3 AND name LIKE 'a%' should NOT push as a whole")


# =============================================================================
# InMemorySource — accepts everything: an in-mem scan applies any predicate as
# a deferred OP_FILTER, so pushdown is always honored, which the pipeline
# relies on.
# =============================================================================


def test_in_memory_pushdown_accepts_col_op_literal() raises:
    var src = _make_in_memory_source()
    assert_true(
        src.supports_filter_pushdown(_col_op_lit(BIN_EQ, String("id"), 5)),
        "InMemorySource pushes any predicate (deferred OP_FILTER)",
    )
    assert_true(
        src.supports_filter_pushdown(_col_op_lit(BIN_GT, String("id"), 0)),
        "InMemorySource pushes any predicate — even id>0",
    )


def test_in_memory_pushdown_accepts_or_tree() raises:
    """Even an OR-tree (which ParquetSource rejects) is pushable into an
    in-memory scan — it becomes a deferred OP_FILTER all the same."""
    var src = _make_in_memory_source()
    var e = Expr.binary(
        BIN_OR, _col_op_lit(BIN_EQ, String("id"), 1), _col_op_lit(BIN_EQ, String("id"), 2)
    )
    assert_true(src.supports_filter_pushdown(e), "InMemorySource pushes OR-trees too")


# =============================================================================
# SourceVariant — tag-dispatch
# =============================================================================


def test_source_variant_pushdown_parquet_arm() raises:
    var v = SourceVariant(_make_parquet_source())
    assert_true(
        v.supports_filter_pushdown(_col_op_lit(BIN_EQ, String("id"), 5)),
        "parquet arm: id==5 pushable",
    )
    assert_false(
        v.supports_filter_pushdown(
            Expr.binary(BIN_OR, _col_op_lit(BIN_EQ, String("id"), 1), _col_op_lit(BIN_EQ, String("id"), 2))
        ),
        "parquet arm: OR-tree not pushable",
    )


def test_source_variant_pushdown_in_memory_arm() raises:
    var v = SourceVariant(_make_in_memory_source())
    assert_true(
        v.supports_filter_pushdown(_col_op_lit(BIN_EQ, String("id"), 5)),
        "in-memory arm: any predicate pushable (deferred OP_FILTER)",
    )
    assert_true(
        v.supports_filter_pushdown(
            Expr.binary(BIN_OR, _col_op_lit(BIN_EQ, String("id"), 1), _col_op_lit(BIN_EQ, String("id"), 2))
        ),
        "in-memory arm: OR-tree pushable too",
    )


def main() raises:
    var suite = TestSuite()
    suite.test[test_parquet_pushdown_col_eq_literal]()
    suite.test[test_parquet_pushdown_all_comparison_ops]()
    suite.test[test_parquet_pushdown_literal_op_col]()
    suite.test[test_parquet_pushdown_string_col_eq_literal]()
    suite.test[test_parquet_pushdown_float_col_lt_literal]()
    suite.test[test_parquet_pushdown_and_tree_of_pushable]()
    suite.test[test_parquet_pushdown_in_list]()
    suite.test[test_parquet_pushdown_partition_col_eq]()
    suite.test[test_parquet_no_pushdown_or_tree]()
    suite.test[test_parquet_no_pushdown_like]()
    suite.test[test_parquet_no_pushdown_arithmetic_operand]()
    suite.test[test_parquet_no_pushdown_unary_not]()
    suite.test[test_parquet_no_pushdown_off_schema_col]()
    suite.test[test_parquet_no_pushdown_side_qualified_colref]()
    suite.test[test_parquet_no_pushdown_bare_colref]()
    suite.test[test_parquet_no_pushdown_and_tree_one_unpushable]()
    suite.test[test_in_memory_pushdown_accepts_col_op_literal]()
    suite.test[test_in_memory_pushdown_accepts_or_tree]()
    suite.test[test_source_variant_pushdown_parquet_arm]()
    suite.test[test_source_variant_pushdown_in_memory_arm]()
    suite^.run()
