# =============================================================================
# compute_project_routes.mojo: which evaluator serves each project output
# =============================================================================
#
# The predicates `compute_project.eval_project_exprs_over_batch` routes each
# output expression by, and the column maps it hands the translator. Every
# function here reads an `Expr` or a batch schema and decides nothing about a
# value.
#
# The evaluator has three routes:
#   * a pure column reference is copied (`_passthrough_col_index`, with the
#     storage checks `_passthrough_storage_compatible` and
#     `_varlen_offset_width_alias`);
#   * a family the per-DType walkers cannot build goes to the column
#     evaluator `komira_batch_eval._eval_column_expr` (or `_eval_when_expr`
#     for CASE): the `_is_*_output` predicates, `expr_carries_udf_call`, and
#     the strict-arithmetic arm (`_expr_is_strict_null_propagating`,
#     `_strict_overlay_input_scan`, `_expr_has_domain_checked_math`);
#   * everything else is translated (`lower_untyped_expr`) and evaluated by
#     the per-DType `ExpressionExecutor` walkers.
#
# The `_is_*_output` predicates match their tag at the top of the expression
# or under any number of aliases (an alias is a name, so two aliases route
# the same as one), and under no other node: `abs(x) + 1` is not matched and
# goes to the walkers, which decline it. Nesting the other way
# (`abs(trunc(x))`) is matched, and the column evaluator recurses.
# =============================================================================

from std.collections import Optional, Dict

from komira_arrow.arrow_types import ArrowType
from komira_arrow.record_batch import RecordBatch
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_expr.expr import (
    Expr,
    EXPR_COL_REF,
    EXPR_ALIAS,
    EXPR_WHEN,
    EXPR_REGEXP,
    EXPR_SUBSTRING,
    EXPR_STRING_FN,
    EXPR_STRING_FN_N,
    EXPR_EXTRACT,
    EXPR_UNARY_OP,
    EXPR_COL_IDX,
    EXPR_LITERAL,
    EXPR_BINARY_OP,
    EXPR_MATH_FN,
    EXPR_MATH_FN2,
    EXPR_CAST,
    EXPR_STRUCT_FIELD,
    EXPR_STRUCT_FIELD_IDX,
    EXPR_MAP_GET,
    EXPR_JSON_EXTRACT,
    BIN_ADD,
    BIN_SUB,
    BIN_MUL,
    BIN_DIV,
    UN_ABS,
    UN_SIGN,
    UN_TRUNC,
    UN_ROUND,
    UN_BIT_COUNT,
    UN_IS_NULL,
    UN_IS_NOT_NULL,
    # The nine unary math ops whose kernel can refuse an argument
    # (`_expr_has_domain_checked_math`).
    MATH_ACOS,
    MATH_ASIN,
    MATH_ATANH,
    MATH_COT,
    MATH_GAMMA,
    MATH_LN,
    MATH_LOG10,
    MATH_LOG2,
    MATH_SQRT,
)

from .lower_untyped_expr import (
    RUNTIME_DTYPE_F64,
    RUNTIME_DTYPE_I32,
    RUNTIME_DTYPE_I64,
    RUNTIME_DTYPE_UNSUPPORTED,
)


def _arrow_to_runtime_dtype_local(at: ArrowType) -> Int:
    """The `RUNTIME_DTYPE_*` family of a column of type `at`, for the
    translator's `col_name_to_dtype`: INT64, DATE32 and the TIMESTAMP types
    read on the I64 channel, INT32 on the I32 channel, FLOAT64 and FLOAT32 on
    the F64 channel. Every other type is UNSUPPORTED (a computed expression
    over it is declined).

    The walker's column leaf reads the column's own type, so mixed I64 and
    F64 arithmetic widens to F64 at `_infer_runtime_dtype`."""
    if at == ArrowType.INT64:
        return RUNTIME_DTYPE_I64
    if at == ArrowType.INT32:
        return RUNTIME_DTYPE_I32
    if at == ArrowType.FLOAT64 or at == ArrowType.FLOAT32:
        return RUNTIME_DTYPE_F64
    if at == ArrowType.DATE32:
        return RUNTIME_DTYPE_I64
    if (
        at == ArrowType.TIMESTAMP
        or at == ArrowType.TIMESTAMP_S
        or at == ArrowType.TIMESTAMP_MS
        or at == ArrowType.TIMESTAMP_US
        or at == ArrowType.TIMESTAMP_NS
    ):
        return RUNTIME_DTYPE_I64
    return RUNTIME_DTYPE_UNSUPPORTED


