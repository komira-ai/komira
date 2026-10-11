# =============================================================================
# pplan_wire_equal.mojo — FIELD-FOR-FIELD equality for a physical collect plan.
# =============================================================================
#
# ⚠ THIS FILE IS THE REASON THE ROUND-TRIP TEST MEANS ANYTHING.
#
# "It decoded" is not a round-trip result. A codec that drops `projection` still
# decodes, still returns a `ParquetSourceData`, and still passes any test that
# asserts the decode did not raise. The assertion has to be that EVERY FIELD ON
# BOTH SIDES IS THE SAME VALUE, and that is what lives here.
#
# ⛔ AND IT MUST FAIL LOUD RATHER THAN RETURN False ON A SHAPE IT CANNOT
# COMPARE. A comparator that returns False for "I don't know" makes a passing
# test impossible to distinguish from a broken one; a comparator that returns
# True for "I don't know" is worse. Every arm here either compares or raises.
#
# The comparison is on the DECODED STRUCTS, deliberately, not on the bytes.
# Comparing `encode(decode(b)) == b` would pass for a codec that is
# self-consistently wrong about a field — it would drop the same field on both
# sides. Comparing the structs asks the question that matters: is the plan the
# decoder is about to hand back the plan that was encoded?
# =============================================================================

from komira_plan_expr.expr import Expr
from komira_plan_expr.scalar_value import ScalarValue
from komira_physical_plan.physical_plan import (
    ParquetSourceData,
    MorselOp,
    OP_FILTER,
    OP_PROJECT,
    OP_LIMIT,
)
from komira_collections.slab import Slab
from std.memory import bitcast


comptime PPLAN_EQ_UNCOMPARABLE_EXPR: String = "PPLAN_EQ_UNCOMPARABLE_EXPR"
comptime PPLAN_EQ_UNCOMPARABLE_OP: String = "PPLAN_EQ_UNCOMPARABLE_OP"


def scalars_equal(a: ScalarValue, b: ScalarValue) -> Bool:
    """Every one of the 19 fields. No kind-dependent shortcut: a field that is
    "not meaningful for this kind" is still a field the codec either carried or
    lost, and a comparator that skips it cannot see the loss."""
    if a.dtype != b.dtype:
        return False
    if a.int_val != b.int_val:
        return False
    # Bit-exact float compare — `!=` would call two NaNs different and two
    # signed zeros equal, and both of those are round-trip questions.
    if bitcast[DType.uint64](a.float_val) != bitcast[DType.uint64](b.float_val):
        return False
    if a.string_val != b.string_val:
        return False
    if a.bool_val != b.bool_val:
        return False
    if a._kind != b._kind:
        return False
    if a.dec128_high != b.dec128_high or a.dec128_low != b.dec128_low:
        return False
    if a.dec128_precision != b.dec128_precision:
        return False
    if a.dec128_scale != b.dec128_scale:
        return False
    if a.date32_val != b.date32_val:
        return False
    if a.ts_micros != b.ts_micros:
        return False
    if a.null_dtype != b.null_dtype:
        return False
    if a.iv_months != b.iv_months or a.iv_days != b.iv_days:
        return False
    if a.iv_nanos != b.iv_nanos:
        return False
    if a.time_unit != b.time_unit:
        return False
    if a.dec256_high_lo != b.dec256_high_lo:
        return False
    if a.dec256_high_hi != b.dec256_high_hi:
        return False
    return True


def exprs_equal(a: Expr, b: Expr) raises -> Bool:
    """Structural equality over the five modelled Expr tags. RAISES on a tag
    pair it cannot compare rather than guessing an answer."""
    if a.tag != b.tag:
        return False
    if a.is_col_ref():
        return a.col_ref_name() == b.col_ref_name() and a.col_ref_side() == b.col_ref_side()
    elif a.is_literal():
        return scalars_equal(a.literal_value(), b.literal_value())
    elif a.is_binary():
        if a.binary_op() != b.binary_op():
            return False
        if not exprs_equal(a.binary_left_ref(), b.binary_left_ref()):
            return False
        return exprs_equal(a.binary_right_ref(), b.binary_right_ref())
    elif a.is_unary():
        if a.unary_op() != b.unary_op():
            return False
        return exprs_equal(a.unary_child_ref(), b.unary_child_ref())
    elif a.is_alias():
        if a.alias_name() != b.alias_name():
            return False
        return exprs_equal(a.alias_child_ref(), b.alias_child_ref())
    raise Error(PPLAN_EQ_UNCOMPARABLE_EXPR, ": tag ", Int(a.tag))


