# =============================================================================
# sql/sql_bind_union.mojo
#   UNION ALL: binding a chain of branches into one `PLAN_UNION`, with DuckDB's
#   common column types.
# =============================================================================
#
# `<select> UNION ALL <select> ...` binds each branch, folds one common type per
# column over the branches left to right, and puts one projection on every
# branch whose names or types differ from the union's, so every child of the
# node advertises exactly the node's schema (`LogicalPlan.union` does not
# coerce). A pair of types this engine cannot cast between is refused by name.
#
# Where DuckDB answers and this binder refuses, by name: UBIGINT with a signed
# integer (DuckDB's HUGEINT; Arrow has no 128-bit integer); a common decimal
# wider than 38 digits (DuckDB narrows the scale or keeps a type the values
# can overflow); BOOLEAN with a number, DATE with a timestamp, a string with
# any other type, STRING with LARGE_STRING, and a timestamp with a zone or in
# nanoseconds against another unit (the projection's casts do not serve these
# pairs exactly). A column is nullable when any branch is; nullability alone
# never adds a projection, because the concatenation merges validity.

from arrow.arrow_types import ArrowType
from arrow.schema import Field, Schema, SchemaBuilder
from plan_expr.expr import Expr
from plan_ir.logical_plan import ExprArray, LogicalPlan
from sql.sql_ast import SelectStmt
from sql.sql_bind_scope import CteScope
from sql.sql_binder import _bind_select
from sql.sql_catalog import SqlCatalog
from std.builtin.swap import swap
from std.memory import OwnedPointer


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


def _union_merge_schema(acc: Schema, rhs: Schema, branch: Int) raises -> Schema:
    """Fold branch number `branch` (2-based) into the union schema `acc` built
    from the branches before it: the column count must match, each column takes
    the common type of the two, the names stay `acc`'s (the first branch's, as in
    DuckDB), and a column is nullable when either side is."""
    if acc.num_columns() != rhs.num_columns():
        raise Error(
            "SQL bind error: UNION ALL branch " + String(branch) + " produces "
            + String(rhs.num_columns()) + " column(s) but the first branch"
            " produces " + String(acc.num_columns())
            + ". Every branch of a UNION ALL must produce the same number of"
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
            var earlier = String("branch 1 gives")
            if branch > 2:
                earlier = "branches 1 to " + String(branch - 1) + " give"
            raise Error(
                "SQL not supported: UNION ALL column " + String(i + 1) + " ("
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
    itself when it already is, else `plan` under one projection that casts each
    column of another type and renames each column to the union's name."""
    var n = plan.output_schema.num_columns()
    var differs = False
    for i in range(n):
        if plan.output_schema.field_name(i) != out_schema.field_name(i):
            differs = True
        if not _same_column_type(plan.output_schema, out_schema, i):
            differs = True
    if not differs:
        return plan^
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
        var e = Expr.col_ref(String(plan.output_schema.field_name(i)))
        if not _same_column_type(plan.output_schema, out_schema, i):
            if out_schema.field_arrow_type(i) == ArrowType.DECIMAL128:
                e = Expr.cast_to_decimal(
                    e^, out_schema.field_decimal_precision(i),
                    out_schema.field_decimal_scale(i),
                )
            else:
                e = Expr.cast_to_arrow(e^, out_schema.field_arrow_type(i))
        exprs.append(Expr.alias(e^, String(out_schema.field_name(i))))
    return LogicalPlan.project(exprs^, plan^)


def _bind_select_with_union(
    body: SelectStmt,
    top: SelectStmt,
    catalog: SqlCatalog,
    cte_scope: CteScope,
    prebound: List[Expr],
    result_names: Bool,
) raises -> LogicalPlan:
    """Bind `body`, a SELECT that may head a UNION ALL chain, to a plan: the
    SELECT's own plan when `body.union_all_idx < 0`, else the chain's
    `PLAN_UNION`. The chain's branch bodies live in `top.subqueries` (the
    top-level statement's table, which `body.union_all_idx` indexes)."""
    var head = _bind_select(
        body, catalog, cte_scope, prebound, result_names,
        body.union_all_idx >= 0,
    )
    if body.union_all_idx < 0:
        return head^
    return _bind_union_all_chain(
        head^, top, body.union_all_idx, catalog, cte_scope, prebound
    )


def _bind_union_all_chain(
    var head: LogicalPlan,
    top: SelectStmt,
    first_idx: Int,
    catalog: SqlCatalog,
    cte_scope: CteScope,
    prebound: List[Expr],
) raises -> LogicalPlan:
    """`<select> UNION ALL <select> [UNION ALL ...]` -> one `PLAN_UNION`.

    N branches make one node with N children, not a left-deep tree of
    two-branch unions.

    Iterative: the branch bodies live in the top-level statement's
    `subqueries` table, so the chain is a linked list of indices into one
    table, walked with a loop. Recursing through each branch body would
    re-enter `_bind_select` from inside itself, a shape the Mojo compiler
    hangs on.

    The output schema folds each column's common type over the branches
    (`_union_merge_schema`) and keeps the first branch's names, which is
    DuckDB's rule: `SELECT a FROM t UNION ALL SELECT b FROM u` is a column
    called `a`. Every branch then goes through `_union_conform_branch`. Each
    branch's bare integer result literals are INT32 as in a lone SELECT, so
    `SELECT 1 UNION ALL SELECT 5000000000` widens to BIGINT.
    """
    var out_schema = head.output_schema.copy()
    var children = List[OwnedPointer[LogicalPlan]]()
    children.append(OwnedPointer(head^))
    var idx = first_idx
    var branch = 2
    while idx >= 0:
        ref sd = top.subqueries[idx]
        var plan = _bind_select(
            sd.body, catalog, cte_scope, prebound, False, True
        )
        out_schema = _union_merge_schema(out_schema, plan.output_schema, branch)
        var next_idx = sd.body.union_all_idx
        children.append(OwnedPointer(plan^))
        idx = next_idx
        branch += 1
    for i in range(len(children)):
        var taken = LogicalPlan.union(
            List[OwnedPointer[LogicalPlan]](), Schema()
        )
        swap(taken, children[i][])
        children[i][] = _union_conform_branch(taken^, out_schema, i + 1)
    return LogicalPlan.union(children^, out_schema^)