def _is_int32_storage(at: ArrowType) -> Bool:
    """True iff a column of type `at` is stored as 4-byte signed integers:
    INT32, or DATE32, which a decoder may hand over as an INT32 column."""
    return at == ArrowType.INT32 or at == ArrowType.DATE32


def _is_int64_storage(at: ArrowType) -> Bool:
    """True iff a column of type `at` is stored as 8-byte signed integers:
    INT64, or DATE64 and the TIMESTAMP types, which a decoder may hand over as
    an INT64 column."""
    return (
        at == ArrowType.INT64
        or at == ArrowType.DATE64
        or at == ArrowType.TIMESTAMP
        or at == ArrowType.TIMESTAMP_S
        or at == ArrowType.TIMESTAMP_MS
        or at == ArrowType.TIMESTAMP_US
        or at == ArrowType.TIMESTAMP_NS
    )


def _varlen_offset_width_alias(a: ArrowType, b: ArrowType) -> Bool:
    """True iff `a` and `b` are the same variable-length type at the two
    offset widths: (STRING, LARGE_STRING) or (BINARY, LARGE_BINARY), either
    way round.

    This is a separate predicate from `_passthrough_storage_compatible`
    because the buffers differ (8-byte offsets against 4-byte ones) while the
    values are the same. The pair arises when an aggregate's group-key drain
    widens a string column past the int32 offset limit
    (`Column.from_strings_with_validity_promoting`) under a projection that
    declared `string` before any data existed.

    Admitting the pair is sound only because the passthrough arm emits the
    SOURCE column's type (`src_at`) in the output field, so the field states
    the offset width the column has. If that arm ever stamps the declared
    type instead, this predicate has to go with it: a reader told 32-bit
    offsets over a 64-bit buffer reads wrong values with a right row count.
    """
    if a == ArrowType.STRING and b == ArrowType.LARGE_STRING:
        return True
    if a == ArrowType.LARGE_STRING and b == ArrowType.STRING:
        return True
    if a == ArrowType.BINARY and b == ArrowType.LARGE_BINARY:
        return True
    if a == ArrowType.LARGE_BINARY and b == ArrowType.BINARY:
        return True
    return False


def _passthrough_storage_compatible(a: ArrowType, b: ArrowType) -> Bool:
    """True iff a column of type `a` can be copied out where the plan declares
    type `b`: the two types share one physical storage.

    A decoder may hand a temporal column over as its storage integer column
    (DATE32 as INT32; DATE64 and TIMESTAMP as INT64) while the plan keeps the
    temporal type, so those pairs are compatible. A width or kind divergence
    (INT32 against INT64, an integer against a float) is not."""
    if a == b:
        return True
    if _is_int32_storage(a) and _is_int32_storage(b):
        return True
    if _is_int64_storage(a) and _is_int64_storage(b):
        return True
    return False


def _build_col_maps(
    imm batch: RecordBatch,
    mut name_to_idx: Dict[String, Int],
    mut name_to_dtype: Dict[String, Int],
) -> Bool:
    """Fill `name_to_idx` (column name -> position in `batch`) and
    `name_to_dtype` (column name -> `RUNTIME_DTYPE_*` family) from `batch`'s
    schema, for the translator.

    A column of an unsupported type is entered with RUNTIME_DTYPE_UNSUPPORTED:
    the translator then declines an expression that computes over it, and a
    pure reference to it is served by the passthrough copy, which does not
    read these maps. Returns True."""
    var n = batch.schema.num_columns()
    for i in range(n):
        var nm = batch.schema.field_name(i)
        var at = batch.schema.field_arrow_type(i)
        var rt = _arrow_to_runtime_dtype_local(at)
        name_to_idx[nm] = i
        name_to_dtype[nm] = rt
    return True


