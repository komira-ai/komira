# =============================================================================
# test_partition_predicate_split_shapes.mojo
# =============================================================================
# `split_partition_predicate` over the conjunct shapes the first split test
# file does not build:
#   * a conjunct that is neither a binary op nor an IN-list node: a bare
#     column (partition -> conservative OTHER, data -> residual) and a
#     literal (residual);
#   * the canonical `EXPR_IN_LIST` node (`Expr.in_list_node`): on a
#     partition column (a clean IN, also with zero values), on a data
#     column, and over an expression of a partition or data column;
#   * OR-chains that are not a uniform single-column EQ disjunction: a
#     range leaf on the left or on the right, a column-to-column leaf,
#     literal-on-the-left EQ leaves, EQs over a data column, and EQs over a
#     column whose name is empty; and an OR-chain over the second partition
#     column, which must carry that column's type;
#   * comparisons whose both sides are columns, or whose literal is on the
#     left of a data column.
# Every case checks the Tier-1 constraint list AND whether the conjunct
# stays on the Tier-2 residual: dropping a conjunct from the residual while
# its constraint cannot prune is a wrong answer, so both halves are pinned.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_plan_expr.expr import (
    Expr,
    EXPR_BINARY_OP,
    EXPR_COL_REF,
    EXPR_IN_LIST,
    BIN_ADD,
    BIN_AND,
    BIN_EQ,
    BIN_GT,
    BIN_LT,
    BIN_OR,
)
from komira_plan_expr.scalar_value import ScalarValue
from komira_fs.pruned_hive_discovery import _OP_IN, _OP_OTHER
from komira_scan_planning.partition_predicate_split import (
    split_partition_predicate,
    should_use_pruned_discovery,
)


def _col(name: String) -> Expr:
    return Expr.col_ref(name)


def _lit_str(v: String) -> Expr:
    return Expr.literal(ScalarValue.from_string(v))


def _lit_int(v: Int) -> Expr:
    return Expr.literal(ScalarValue.from_int(v))


def _bin(op: UInt8, var l: Expr, var r: Expr) -> Expr:
    return Expr.binary(op, l^, r^)


def _cols(a: String, b: String) -> List[String]:
    var c = List[String]()
    c.append(a)
    c.append(b)
    return c^


def _types(a: ArrowType, b: ArrowType) -> List[ArrowType]:
    var t = List[ArrowType]()
    t.append(a)
    t.append(b)
    return t^


# dt (STRING) and yr (INT64) are the partition columns of every case below
# unless a case says otherwise.
def _pcols() -> List[String]:
    return _cols(String("dt"), String("yr"))


def _ptypes() -> List[ArrowType]:
    return _types(ArrowType.STRING, ArrowType.INT64)


def _strs(a: String, b: String) -> List[ScalarValue]:
    var v = List[ScalarValue]()
    v.append(ScalarValue.from_string(a))
    v.append(ScalarValue.from_string(b))
    return v^


def _assert_residual_only(filter: Expr) raises:
    """The filter yields no Tier-1 constraint and stays whole on Tier-2."""
    var split = split_partition_predicate(filter, _pcols(), _ptypes())
    assert_equal(split.partition_predicate.num_constraints(), 0)
    assert_true(Bool(split.residual))
    assert_false(should_use_pruned_discovery(split))


def _assert_conservative(filter: Expr, col: String) raises:
    """The filter yields one OTHER constraint on `col` (the fold keeps every
    file) and stays on Tier-2 so its rows are still filtered."""
    var split = split_partition_predicate(filter, _pcols(), _ptypes())
    assert_equal(split.partition_predicate.num_constraints(), 1)
    ref c = split.partition_predicate.constraints[0]
    assert_equal(c.op, _OP_OTHER)
    assert_equal(c.col, col)
    assert_equal(len(c.values), 0)
    assert_true(Bool(split.residual))
    assert_true(should_use_pruned_discovery(split))


# --- conjuncts that are neither a binary op nor an IN-list node ------------


def test_bare_partition_col_conjunct_is_conservative() raises:
    # WHERE dt AND amount > 1: the bare `dt` conjunct cannot enumerate, so it
    # is an OTHER constraint on dt and both conjuncts stay on the residual.
    var filter = _bin(
        BIN_AND, _col(String("dt")), _bin(BIN_GT, _col(String("amount")), _lit_int(1))
    )
    var split = split_partition_predicate(filter, _pcols(), _ptypes())
    assert_equal(split.partition_predicate.num_constraints(), 1)
    ref c = split.partition_predicate.constraints[0]
    assert_equal(c.op, _OP_OTHER)
    assert_equal(c.col, String("dt"))
    assert_true(Bool(split.residual))
    ref r = split.residual.value()
    assert_equal(r.tag, EXPR_BINARY_OP)
    assert_equal(r.binary_op(), BIN_AND)
    assert_equal(r.binary_left_ref().tag, EXPR_COL_REF)
    assert_equal(r.binary_left_ref().col_ref_name(), String("dt"))


