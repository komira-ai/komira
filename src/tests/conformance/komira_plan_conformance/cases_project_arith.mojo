# =============================================================================
# komira_plan_conformance/cases_project_arith.mojo -- shard project_arith.
# =============================================================================
#
# Arithmetic in a projection, citing query semantics §4.8, §5.0 to §5.3,
# §5.5 to §5.7, §8.9, §8.10 and §8.19. A NULL operand gives NULL before the
# zero-divisor rule is consulted (§5.0). Three datasets:
#   int_pairs    x, y = (1, 10), (NULL, 20), (3, NULL), (NULL, NULL), (5, 5):
#                integer + - * with each operand NULL alone and both NULL.
#   div_pairs    a / b and a % b for every sign pair of 7 and 2, four zero
#                divisors (one under a NULL a), 6 / 3, a NULL b, 0 / 5 and
#                -1 / 5, where truncating and flooring differ.
#   float_pairs  p / q giving +inf, -inf and NaN (§5.6), then NaN and inf
#                carried through + - * (§5.7); JSON cannot spell NaN or
#                infinity, so they are produced by a division the document
#                settles.
# Every expectation is HAND, its derivation in the .tsv. A PROJECT root is
# not a SORT, so every case compares its rows as a multiset (§4.8).
#
# Types. Both operands of every operator have one type, INT64 or FLOAT64,
# and a literal operand is declared with that type (§8.19). §8.9 (the type
# of mixed arithmetic) is UNDECIDED, but each of its options gives INT64 for
# INT64 with INT64 and FLOAT64 for FLOAT64 with FLOAT64: option (a)'s table
# answers the narrowest type both convert to without loss, and option (b)
# requires same-typed operands, which these are. BIN_DIV of two integers is
# the integer type (§5.1, §8.10: DEPARTS, pending ruling (recommended:
# accept)). Every arithmetic result is nullable by §8's default.
#
# The plan's BIN_DIV on integers is DuckDB's `//` (§5.1, DEPARTS, pending
# ruling (recommended: accept)): it truncates. The other rules here are
# MATCHES.
#
# Not here, and why:
#   - mixed-type operands (INT64 with FLOAT64, a narrower integer): their
#     result type is §8.9, UNDECIDED.
#   - overflow (§5.5) and MIN / -1 (§5.4): each is an error, and an ERROR
#     case needs the engine's error code and kind, which no executor fixes
#     yet; MIN % -1 (§5.8) is inferred, not measured, in the document.
#   - float modulo (§5.9) and DECIMAL arithmetic (§5.10, §8.11 to §8.13):
#     outside this shard's brief.
#   - NaN or infinity as an input: JSON cannot carry them.
#
# The defect each case would catch once it executes:
#   int_add_sub_mul_nulls     a NULL operand read as 0 (id 2's x + y as 20);
#                             no value is near overflow (§5.5)
#   int_div_trunc             flooring division (-7 / 2 as -4, -1 / 5 as -1),
#                             true division (7 / 2 as 3.5), a zero divisor
#                             raising or answering 0
#   int_mod_sign              a floored modulo (-7 % 2 as 1, -1 % 5 as 4); a
#                             remainder taking the divisor's sign (7 % -2 as
#                             -1); a zero divisor raising or answering a
#   int_div_mod_identity      a division and a modulo that disagree on the
#                             rounding, so (a / b) * b + a % b is not a
#   int_div_mod_literal_zero  a literal zero divisor folded to an error or
#                             0; the result declared non-nullable over the
#                             non-nullable id
#   float_div_zero            x / 0.0 answered NULL or raising; the sign of
#                             -0.0 ignored (2.0 / -0.0 as +inf); 0.0 / 0.0
#                             as 0 or NULL
#   float_nan_inf_propagation inf - inf or 0 * inf as 0; inf + 1 changed;
#                             NaN + NULL answering NaN (§5.7: NULL dominates)
# =============================================================================

from komira_plan_expr.expr import BIN_ADD, BIN_DIV, BIN_MOD, BIN_MUL, BIN_SUB, Expr
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_harness import CanonPolicy
from komira_plan_ir.logical_plan import ExprArray, LogicalPlan

from .plan_case import Case
from .datasets import div_pairs, float_pairs, int_pairs, scan

comptime SHARD = "project_arith"


def _col(name: String) -> Expr:
    return Expr.col_ref(name)


def _as(var e: Expr, name: String) -> Expr:
    return Expr.alias(e^, name)


def _bin(op: UInt8, var l: Expr, var r: Expr) -> Expr:
    return Expr.binary(op, l^, r^)