def _passthrough_col_index(imm batch: RecordBatch, imm e: Expr) raises -> Int:
    """The position in `batch` of the column `e` names when `e` is a column
    reference under any number of aliases (none included); -1 when `e` is
    anything else or the column is absent.

    Every alias level is unwrapped: an aliased column is the column, so it
    is copied with its validity. A column left to the walkers would lose its
    NULLs, since they read values only."""
    if e.tag == EXPR_ALIAS:
        return _passthrough_col_index(batch, e.alias_child_ref())
    if e.tag != EXPR_COL_REF:
        return -1
    var name = e._col_ref.value().name
    var n = batch.schema.num_columns()
    for i in range(n):
        if batch.schema.field_name(i) == name:
            return i
    return -1


def _when_expr_ref(imm e: Expr) -> Optional[Int]:
    """`Some(0)` when `e` is a CASE (`EXPR_WHEN`) under any number of aliases
    (none included), None otherwise. The caller unwraps the aliases itself
    (`compute_project._eval_when_under_aliases`)."""
    if e.tag == EXPR_WHEN:
        return Optional[Int](0)
    if e.tag == EXPR_ALIAS:
        return _when_expr_ref(e.alias_child_ref())
    return None


def is_literal_output_expr(imm e: Expr) -> Bool:
    """True iff the output expression `e` is a literal (`EXPR_LITERAL`) under
    any number of aliases (none included).

    Public so that every caller asking "is this projected output a
    constant?" asks it the same way: a binder names each projected literal
    (`Expr.alias(<literal>, <name>)`), so a bare tag test misses it.

    The evaluator serves such an output by broadcasting the value
    (`broadcast_scalar`) and checking the column against the declared type,
    which covers STRING, BOOL, DATE32, INT32 and FLOAT32 literals; the
    walker channels the evaluator serves are I64 and F64 only, and they widen
    every narrow literal. A literal inside a larger expression (`1 + col`) is not matched
    and keeps the walker route."""
    if e.tag == EXPR_LITERAL:
        return True
    if e.tag == EXPR_ALIAS:
        return is_literal_output_expr(e.alias_child_ref())
    return False


def _literal_under_aliases(imm e: Expr) raises -> ScalarValue:
    """The value of the literal `e` is, under any number of aliases. Requires
    `is_literal_output_expr(e)`; raises on any other shape."""
    if e.tag == EXPR_LITERAL:
        return e.literal_value()
    if e.tag == EXPR_ALIAS:
        return _literal_under_aliases(e.alias_child_ref())
    raise Error("_literal_under_aliases: the expression is not a literal")


def _is_regexp_output(imm e: Expr) -> Bool:
    """True iff `e` is an `EXPR_REGEXP` under any number of aliases. The
    walkers have no regexp node; the column evaluator serves both the BOOL
    `regexp_like` and the STRING-valued forms."""
    if e.tag == EXPR_REGEXP:
        return True
    if e.tag == EXPR_ALIAS:
        return _is_regexp_output(e.alias_child_ref())
    return False


def _is_substring_output(imm e: Expr) -> Bool:
    """True iff `e` is an `EXPR_SUBSTRING` under any number of aliases: a
    string result, which the walkers cannot build."""
    if e.tag == EXPR_SUBSTRING:
        return True
    if e.tag == EXPR_ALIAS:
        return _is_substring_output(e.alias_child_ref())
    return False


