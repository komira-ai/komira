# =============================================================================
# sql/sql_bind_union.mojo
#   DuckDB's common column types of a set operation's branches, and the
#   projection that conforms a branch to them.
# =============================================================================
#
# A set operation (`sql_bind_set_op`: UNION ALL, UNION, INTERSECT, EXCEPT) folds one
# common type per column over its inputs left to right (`_union_merge_schema`)
# and puts one projection on every input whose names or types differ from the
# result's (`_union_conform_branch`), so every child of a `PLAN_UNION` node
# advertises exactly the node's schema (`LogicalPlan.union` does not coerce).
# The casts and renames go into the branch's own SELECT-list projection, by
# position, when the branch ends in one. A pair of types this
# engine cannot cast between is refused by name.
#
# An INTEGER or BIGINT with a VARCHAR takes VARCHAR, as in DuckDB: the integer
# input is cast to its plain decimal spelling (the cast `CAST(x AS VARCHAR)`
# binds to), so 3 and '3' are one value of the result.
#
# Where DuckDB answers and this binder refuses, by name: UBIGINT with a signed
# integer (DuckDB's HUGEINT; Arrow has no 128-bit integer); a common decimal
# wider than 38 digits (DuckDB narrows the scale or keeps a type the values
# can overflow); BOOLEAN with a number, DATE with a timestamp, a string with
# any type but INTEGER and BIGINT, STRING with LARGE_STRING, and a timestamp
# with a zone or in nanoseconds against another unit (the projection's casts
# do not serve these pairs exactly). A column is nullable when any branch is; nullability alone
# never adds a projection, because the concatenation merges validity.

from arrow.arrow_types import ArrowType
from arrow.schema import Field, Schema, SchemaBuilder
from plan_expr.expr import Expr
from plan_ir.logical_plan import ExprArray, LogicalPlan, PLAN_PROJECT, PLAN_SCAN
from std.builtin.swap import swap


struct _Common(Copyable, Movable):
    """The common type of two column types: `at` (with `precision` / `scale`
    for a decimal), or `why` non-empty when there is none."""

    var at: ArrowType
    var precision: Int
    var scale: Int
    var why: String

    def __init__(
        out self,
        at: ArrowType,
        precision: Int = 0,
        scale: Int = 0,
        why: String = String(""),
    ):
        self.at = at
        self.precision = precision
        self.scale = scale
        self.why = why


comptime _NO_COMMON_TYPE: String = "no common type this engine casts to"
comptime _HUGEINT_COMMON_TYPE: String = (
    "DuckDB's common type is HUGEINT, which Arrow cannot hold"
)


def _int_bits(at: ArrowType) -> Int:
    """The width in bits of an integer type."""
    if at == ArrowType.INT8 or at == ArrowType.UINT8:
        return 8
    if at == ArrowType.INT16 or at == ArrowType.UINT16:
        return 16
    if at == ArrowType.INT32 or at == ArrowType.UINT32:
        return 32
    return 64


def _is_signed_int(at: ArrowType) -> Bool:
    return (
        at == ArrowType.INT8
        or at == ArrowType.INT16
        or at == ArrowType.INT32
        or at == ArrowType.INT64
    )


def _signed_of_bits(bits: Int) -> ArrowType:
    """The signed integer type of 16, 32 or 64 bits."""
    if bits == 16:
        return ArrowType.INT16
    if bits == 32:
        return ArrowType.INT32
    return ArrowType.INT64


def _int_decimal_digits(at: ArrowType) -> Int:
    """The digits of the decimal an integer type converts to, DECIMAL(w, 0)."""
    if at == ArrowType.INT8 or at == ArrowType.UINT8:
        return 3
    if at == ArrowType.INT16 or at == ArrowType.UINT16:
        return 5
    if at == ArrowType.INT32 or at == ArrowType.UINT32:
        return 10
    if at == ArrowType.INT64:
        return 19
    return 20


def _common_int(a: ArrowType, b: ArrowType) -> _Common:
    """Two distinct integer types: DuckDB's wider type of the same signedness,
    and for a signed with an unsigned one the signed type twice the unsigned
    width (HUGEINT, refused, past 64 bits)."""
    var a_signed = _is_signed_int(a)
    var b_signed = _is_signed_int(b)
    if a_signed == b_signed:
        if _int_bits(a) >= _int_bits(b):
            return _Common(a)
        return _Common(b)
    var sgn = a if a_signed else b
    var uns = b if a_signed else a
    if _int_bits(uns) < _int_bits(sgn):
        return _Common(sgn)
    if _int_bits(uns) * 2 > 64:
        return _Common(ArrowType.NULL, why=String(_HUGEINT_COMMON_TYPE))
    return _Common(_signed_of_bits(_int_bits(uns) * 2))


