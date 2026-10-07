# =============================================================================
# test_partition_predicate_split.mojo
# =============================================================================
# unit tests for the optimizer predicate-split: given a scan filter
# `Expr` + the partition schema (names + types), assert the correct
# (PartitionPredicate Tier-1, residual data-pred Tier-2) split + the discovery
# routing decision (EagerGlob vs PrunedHive).
#
# Tested AT THE OPTIMIZER/PLAN SEAM — `split_partition_predicate(...)` is a
# pure function over an `Expr` + the partition schema. NO ctx.materialize / NO
# typed-read binding (avoids the Path-4 source-mode compile that bit ).
#
# Coverage (the dispatch test matrix):
#   * EQ on a partition col -> Tier-1 (clean, no residual).
#   * range (>) on a DATA col -> Tier-2 (residual, empty partition pred).
#   * mixed `dt='..' AND amount>100` -> dt to Tier-1, amount>100 to Tier-2.
#   * range on a PARTITION col -> Tier-1 fold constraint (clean).
#   * literal-on-left flip (`100 < amount` form).
#   * IN-list (OR-of-EQ on a partition col) -> Tier-1 IN constraint.
#   * conservative OTHER (col-on-both-sides / OR mixing a partition col).
#   * no filter conjunct touches a partition col -> EagerGlobDiscovery routing.

# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_plan_expr.expr import (
    Expr,
    EXPR_BINARY_OP,
    BIN_EQ,
    BIN_GT,
    BIN_LT,
    BIN_AND,
    BIN_OR,
)
from komira_plan_expr.scalar_value import ScalarValue
from komira_scan_planning.partition_predicate_split import (
    split_partition_predicate,
    should_use_pruned_discovery,
    PredicateSplit,
)

# Mirror the _OP_* constants so the tests
# can assert the constraint op without importing module-privates.
comptime _OP_EQ: Int = 0
comptime _OP_IN: Int = 1
comptime _OP_LT: Int = 2
comptime _OP_GT: Int = 4
comptime _OP_OTHER: Int = 7


# =============================================================================
# small Expr builders (so each test reads like SQL).
# =============================================================================


def _col(name: String) -> Expr:
    return Expr.col_ref(name)


def _lit_str(v: String) -> Expr:
    return Expr.literal(ScalarValue.from_string(v))


def _lit_int(v: Int) -> Expr:
    return Expr.literal(ScalarValue.from_int(v))


def _eq(var l: Expr, var r: Expr) -> Expr:
    return Expr.binary(BIN_EQ, l^, r^)


def _gt(var l: Expr, var r: Expr) -> Expr:
    return Expr.binary(BIN_GT, l^, r^)


def _lt(var l: Expr, var r: Expr) -> Expr:
    return Expr.binary(BIN_LT, l^, r^)


def _and(var l: Expr, var r: Expr) -> Expr:
    return Expr.binary(BIN_AND, l^, r^)


def _or(var l: Expr, var r: Expr) -> Expr:
    return Expr.binary(BIN_OR, l^, r^)


# A two-column Hive schema: dt (STRING) partition col + region (STRING).
def _part_cols() -> List[String]:
    var c = List[String]()
    c.append(String("dt"))
    c.append(String("region"))
    return c^


def _part_types() -> List[ArrowType]:
    var t = List[ArrowType]()
    t.append(ArrowType.STRING)
    t.append(ArrowType.STRING)
    return t^


# A single INT64 partition col `yr`, for the numeric-range cases.
def _yr_cols() -> List[String]:
    var c = List[String]()
    c.append(String("yr"))
    return c^


def _yr_types() -> List[ArrowType]:
    var t = List[ArrowType]()
    t.append(ArrowType.INT64)
    return t^


# =============================================================================
# the split cases.
# =============================================================================


def test_eq_on_partition_col_is_tier1() raises:
    # WHERE dt = '2026-11-04'  ->  Tier-1 EQ constraint, NO residual.
    var filter = _eq(_col(String("dt")), _lit_str(String("2026-11-04")))
    var split = split_partition_predicate(filter^, _part_cols(), _part_types())
    assert_equal(split.partition_predicate.num_constraints(), 1)
    ref c = split.partition_predicate.constraints[0]
    assert_equal(c.col, String("dt"))
    assert_equal(c.op, _OP_EQ)
    assert_equal(len(c.values), 1)
    assert_equal(c.values[0], String("2026-11-04"))
    assert_false(Bool(split.residual))  # whole filter consumed by Tier-1
    assert_true(should_use_pruned_discovery(split))