def _is_string_fn_output(imm e: Expr) -> Bool:
    """True iff `e` is an `EXPR_STRING_FN` (`upper(s)`) or an
    `EXPR_STRING_FN_N` (`concat(a, b)` and the other variadic functions),
    under any number of aliases. One predicate for both tags: the
    evaluator's arm for them is the same, and it checks the result type per
    op against the declared type, so it does not assume STRING."""
    if e.tag == EXPR_STRING_FN or e.tag == EXPR_STRING_FN_N:
        return True
    if e.tag == EXPR_ALIAS:
        return _is_string_fn_output(e.alias_child_ref())
    return False


def _is_null_test_output(imm e: Expr) -> Bool:
    """True iff `e` is `x IS NULL` or `x IS NOT NULL` (the two BOOL-valued
    `EXPR_UNARY_OP` members), under any number of aliases.

    The translator's null tests take a STRING operand only; the column
    evaluator reads any column's validity bitmap, so these outputs go there
    whatever the operand's type."""
    if e.tag == EXPR_UNARY_OP:
        var op = e.unary_op()
        return op == UN_IS_NULL or op == UN_IS_NOT_NULL
    if e.tag == EXPR_ALIAS:
        return _is_null_test_output(e.alias_child_ref())
    return False


def _is_cast_output(imm e: Expr) -> Bool:
    """True iff `e` is an `EXPR_CAST` under any number of aliases.

    The walkers have only the widening I64 -> F64 cast; the column evaluator
    has the full cast ladder, including a cast to DECIMAL128, whose precision
    and scale the evaluator carries from the declared output field."""
    if e.tag == EXPR_CAST:
        return True
    if e.tag == EXPR_ALIAS:
        return _is_cast_output(e.alias_child_ref())
    return False


def _is_num_typepres_output(imm e: Expr) -> Bool:
    """True iff `e` is `abs`, `sign`, `trunc`, `round` or `bit_count` (the
    `EXPR_UNARY_OP` members the walkers have no node for), under any number
    of aliases.

    Not every unary op: negation has walker nodes and keeps that route, and
    NOT and the null tests are BOOL-valued. The result type varies per op and
    per operand (`bit_count` is INT8 whatever its operand), so the
    evaluator's declared-type check does real work for this family."""
    if e.tag == EXPR_UNARY_OP:
        var op = e.unary_op()
        return (
            op == UN_ABS or op == UN_SIGN or op == UN_TRUNC or op == UN_ROUND
            or op == UN_BIT_COUNT
        )
    if e.tag == EXPR_ALIAS:
        return _is_num_typepres_output(e.alias_child_ref())
    return False


# =============================================================================
# The strict-arithmetic arm: a NULL in the input
# =============================================================================
#
# The per-DType walkers drop validity: `eval_to_list_<dtype>_from_view`
# appends plain values, and the column is built with no validity bitmap, so a
# NULL input cell is read as its payload bytes and the result is valid. An
# aggregate that answers NULL (`var_samp` of one row) under `sqrt(...)` would
# then answer `sqrt` of the payload.
#
# The column evaluator propagates validity for exactly the strict shapes
# `_expr_is_strict_null_propagating` admits (arithmetic, unary and binary
# math, a FLOAT64 cast), so a strict expression over an input that HOLDS a
# NULL goes there. Over an input with no NULL the two evaluators compute the
# same IEEE-754 values, so the gate is the batch's `null_count()`, not the
# field's `nullable`, and a null-free batch keeps the walker route, except
# for the domain-checked math below.
#
# The predicate is an allowlist: the column evaluator raises on a tag it has
# no arm for, so a tag outside the list keeps the walker route. A comparison
# is not admitted (its BOOL result cannot ride the I64 / F64 channels),
# nor are CASE and the null tests, which are not strict.
#
# Domain-checked math. The column evaluator's unary math kernel refuses an
# argument SQL has no answer for (`ln(0)`, `sqrt(-1)`, `asin(2)`, `cot(0)`,
# `gamma(0)` and the rest), and the walkers do not check. So an expression
# holding one of the nine ops that can refuse takes the column route even
# over a null-free batch, and the refusal does not depend on whether another
# row is NULL. `acosh` and `gamma` at a negative argument answer NaN in
# DuckDB and are not refused; `gamma` is in the list for `gamma(0)` only.
# The list names ops only; the bound on a value is decided in the kernel.
# =============================================================================