def test_bare_data_col_and_literal_conjuncts_are_residual() raises:
    # WHERE active AND TRUE: neither names a partition column.
    _assert_residual_only(
        _bin(
            BIN_AND,
            _col(String("active")),
            Expr.literal(ScalarValue.from_bool(True)),
        )
    )


# --- the EXPR_IN_LIST node ---------------------------------------------------


def test_in_list_node_on_partition_col_is_clean_in() raises:
    var filter = Expr.in_list_node(
        _col(String("dt")), _strs(String("a"), String("b"))
    )
    var split = split_partition_predicate(filter, _pcols(), _ptypes())
    assert_equal(split.partition_predicate.num_constraints(), 1)
    ref c = split.partition_predicate.constraints[0]
    assert_equal(c.op, _OP_IN)
    assert_equal(c.col, String("dt"))
    assert_equal(len(c.values), 2)
    assert_equal(c.values[0], String("a"))
    assert_equal(c.values[1], String("b"))
    assert_true(c.arrow_type == ArrowType.STRING)
    assert_false(Bool(split.residual))
    assert_true(should_use_pruned_discovery(split))


def test_in_list_node_takes_the_type_of_its_column() raises:
    # yr is the SECOND partition column: the constraint carries its INT64
    # type, not the first column's STRING.
    var vs = List[ScalarValue]()
    vs.append(ScalarValue.from_int(2020))
    var filter = Expr.in_list_node(_col(String("yr")), vs^)
    var split = split_partition_predicate(filter, _pcols(), _ptypes())
    ref c = split.partition_predicate.constraints[0]
    assert_equal(c.col, String("yr"))
    assert_equal(c.values[0], String("2020"))
    assert_true(c.arrow_type == ArrowType.INT64)


def test_in_list_node_with_no_values_is_clean_empty_in() raises:
    # `dt IN ()` is FALSE for every row: a clean IN with zero values (the
    # fold then keeps no file), nothing left on the residual.
    var filter = Expr.in_list_node(_col(String("dt")), List[ScalarValue]())
    var split = split_partition_predicate(filter, _pcols(), _ptypes())
    assert_equal(split.partition_predicate.num_constraints(), 1)
    ref c = split.partition_predicate.constraints[0]
    assert_equal(c.op, _OP_IN)
    assert_equal(len(c.values), 0)
    assert_false(Bool(split.residual))


def test_in_list_node_on_data_col_is_residual() raises:
    _assert_residual_only(
        Expr.in_list_node(_col(String("region")), _strs(String("a"), String("b")))
    )


def test_in_list_node_over_partition_expression_is_conservative() raises:
    # (1 + yr) IN (2021): the partition column is on the RIGHT of the child
    # expression, so the reference walk must look past the left side.
    var vs = List[ScalarValue]()
    vs.append(ScalarValue.from_int(2021))
    _assert_conservative(
        Expr.in_list_node(_bin(BIN_ADD, _lit_int(1), _col(String("yr"))), vs^),
        String("yr"),
    )


def test_in_list_node_over_data_expression_is_residual() raises:
    var vs = List[ScalarValue]()
    vs.append(ScalarValue.from_int(2))
    _assert_residual_only(
        Expr.in_list_node(_bin(BIN_ADD, _col(String("amount")), _lit_int(1)), vs^)
    )


# --- OR-chains that do not reconstruct into an IN ----------------------------


def test_or_chain_literal_on_left_reconstructs() raises:
    # ('a' = dt) OR ('b' = dt) is the same IN as dt IN ('a', 'b').
    var filter = _bin(
        BIN_OR,
        _bin(BIN_EQ, _lit_str(String("a")), _col(String("dt"))),
        _bin(BIN_EQ, _lit_str(String("b")), _col(String("dt"))),
    )
    var split = split_partition_predicate(filter, _pcols(), _ptypes())
    assert_equal(split.partition_predicate.num_constraints(), 1)
    ref c = split.partition_predicate.constraints[0]
    assert_equal(c.op, _OP_IN)
    assert_equal(c.col, String("dt"))
    assert_equal(len(c.values), 2)
    assert_equal(c.values[0], String("a"))
    assert_equal(c.values[1], String("b"))
    assert_true(c.arrow_type == ArrowType.STRING)
    assert_false(Bool(split.residual))


def test_or_chain_takes_the_type_of_its_column() raises:
    # (yr = 2020) OR (yr = 2021) over the SECOND partition column: the IN
    # carries yr's INT64 type, not dt's STRING (a STRING type would make the
    # fold compare the values lexically).
    var filter = _bin(
        BIN_OR,
        _bin(BIN_EQ, _col(String("yr")), _lit_int(2020)),
        _bin(BIN_EQ, _col(String("yr")), _lit_int(2021)),
    )
    var split = split_partition_predicate(filter, _pcols(), _ptypes())
    assert_equal(split.partition_predicate.num_constraints(), 1)
    ref c = split.partition_predicate.constraints[0]
    assert_equal(c.op, _OP_IN)
    assert_equal(c.col, String("yr"))
    assert_equal(len(c.values), 2)
    assert_equal(c.values[0], String("2020"))
    assert_equal(c.values[1], String("2021"))
    assert_true(c.arrow_type == ArrowType.INT64)
    assert_false(Bool(split.residual))


