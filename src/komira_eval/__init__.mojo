"""The expression and aggregate evaluation layer.

Re-exports the `komira_core.eval` kernel surface alongside the traits, UDF
surfaces and runtime-expression helpers defined in this package.
"""

from komira_core.eval import (
    eval_gt,
    eval_lt,
    eval_eq,
    eval_ne,
    eval_le,
    eval_ge,
    eval_col_gt,
    eval_col_lt,
    eval_col_eq,
    eval_col_ne,
    eval_col_le,
    eval_col_ge,
    filter_to_indices,
    eval_string_eq,
    eval_string_ne,
    eval_string_gt,
    eval_string_lt,
    eval_string_ge,
    eval_string_le,
    eval_string_contains,
    eval_string_starts_with,
    eval_string_ends_with,
    eval_string_like,
    eval_add,
    eval_sub,
    eval_mul,
    eval_div,
    eval_add_scalar,
    eval_mul_scalar,
    eval_and,
    eval_or,
    eval_not,
    filtered_sum,
    eval_revenue_sum,
    eval_filtered_revenue_sum,
    eval_cast,
    eval_cast_float_to_int,
    round_half_to_even,
    bitmap_and,
    eval_gt_nullable,
    eval_is_null,
    eval_is_not_null,
    SelectionVector,
    DictFilterOp,
    dict_filter_eval,
    dict_filter_eval_bool_mask,
    selective_decode_fixed,
    selective_decode_string,
    selective_decode_boolean,
    gather_strings,
    eval_eq_interval_mdn,
    eval_eq_interval_mdn_scalar,
    hash_interval_mdn,
    hash_one_interval_mdn,
    take_interval_mdn,
    filter_interval_mdn,
    lex_lt_interval_mdn,
    lex_lt_one_interval_mdn,
    add_interval_mdn,
    sub_interval_mdn,
    _scalar_add_interval_mdn,
    _scalar_sub_interval_mdn,
)

# Marker trait for UDF row structs.
from komira_eval.auto_komira_schema import AutoKomiraSchema

# User-facing trait for SIMD scalar UDFs.
from komira_eval.expr_scalar_fn import ExprScalarFn

from komira_eval.kleene import (
    _kleene_and_chunk,
    _kleene_or_chunk,
    _kleene_not_chunk,
    _kleene_and_byte,
    _kleene_or_byte,
    _kleene_not_byte,
    _cmp_result_validity_byte,
    _cmp_result_validity_chunk,
)
from komira_core.eval import (
    eval_col_gt_kleene,
    eval_col_lt_kleene,
    eval_col_eq_kleene,
)

# Trait surface declarations and the typed chunk wrapper family.
from komira_eval.eval_chunks import (
    EvalBoolChunk,
    EvalI64Chunk,
    EvalI32Chunk,
    EvalF64Chunk,
    EvalF32Chunk,
    EvalDecimal128Chunk,
    EvalDecimal256Chunk,
)
from komira_eval.expr_traits_unified import (
    ExprBoolU,
    ExprI64U,
    ExprI32U,
    ExprF64U,
    ExprF32U,
    ExprDecimal128U,
    ExprDecimal256U,
    AggI64U,
    AggF64U,
    I64Accumulator,
    F64Accumulator,
    _default_run_filter_self_unified,
    _default_eval_column_i64,
)

# Runtime name -> physical-column-index resolver, built from a file
# footer Schema and consulted at bind time by typed-expression leaves to
# populate their cached column index.
from komira_eval.column_resolver import ColumnResolver

# The public FNV-1a-64 byte-span hash. The search inverted-index term
# directory keys on it; re-exported so `from komira_eval import
# fnv1a_64_over_bytes` resolves at the facade.
from komira_eval.builtin_string_hash_fns import fnv1a_64_over_bytes

from komira_eval.runtime_expr_bool import (
    RuntimeExprBool,
    RuntimeNode,
    ShapeClass,
    MAX_NODES,
    SHAPE_FALLBACK,
    SHAPE_AND_GT_LT_LIT,
    RT_LIT_BOOL,
    RT_LIT_INT,
    RT_LIT_FLOAT,
    RT_LIT_STR,
    RT_COL_REF,
    RT_COMPARISON,
    RT_AND,
    RT_OR,
    RT_NOT,
    RT_IS_NULL,
    RT_BETWEEN,
    RT_IN_LIST,
    RT_BIN_OP,
    RT_EXPR_AGG_FN,
    RT_EXPR_WHEN,
    RT_EXPR_CAST,
    CMP_LT,
    CMP_LE,
    CMP_GT,
    CMP_GE,
    CMP_EQ,
    CMP_NE,
    ISNULL_IS_NULL,
    ISNULL_IS_NOT_NULL,
    rt_lit_bool,
    rt_lit_int,
    rt_lit_float,
    rt_lit_str,
    rt_col_ref,
    rt_comparison,
    rt_and,
    rt_or,
    rt_not,
    rt_is_null,
    rt_between,
    rt_in_list,
    rt_bin_op,
    rt_expr_agg_fn,
    rt_expr_when,
    rt_expr_cast,
    build_runtime_expr_bool,
)