def _expr_is_strict_null_propagating(imm e: Expr) -> Bool:
    """True iff `e` is built only from strict nodes (a NULL operand makes the
    result NULL) that the column evaluator evaluates with validity:
    EXPR_ALIAS, EXPR_COL_REF, EXPR_COL_IDX, EXPR_LITERAL, EXPR_BINARY_OP with
    one of the four arithmetic operators, EXPR_MATH_FN, EXPR_MATH_FN2, and
    EXPR_CAST to FLOAT64. Read-only."""
    if e.tag == EXPR_ALIAS:
        return _expr_is_strict_null_propagating(e.alias_child_ref())
    if e.tag == EXPR_COL_REF or e.tag == EXPR_COL_IDX or e.tag == EXPR_LITERAL:
        return True
    if e.tag == EXPR_MATH_FN:
        return _expr_is_strict_null_propagating(e.math_fn_child_ref())
    if e.tag == EXPR_MATH_FN2:
        if not _expr_is_strict_null_propagating(e.math_fn2_left_ref()):
            return False
        return _expr_is_strict_null_propagating(e.math_fn2_right_ref())
    if e.tag == EXPR_BINARY_OP:
        var op = e.binary_op()
        if not (op == BIN_ADD or op == BIN_SUB or op == BIN_MUL or op == BIN_DIV):
            return False
        if not _expr_is_strict_null_propagating(e.binary_left_ref()):
            return False
        return _expr_is_strict_null_propagating(e.binary_right_ref())
    if e.tag == EXPR_CAST:
        # A front end lowers integer `/` to `CAST(<left> AS DOUBLE) / <right>`.
        # The walker's I64 -> F64 node reads values only, so `sum(v) / 2` over
        # an all-NULL group would answer 0.0 where DuckDB answers NULL. Only
        # the FLOAT64 target is admitted: the column evaluator's cast keeps
        # validity for every operand type the input scan admits.
        if (
            e.cast_target() == DType.float64
            and e.cast_target_arrow() == ArrowType.FLOAT64
        ):
            return _expr_is_strict_null_propagating(e.cast_child_ref())
        return False
    return False


def _expr_has_domain_checked_math(imm e: Expr) -> Bool:
    """True iff `e` holds a unary math node whose op the kernel can refuse
    (LN, LOG10, LOG2, SQRT, ASIN, ACOS, ATANH, COT, GAMMA). Walks the shapes
    `_expr_is_strict_null_propagating` admits, and is consulted only after it
    said yes. Read-only."""
    if e.tag == EXPR_ALIAS:
        return _expr_has_domain_checked_math(e.alias_child_ref())
    if e.tag == EXPR_MATH_FN:
        var op = e.math_fn_op()
        if (
            op == MATH_LN
            or op == MATH_LOG10
            or op == MATH_LOG2
            or op == MATH_SQRT
            or op == MATH_ASIN
            or op == MATH_ACOS
            or op == MATH_ATANH
            or op == MATH_COT
            or op == MATH_GAMMA
        ):
            return True
        return _expr_has_domain_checked_math(e.math_fn_child_ref())
    if e.tag == EXPR_MATH_FN2:
        if _expr_has_domain_checked_math(e.math_fn2_left_ref()):
            return True
        return _expr_has_domain_checked_math(e.math_fn2_right_ref())
    if e.tag == EXPR_BINARY_OP:
        if _expr_has_domain_checked_math(e.binary_left_ref()):
            return True
        return _expr_has_domain_checked_math(e.binary_right_ref())
    return False