def test_or_chain_range_leaf_left_is_conservative() raises:
    # (dt < 'a') OR (dt = 'b'): the left leaf is no EQ.
    _assert_conservative(
        _bin(
            BIN_OR,
            _bin(BIN_LT, _col(String("dt")), _lit_str(String("a"))),
            _bin(BIN_EQ, _col(String("dt")), _lit_str(String("b"))),
        ),
        String("dt"),
    )


def test_or_chain_range_leaf_right_is_conservative() raises:
    # (dt = 'a') OR (dt < 'b'): the right leaf is no EQ.
    _assert_conservative(
        _bin(
            BIN_OR,
            _bin(BIN_EQ, _col(String("dt")), _lit_str(String("a"))),
            _bin(BIN_LT, _col(String("dt")), _lit_str(String("b"))),
        ),
        String("dt"),
    )


def test_or_chain_col_col_leaf_is_conservative() raises:
    # (dt = region) OR (dt = 'a'): the left EQ has no literal side.
    _assert_conservative(
        _bin(
            BIN_OR,
            _bin(BIN_EQ, _col(String("dt")), _col(String("region"))),
            _bin(BIN_EQ, _col(String("dt")), _lit_str(String("a"))),
        ),
        String("dt"),
    )


def test_or_chain_on_data_col_is_residual() raises:
    # (amount = 1) OR (amount = 2) reconstructs over a DATA column.
    _assert_residual_only(
        _bin(
            BIN_OR,
            _bin(BIN_EQ, _col(String("amount")), _lit_int(1)),
            _bin(BIN_EQ, _col(String("amount")), _lit_int(2)),
        )
    )


def test_or_of_data_ranges_is_residual() raises:
    _assert_residual_only(
        _bin(
            BIN_OR,
            _bin(BIN_GT, _col(String("amount")), _lit_int(1)),
            _bin(BIN_LT, _col(String("qty")), _lit_int(2)),
        )
    )


def test_or_chain_over_empty_col_name_is_not_pinned() raises:
    # A column named "" is listed as a partition column. The OR-chain over it
    # must not become an IN constraint: the empty name is the "no column
    # seen yet" marker of the reconstruction, so it never pins a column.
    var filter = _bin(
        BIN_OR,
        _bin(BIN_EQ, _col(String("")), _lit_str(String("a"))),
        _bin(BIN_EQ, _col(String("")), _lit_str(String("b"))),
    )
    var split = split_partition_predicate(
        filter, _cols(String(""), String("dt")), _ptypes()
    )
    assert_equal(split.partition_predicate.num_constraints(), 0)
    assert_true(Bool(split.residual))


# --- comparisons with no column-vs-literal partition shape -------------------


def test_literal_left_of_data_col_is_residual() raises:
    _assert_residual_only(_bin(BIN_LT, _lit_int(5), _col(String("amount"))))


def test_data_col_vs_data_col_is_residual() raises:
    _assert_residual_only(
        _bin(BIN_GT, _col(String("amount")), _col(String("qty")))
    )


def test_data_col_vs_partition_col_is_conservative() raises:
    # amount > yr: the partition column is on the right.
    _assert_conservative(
        _bin(BIN_GT, _col(String("amount")), _col(String("yr"))), String("yr")
    )


def main() raises:
    var suite = TestSuite()
    suite.test[test_bare_partition_col_conjunct_is_conservative]()
    suite.test[test_bare_data_col_and_literal_conjuncts_are_residual]()
    suite.test[test_in_list_node_on_partition_col_is_clean_in]()
    suite.test[test_in_list_node_takes_the_type_of_its_column]()
    suite.test[test_in_list_node_with_no_values_is_clean_empty_in]()
    suite.test[test_in_list_node_on_data_col_is_residual]()
    suite.test[test_in_list_node_over_partition_expression_is_conservative]()
    suite.test[test_in_list_node_over_data_expression_is_residual]()
    suite.test[test_or_chain_literal_on_left_reconstructs]()
    suite.test[test_or_chain_takes_the_type_of_its_column]()
    suite.test[test_or_chain_range_leaf_left_is_conservative]()
    suite.test[test_or_chain_range_leaf_right_is_conservative]()
    suite.test[test_or_chain_col_col_leaf_is_conservative]()
    suite.test[test_or_chain_on_data_col_is_residual]()
    suite.test[test_or_of_data_ranges_is_residual]()
    suite.test[test_or_chain_over_empty_col_name_is_not_pinned]()
    suite.test[test_literal_left_of_data_col_is_residual]()
    suite.test[test_data_col_vs_data_col_is_residual]()
    suite.test[test_data_col_vs_partition_col_is_conservative]()
    suite^.run()