def test_range_on_data_col_is_tier2() raises:
    # WHERE amount > 100  ->  Tier-2 residual, EMPTY partition predicate.
    var filter = _gt(_col(String("amount")), _lit_int(100))
    var split = split_partition_predicate(filter^, _part_cols(), _part_types())
    assert_equal(split.partition_predicate.num_constraints(), 0)
    assert_true(Bool(split.residual))  # data pred stays for Tier-2 pushdown
    assert_false(split.has_partition_pruning())
    # routing: no partition pruning -> EagerGlobDiscovery (today's default).
    assert_false(should_use_pruned_discovery(split))


def test_mixed_partition_and_data_splits_both() raises:
    # WHERE dt = '2026-11-04' AND amount > 100  ->  dt to Tier-1, amount to Tier-2.
    var part = _eq(_col(String("dt")), _lit_str(String("2026-11-04")))
    var data = _gt(_col(String("amount")), _lit_int(100))
    var filter = _and(part^, data^)
    var split = split_partition_predicate(filter^, _part_cols(), _part_types())
    # Tier-1: exactly the dt EQ.
    assert_equal(split.partition_predicate.num_constraints(), 1)
    ref c = split.partition_predicate.constraints[0]
    assert_equal(c.col, String("dt"))
    assert_equal(c.op, _OP_EQ)
    # Tier-2: the amount>100 residual remains.
    assert_true(Bool(split.residual))
    assert_true(should_use_pruned_discovery(split))


def test_range_on_partition_col_is_tier1_fold() raises:
    # WHERE yr > 2020  ->  Tier-1 GT fold constraint (non-enumerable range on a
    # PARTITION col; filter_partitions fold evaluates it). Clean (no
    # residual): the prefix-walk + fold cover it.
    var filter = _gt(_col(String("yr")), _lit_int(2020))
    var split = split_partition_predicate(filter^, _yr_cols(), _yr_types())
    assert_equal(split.partition_predicate.num_constraints(), 1)
    ref c = split.partition_predicate.constraints[0]
    assert_equal(c.col, String("yr"))
    assert_equal(c.op, _OP_GT)
    assert_equal(c.values[0], String("2020"))
    assert_false(Bool(split.residual))
    assert_true(should_use_pruned_discovery(split))


def test_literal_on_left_flips_op() raises:
    # WHERE 2020 < yr  ->  reads as `yr > 2020` (op flipped).
    var filter = _lt(_lit_int(2020), _col(String("yr")))
    var split = split_partition_predicate(filter^, _yr_cols(), _yr_types())
    assert_equal(split.partition_predicate.num_constraints(), 1)
    ref c = split.partition_predicate.constraints[0]
    assert_equal(c.col, String("yr"))
    assert_equal(c.op, _OP_GT)  # LT flipped to GT
    assert_equal(c.values[0], String("2020"))


def test_in_list_on_partition_col_reconstructs() raises:
    # WHERE dt IN ('a','b','c')  arrives folded as the OR-of-EQ chain
    # ((dt=='a') OR (dt=='b')) OR (dt=='c'). The split reconstructs it into an
    # IN constraint (fan-out -> 3 targeted prefixes).
    var ab = _or(
        _eq(_col(String("dt")), _lit_str(String("a"))),
        _eq(_col(String("dt")), _lit_str(String("b"))),
    )
    var filter = _or(ab^, _eq(_col(String("dt")), _lit_str(String("c"))))
    var split = split_partition_predicate(filter^, _part_cols(), _part_types())
    assert_equal(split.partition_predicate.num_constraints(), 1)
    ref c = split.partition_predicate.constraints[0]
    assert_equal(c.col, String("dt"))
    assert_equal(c.op, _OP_IN)
    assert_equal(len(c.values), 3)
    assert_equal(c.values[0], String("a"))
    assert_equal(c.values[1], String("b"))
    assert_equal(c.values[2], String("c"))
    # IN is fully enumerable -> clean, no residual.
    assert_false(Bool(split.residual))
    assert_true(should_use_pruned_discovery(split))