def _strict_overlay_input_scan(
    imm e: Expr, imm batch: RecordBatch, mut saw_null: Bool
) -> Bool:
    """One walk over `e`'s column leaves. Returns False as soon as a leaf is
    outside the strict arm's operand types, or names a column `batch` does
    not hold; sets `saw_null` when a leaf's column holds at least one NULL in
    this batch.

    The operand types are INT64 and FLOAT64. INT32 is left out because the
    column evaluator's column-column arithmetic has no INT32 arm and raises,
    and a raise here would propagate out of the projection rather than
    decline it. Reads names by a linear scan and does not raise."""
    if e.tag == EXPR_ALIAS:
        return _strict_overlay_input_scan(e.alias_child_ref(), batch, saw_null)
    if e.tag == EXPR_MATH_FN:
        return _strict_overlay_input_scan(e.math_fn_child_ref(), batch, saw_null)
    if e.tag == EXPR_MATH_FN2:
        if not _strict_overlay_input_scan(e.math_fn2_left_ref(), batch, saw_null):
            return False
        return _strict_overlay_input_scan(e.math_fn2_right_ref(), batch, saw_null)
    if e.tag == EXPR_BINARY_OP:
        if not _strict_overlay_input_scan(e.binary_left_ref(), batch, saw_null):
            return False
        return _strict_overlay_input_scan(e.binary_right_ref(), batch, saw_null)
    if e.tag == EXPR_CAST:
        return _strict_overlay_input_scan(e.cast_child_ref(), batch, saw_null)
    if e.tag == EXPR_LITERAL:
        return True
    var idx = -1
    if e.tag == EXPR_COL_IDX:
        var ix = e.col_idx_index()
        if ix >= 0 and ix < batch.schema.num_columns():
            idx = ix
    elif e.tag == EXPR_COL_REF:
        var nm = e._col_ref.value().name
        var n = batch.schema.num_columns()
        for i in range(n):
            if batch.schema.field_name(i) == nm:
                idx = i
                break
    else:
        return False
    if idx < 0:
        return False
    var at = batch.schema.field_arrow_type(idx)
    if at != ArrowType.INT64 and at != ArrowType.FLOAT64:
        return False
    if batch.column_at(idx).null_count() > 0:
        saw_null = True
    return True


def _is_nested_extract_output(imm e: Expr) -> Bool:
    """True iff `e` reads one value out of a nested or JSON cell
    (`EXPR_STRUCT_FIELD`, `EXPR_STRUCT_FIELD_IDX`, `EXPR_MAP_GET`,
    `EXPR_JSON_EXTRACT`), under any number of aliases.

    A nested extract inside a family that has its own arm
    (`upper(struct_extract(s, 'city'))`) is served through that family's
    arm, since the column evaluator recurses. One under a tag with no column
    arm (`struct_extract(s, 'city') = 'NYC'`) is not matched and is
    declined."""
    if (
        e.tag == EXPR_STRUCT_FIELD
        or e.tag == EXPR_STRUCT_FIELD_IDX
        or e.tag == EXPR_MAP_GET
        or e.tag == EXPR_JSON_EXTRACT
    ):
        return True
    if e.tag == EXPR_ALIAS:
        return _is_nested_extract_output(e.alias_child_ref())
    return False


def _is_extract_output(imm e: Expr) -> Bool:
    """True iff `e` is an `EXPR_EXTRACT` (`extract(<field> FROM x)`, `year(x)`,
    the `date_trunc(<unit>, x)` family) under any number of aliases.

    The walkers' extract node needs the operand's tick unit, and the
    translator's family map answers only "I64" for DATE32 and every TIMESTAMP
    unit. The column evaluator reads the temporal type off the batch schema,
    so the extract goes there. `year(d) + 1` is not matched and is
    declined."""
    if e.tag == EXPR_EXTRACT:
        return True
    if e.tag == EXPR_ALIAS:
        return _is_extract_output(e.alias_child_ref())
    return False