def _common_decimal(p1: Int, s1: Int, p2: Int, s2: Int) -> _Common:
    """Two decimals: the larger scale and the larger count of integer digits."""
    var scale = max(s1, s2)
    var precision = max(p1 - s1, p2 - s2) + scale
    if precision > 38:
        return _Common(
            ArrowType.NULL,
            why="the common decimal would need " + String(precision)
            + " digits, above 38",
        )
    return _Common(ArrowType.DECIMAL128, precision, scale)


def _timestamp_unit_rank(at: ArrowType) -> Int:
    """The coarseness order of the units `_common_timestamp` compares: seconds,
    milliseconds, then microseconds (the legacy timestamp included)."""
    if at == ArrowType.TIMESTAMP_S:
        return 0
    if at == ArrowType.TIMESTAMP_MS:
        return 1
    return 2


def _common_timestamp(
    a: ArrowType, a_tz: String, b: ArrowType, b_tz: String
) -> _Common:
    """Two timestamps: the same type and zone as is, else the finer unit of two
    zone-less timestamps neither of which is in nanoseconds."""
    if a == b and a_tz == b_tz:
        return _Common(a)
    if (
        a.is_timestamp()
        and b.is_timestamp()
        and a_tz == ""
        and b_tz == ""
        and a != ArrowType.TIMESTAMP_NS
        and b != ArrowType.TIMESTAMP_NS
    ):
        if _timestamp_unit_rank(a) >= _timestamp_unit_rank(b):
            return _Common(a)
        return _Common(b)
    return _Common(ArrowType.NULL, why=String(_NO_COMMON_TYPE))


def _common_type(
    a: ArrowType,
    a_precision: Int,
    a_scale: Int,
    a_tz: String,
    b: ArrowType,
    b_precision: Int,
    b_scale: Int,
    b_tz: String,
) -> _Common:
    """The common type DuckDB gives a UNION ALL column whose branches have the
    types `a` and `b` (see the module header for what is refused)."""
    if _int_to_string(a, b) or _int_to_string(b, a):
        return _Common(ArrowType.STRING)
    if a.is_timestamp() or b.is_timestamp():
        return _common_timestamp(a, a_tz, b, b_tz)
    var a_dec = a == ArrowType.DECIMAL128
    var b_dec = b == ArrowType.DECIMAL128
    if a_dec and b_dec:
        return _common_decimal(a_precision, a_scale, b_precision, b_scale)
    if a == b:
        return _Common(a)
    if a.is_integer() and b.is_integer():
        return _common_int(a, b)
    if a_dec or b_dec:
        var other = b if a_dec else a
        if other == ArrowType.FLOAT32 or other == ArrowType.FLOAT64:
            return _Common(other)
        if other.is_integer():
            var dec_p = a_precision if a_dec else b_precision
            var dec_s = a_scale if a_dec else b_scale
            return _common_decimal(
                dec_p, dec_s, _int_decimal_digits(other), 0
            )
        return _Common(ArrowType.NULL, why=String(_NO_COMMON_TYPE))
    var a_float = a == ArrowType.FLOAT32 or a == ArrowType.FLOAT64
    var b_float = b == ArrowType.FLOAT32 or b == ArrowType.FLOAT64
    if a_float and b_float:
        return _Common(ArrowType.FLOAT64)
    if a_float and b.is_integer():
        return _Common(a)
    if b_float and a.is_integer():
        return _Common(b)
    return _Common(ArrowType.NULL, why=String(_NO_COMMON_TYPE))


def _int_to_string(a: ArrowType, b: ArrowType) -> Bool:
    """`a` is INT32 or INT64 and `b` STRING: the integer pair whose cast to a
    string the engine serves."""
    return (a == ArrowType.INT32 or a == ArrowType.INT64) and b == ArrowType.STRING


def _union_type_name(schema: Schema, i: Int) -> String:
    """A column's type as an error message names it (a decimal with its
    precision and scale)."""
    if schema.field_arrow_type(i) == ArrowType.DECIMAL128:
        return (
            "DECIMAL128(" + String(schema.field_decimal_precision(i)) + ", "
            + String(schema.field_decimal_scale(i)) + ")"
        )
    return String(schema.field_arrow_type(i))


def _same_column_type(a: Schema, b: Schema, i: Int) -> Bool:
    """Column `i` has one type in both schemas (a decimal: one precision and
    scale)."""
    if a.field_arrow_type(i) != b.field_arrow_type(i):
        return False
    if a.field_arrow_type(i) == ArrowType.DECIMAL128:
        return (
            a.field_decimal_precision(i) == b.field_decimal_precision(i)
            and a.field_decimal_scale(i) == b.field_decimal_scale(i)
        )
    return True