def test_or_across_two_partition_cols_is_conservative() raises:
    # WHERE dt='a' OR region='x'  -> NOT a single-col IN; conservative OTHER
    # constraint (the fold keeps the file) AND kept on the residual.
    var filter = _or(
        _eq(_col(String("dt")), _lit_str(String("a"))),
        _eq(_col(String("region")), _lit_str(String("x"))),
    )
    var split = split_partition_predicate(filter^, _part_cols(), _part_types())
    assert_equal(split.partition_predicate.num_constraints(), 1)
    ref c = split.partition_predicate.constraints[0]
    assert_equal(c.op, _OP_OTHER)  # cannot enumerate -> opaque fold constraint
    # conservative: the conjunct stays on the residual too.
    assert_true(Bool(split.residual))
    assert_true(should_use_pruned_discovery(split))


def test_col_on_both_sides_is_conservative() raises:
    # WHERE dt > region  (two partition cols, no literal) -> conservative OTHER.
    var filter = _gt(_col(String("dt")), _col(String("region")))
    var split = split_partition_predicate(filter^, _part_cols(), _part_types())
    assert_equal(split.partition_predicate.num_constraints(), 1)
    ref c = split.partition_predicate.constraints[0]
    assert_equal(c.op, _OP_OTHER)
    assert_true(Bool(split.residual))


def test_two_data_conjuncts_no_pruning() raises:
    # WHERE amount > 100 AND qty < 5  -> both DATA cols; EMPTY partition pred;
    # residual = the whole AND; EagerGlobDiscovery routing.
    var filter = _and(
        _gt(_col(String("amount")), _lit_int(100)),
        _lt(_col(String("qty")), _lit_int(5)),
    )
    var split = split_partition_predicate(filter^, _part_cols(), _part_types())
    assert_equal(split.partition_predicate.num_constraints(), 0)
    assert_true(Bool(split.residual))
    assert_false(should_use_pruned_discovery(split))


def test_two_partition_eqs_both_tier1() raises:
    # WHERE dt='2026-11-04' AND region='us-west'  -> TWO Tier-1 constraints,
    # NO residual (both partition cols, fully consumed).
    var filter = _and(
        _eq(_col(String("dt")), _lit_str(String("2026-11-04"))),
        _eq(_col(String("region")), _lit_str(String("us-west"))),
    )
    var split = split_partition_predicate(filter^, _part_cols(), _part_types())
    assert_equal(split.partition_predicate.num_constraints(), 2)
    assert_false(Bool(split.residual))
    assert_true(should_use_pruned_discovery(split))


def test_int_literal_renders_decimal() raises:
    # An INT64 partition col EQ: the constraint value is the decimal text
    # (`2020`), the form the fold compares numerically.
    var filter = _eq(_col(String("yr")), _lit_int(2020))
    var split = split_partition_predicate(filter^, _yr_cols(), _yr_types())
    assert_equal(split.partition_predicate.num_constraints(), 1)
    ref c = split.partition_predicate.constraints[0]
    assert_equal(c.col, String("yr"))
    assert_equal(c.op, _OP_EQ)
    assert_equal(c.values[0], String("2020"))
    assert_true(c.arrow_type == ArrowType.INT64)


def main() raises:
    var suite = TestSuite()
    suite.test[test_eq_on_partition_col_is_tier1]()
    suite.test[test_range_on_data_col_is_tier2]()
    suite.test[test_mixed_partition_and_data_splits_both]()
    suite.test[test_range_on_partition_col_is_tier1_fold]()
    suite.test[test_literal_on_left_flips_op]()
    suite.test[test_in_list_on_partition_col_reconstructs]()
    suite.test[test_or_across_two_partition_cols_is_conservative]()
    suite.test[test_col_on_both_sides_is_conservative]()
    suite.test[test_two_data_conjuncts_no_pruning]()
    suite.test[test_two_partition_eqs_both_tier1]()
    suite.test[test_int_literal_renders_decimal]()
    suite^.run()