def _opt_exprs_equal(a: Optional[Expr], b: Optional[Expr]) raises -> Bool:
    if not a and not b:
        return True
    if not a or not b:
        return False
    return exprs_equal(a.value(), b.value())


def _opt_strs_equal(a: Optional[List[String]], b: Optional[List[String]]) -> Bool:
    if not a and not b:
        return True
    if not a or not b:
        return False
    return _strs_equal(a.value(), b.value())


def _strs_equal(a: List[String], b: List[String]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


def ops_equal(a: MorselOp, b: MorselOp) raises -> Bool:
    if a.tag != b.tag:
        return False
    if a.tag == OP_FILTER:
        return _opt_exprs_equal(a.filter_predicate, b.filter_predicate)
    elif a.tag == OP_PROJECT:
        if not a.project_exprs or not b.project_exprs:
            return False
        ref ae = a.project_exprs.value()
        ref be = b.project_exprs.value()
        if len(ae) != len(be):
            return False
        for i in range(len(ae)):
            if not exprs_equal(ae[i], be[i]):
                return False
        if not _opt_strs_equal(a.project_names, b.project_names):
            return False
        return a.project_reorders_only == b.project_reorders_only
    elif a.tag == OP_LIMIT:
        return a.limit_count == b.limit_count
    raise Error(PPLAN_EQ_UNCOMPARABLE_OP, ": tag ", Int(a.tag))


def pq_data_equal(a: ParquetSourceData, b: ParquetSourceData) raises -> Bool:
    """All 10 fields of `ParquetSourceData`. The two the codec REFUSES
    (`hive_partition_cols`, `hive_predicate`) are compared too — a refusal that
    silently became an empty list on the way back would show up right here."""
    if a.file_path != b.file_path:
        return False
    if not _opt_strs_equal(a.projection, b.projection):
        return False
    if not _opt_exprs_equal(a.pushed_filter, b.pushed_filter):
        return False
    if len(a.hive_partition_cols) != len(b.hive_partition_cols):
        return False
    for i in range(len(a.hive_partition_cols)):
        if a.hive_partition_cols[i].name != b.hive_partition_cols[i].name:
            return False
    if Bool(a.hive_predicate) != Bool(b.hive_predicate):
        return False
    if a.fs_descriptor.scheme != b.fs_descriptor.scheme:
        return False
    if a.fs_descriptor.bucket != b.fs_descriptor.bucket:
        return False
    if a.fs_descriptor.node_id != b.fs_descriptor.node_id:
        return False
    if a.preserve_numeric_dict != b.preserve_numeric_dict:
        return False
    if not _strs_equal(a.explicit_paths, b.explicit_paths):
        return False
    if Bool(a.row_window) != Bool(b.row_window):
        return False
    if a.row_window and b.row_window:
        if a.row_window.value().offset != b.row_window.value().offset:
            return False
        if a.row_window.value().length != b.row_window.value().length:
            return False
    if a.preserve_string_dict != b.preserve_string_dict:
        return False
    return True


def pplan_fields_equal(
    a_pq: ParquetSourceData, a_ops: Slab[MorselOp],
    b_pq: ParquetSourceData, b_ops: Slab[MorselOp],
) raises -> Bool:
    """THE assertion the round-trip test makes."""
    if not pq_data_equal(a_pq, b_pq):
        return False
    if len(a_ops) != len(b_ops):
        return False
    for i in range(len(a_ops)):
        if not ops_equal(a_ops[i], b_ops[i]):
            return False
    return True