def _i64(v: Int) -> Expr:
    return Expr.literal(ScalarValue.from_int64(Int64(v)))


def _f64(v: Float64) -> Expr:
    return Expr.literal(ScalarValue.from_float(v))


# --- integers -----------------------------------------------------------------


def _int_add_sub_mul_nulls() raises -> LogicalPlan:
    """x + y, x - y, x * y over int_pairs."""
    var e = ExprArray()
    e.append(_col("id"))
    e.append(_as(_bin(BIN_ADD, _col("x"), _col("y")), "sum_xy"))
    e.append(_as(_bin(BIN_SUB, _col("x"), _col("y")), "diff_xy"))
    e.append(_as(_bin(BIN_MUL, _col("x"), _col("y")), "prod_xy"))
    return LogicalPlan.project(e^, scan(int_pairs()))


def _int_div_trunc() raises -> LogicalPlan:
    var e = ExprArray()
    e.append(_col("id"))
    e.append(_as(_bin(BIN_DIV, _col("a"), _col("b")), "q"))
    return LogicalPlan.project(e^, scan(div_pairs()))


def _int_mod_sign() raises -> LogicalPlan:
    var e = ExprArray()
    e.append(_col("id"))
    e.append(_as(_bin(BIN_MOD, _col("a"), _col("b")), "m"))
    return LogicalPlan.project(e^, scan(div_pairs()))


def _int_div_mod_identity() raises -> LogicalPlan:
    """(a / b) * b + a % b, which §5.2 says equals a."""
    var q_times_b = _bin(BIN_MUL, _bin(BIN_DIV, _col("a"), _col("b")), _col("b"))
    var e = ExprArray()
    e.append(_col("id"))
    e.append(_col("a"))
    e.append(_as(_bin(BIN_ADD, q_times_b^, _bin(BIN_MOD, _col("a"), _col("b"))), "back"))
    return LogicalPlan.project(e^, scan(div_pairs()))


def _int_div_mod_literal_zero() raises -> LogicalPlan:
    """a / 0, a % 0, id / 0, id % 0 with an INT64 literal 0; id is
    non-nullable."""
    var e = ExprArray()
    e.append(_col("id"))
    e.append(_as(_bin(BIN_DIV, _col("a"), _i64(0)), "a_div_0"))
    e.append(_as(_bin(BIN_MOD, _col("a"), _i64(0)), "a_mod_0"))
    e.append(_as(_bin(BIN_DIV, _col("id"), _i64(0)), "id_div_0"))
    e.append(_as(_bin(BIN_MOD, _col("id"), _i64(0)), "id_mod_0"))
    return LogicalPlan.project(e^, scan(div_pairs()))


# --- floats -------------------------------------------------------------------


def _p_over_q() -> Expr:
    return _bin(BIN_DIV, _col("p"), _col("q"))


def _float_div_zero() raises -> LogicalPlan:
    var e = ExprArray()
    e.append(_col("id"))
    e.append(_as(_p_over_q(), "d"))
    return LogicalPlan.project(e^, scan(float_pairs()))


def _float_nan_inf_propagation() raises -> LogicalPlan:
    """With d = p / q: d + 1.0, d - d, d * 0.0, d + r."""
    var e = ExprArray()
    e.append(_col("id"))
    e.append(_as(_bin(BIN_ADD, _p_over_q(), _f64(1.0)), "plus_one"))
    e.append(_as(_bin(BIN_SUB, _p_over_q(), _p_over_q()), "minus_self"))
    e.append(_as(_bin(BIN_MUL, _p_over_q(), _f64(0.0)), "times_zero"))
    e.append(_as(_bin(BIN_ADD, _p_over_q(), _col("r")), "plus_r"))
    return LogicalPlan.project(e^, scan(float_pairs()))


def cases() -> List[Case]:
    return [
        Case.hand("int_add_sub_mul_nulls", SHARD, _int_add_sub_mul_nulls, CanonPolicy.unordered()),
        Case.hand("int_div_trunc", SHARD, _int_div_trunc, CanonPolicy.unordered()),
        Case.hand("int_mod_sign", SHARD, _int_mod_sign, CanonPolicy.unordered()),
        Case.hand("int_div_mod_identity", SHARD, _int_div_mod_identity, CanonPolicy.unordered()),
        Case.hand("int_div_mod_literal_zero", SHARD, _int_div_mod_literal_zero, CanonPolicy.unordered()),
        Case.hand("float_div_zero", SHARD, _float_div_zero, CanonPolicy.unordered()),
        Case.hand("float_nan_inf_propagation", SHARD, _float_nan_inf_propagation, CanonPolicy.unordered()),
    ]