def _union_merge_schema(
    acc: Schema,
    rhs: Schema,
    branch: Int,
    op: String = "UNION ALL",
    first: Int = 1,
) raises -> Schema:
    """Fold branch number `branch` (2-based) into the schema `acc` built from
    branches `first` to `branch - 1` of a set operation `op` (`UNION ALL`,
    `INTERSECT` or `EXCEPT`, which errors name): the column count must match,
    each column takes the common type of the two, the names stay `acc`'s (the
    left input's, as in DuckDB), and a column is nullable when either side
    is."""
    if acc.num_columns() != rhs.num_columns():
        var article = String("a ")
        if op.startswith("I") or op.startswith("E"):
            article = "an "
        var left = String("the first branch")
        if first > 1:
            left = "branch " + String(first)
        raise Error(
            "SQL bind error: " + op + " branch " + String(branch) + " produces "
            + String(rhs.num_columns()) + " column(s) but " + left
            + " produces " + String(acc.num_columns())
            + ". Every branch of " + article + op + " must produce the same number of"
            " columns, in the same order."
        )
    var builder = SchemaBuilder()
    for i in range(acc.num_columns()):
        var common = _common_type(
            acc.field_arrow_type(i),
            acc.field_decimal_precision(i),
            acc.field_decimal_scale(i),
            acc.field_tz(i),
            rhs.field_arrow_type(i),
            rhs.field_decimal_precision(i),
            rhs.field_decimal_scale(i),
            rhs.field_tz(i),
        )
        if common.why != "":
            var earlier = "branch " + String(first) + " gives"
            if branch - 1 > first:
                earlier = (
                    "branches " + String(first) + " to " + String(branch - 1)
                    + " give"
                )
            raise Error(
                "SQL not supported: " + op + " column " + String(i + 1) + " ("
                + String(acc.field_name(i)) + "): " + earlier + " "
                + _union_type_name(acc, i) + " and branch " + String(branch)
                + " gives " + _union_type_name(rhs, i) + "; " + common.why
                + ". Cast the columns to one type."
            )
        var nullable = acc.field_nullable(i) or rhs.field_nullable(i)
        if common.at == ArrowType.DECIMAL128:
            builder.add_field(
                Field.decimal128(
                    String(acc.field_name(i)), common.precision, common.scale,
                    nullable,
                )
            )
        elif common.at == acc.field_arrow_type(i):
            var kept = acc.field_at(i)
            kept.nullable = nullable
            builder.add_field(kept)
        else:
            builder.add_field(
                Field(String(acc.field_name(i)), common.at, nullable)
            )
    return builder.build()


def _union_conform_branch(
    var plan: LogicalPlan, out_schema: Schema, branch: Int
) raises -> LogicalPlan:
    """A branch plan whose column names and types are the union's: `plan`
    itself when it already is; else, when the branch ends in a projection (its
    SELECT list), that projection with each expression cast and renamed by
    position; else `plan` under one projection that casts and renames each
    column, which names its input columns and so refuses a branch with two
    columns of one name."""
    var n = plan.output_schema.num_columns()
    var differs = False
    for i in range(n):
        if plan.output_schema.field_name(i) != out_schema.field_name(i):
            differs = True
        if not _same_column_type(plan.output_schema, out_schema, i):
            differs = True
    if not differs:
        return plan^
    if plan.tag == PLAN_PROJECT and not plan.project_data_ref().udf:
        # The branch ends in its SELECT list: cast and rename that list's
        # expressions in place, by position, so two items of one name (two
        # bare literals are both `literal`) stay two columns.
        var listed = ExprArray()
        for i in range(n):
            listed.append(
                _conform_expr(
                    plan.project_data_ref().exprs[i].copy(),
                    plan.output_schema,
                    out_schema,
                    i,
                )
            )
        var child = LogicalPlan(PLAN_SCAN, Schema())
        swap(child, plan._project.value()[].child[])
        return LogicalPlan.project(listed^, child^)
    for i in range(n):
        for j in range(i + 1, n):
            if plan.output_schema.field_name(i) == plan.output_schema.field_name(j):
                raise Error(
                    "SQL not supported: UNION ALL branch " + String(branch)
                    + " has two columns named `"
                    + String(plan.output_schema.field_name(i)) + "` and needs"
                    " its columns renamed or cast to match the other branches."
                    " Columns are matched by name, so the second would read the"
                    " first's values. Give the two columns distinct aliases."
                )
    var exprs = ExprArray()
    for i in range(n):
        exprs.append(
            _conform_expr(
                Expr.col_ref(String(plan.output_schema.field_name(i))),
                plan.output_schema,
                out_schema,
                i,
            )
        )
    return LogicalPlan.project(exprs^, plan^)


def _conform_expr(
    var e: Expr, branch_schema: Schema, out_schema: Schema, i: Int
) raises -> Expr:
    """`e`, the branch's column `i`, cast to the union's type when the two
    differ and named as the union's column `i`."""
    if not _same_column_type(branch_schema, out_schema, i):
        if out_schema.field_arrow_type(i) == ArrowType.DECIMAL128:
            e = Expr.cast_to_decimal(
                e^, out_schema.field_decimal_precision(i),
                out_schema.field_decimal_scale(i),
            )
        else:
            e = Expr.cast_to_arrow(e^, out_schema.field_arrow_type(i))
    return Expr.alias(e^, String(out_schema.field_name(i)))
