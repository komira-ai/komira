"""Expression nodes as `WireExpr` messages.

Each node kind is one arm of the `WireExpr` oneof (src/plan_proto/plan.proto),
and each arm carries what the engine's factory for that kind holds
(src/plan_expr/expr.mojo), so the reader rebuilds the expression the engine
would have built itself:

    ColRef       col_ref, by name, with its side (none, left or right)
    Lit          literal (komira/_plan/_scalar.py)
    Compare      binary_op eq ne lt le gt ge
    Arith        binary_op add sub mul div mod
    BoolOp       binary_op and or
    Unary        unary_op
    Cast         cast: DType, Arrow type, precision, scale, try (cast_parts)
    When         when: the cases in order and the default
    StringOp     string_op with its pattern
    Regexp       regexp with its pattern, replacement, flags and group
    StringFn     string_fn
    StringFnN    string_fn_n, its arguments in order, their count checked
    Substring    substring; no length is -1, "to the end"
    MathFn       math_fn
    MathFn2      math_fn2, its operands in order
    Extract      extract, a part or a truncation
    StructField  struct_field by name
    Alias        alias

Nothing is rewritten except a CASE's literal results (`promotes`), and nothing
is reordered. `is_in` and `between` are already comparisons joined by `or` and
`and`, which is how the SQL binder spells IN and BETWEEN too.
"""

from __future__ import annotations

from collections.abc import Iterable

from komira._ops._expr import (
    Alias,
    Arith,
    BoolOp,
    Cast,
    ColRef,
    Compare,
    Extract,
    Lit,
    MathFn,
    MathFn2,
    Node,
    Regexp,
    StringFn,
    StringFnN,
    StringOp,
    StructField,
    Substring,
    Unary,
    When,
)

from ._field import cast_parts, check_columns, columns_of, field_of, promotes
from ._scalar import scalar
from ._wire import member, pb

__all__ = ["encode_expr"]

# The argument count of each `StringFnN` op: n exactly, or at least -n
# (`string_fn_n_arity`, src/plan_expr/expr.mojo). The reader refuses any other
# count as a malformed plan.
_STRING_FN_N_ARITY = {
    "concat": -1,
    "concat_ws": -2,
    "replace": 3,
    "lpad": 3,
    "rpad": 3,
    "repeat": 2,
    "strpos": 2,
    "levenshtein": 2,
    "damerau_levenshtein": 2,
    "hamming": 2,
    "translate": 3,
    "jaro": 2,
    "jaro_winkler": 2,
    "jaccard": 2,
}


def _check_arity(node: StringFnN) -> None:
    want, got = _STRING_FN_N_ARITY[node.op], len(node.args)
    if want > 0 and got != want:
        raise ValueError(f"StringFnN {node.op} takes {want} arguments, not {got}")
    if want < 0 and got < -want:
        raise ValueError(f"StringFnN {node.op} takes at least {-want} arguments, not {got}")


def _binary(out: pb.WireExpr, op: str, left: Node, right: Node, columns) -> None:
    out.binary_op.op = member("BIN_", op)
    _encode(out.binary_op.left, left, columns)
    _encode(out.binary_op.right, right, columns)


def _when(out: pb.WireExpr, node: When, columns) -> None:
    promote = promotes(node, columns)
    for condition, result in node.cases:
        case = out.when.cases.add()
        _encode(case.condition, condition, columns)
        _encode(case.result, result, columns, promote)
    _encode(out.when.default_expr, node.default, columns, promote)


def _cast(out: pb.WireExpr, node: Cast, columns) -> None:
    code, type_id, precision, scale = cast_parts(node)
    _encode(out.cast.child, node.child, columns)
    out.cast.target_dtype_code = code
    out.cast.target_arrow_type_id = type_id
    out.cast.decimal_precision = precision
    out.cast.decimal_scale = scale
    out.cast.try_cast = node.try_cast


def _regexp(out: pb.WireExpr, node: Regexp, columns) -> None:
    out.regexp.op = member("REGEXP_", node.op)
    _encode(out.regexp.child, node.child, columns)
    out.regexp.pattern = node.pattern
    out.regexp.replacement = node.replacement
    out.regexp.flags = node.flags
    out.regexp.group = node.group


def _encode(out: pb.WireExpr, node: Node, columns, as_float: bool = False) -> None:
    """Fill `out` with `node`. `as_float` is for a literal result of a float64
    CASE."""
    if isinstance(node, ColRef):
        out.col_ref.name = node.name
        out.col_ref.side = member("COL_SIDE_", node.side or "none")
    elif isinstance(node, Lit):
        out.literal.CopyFrom(scalar(node.value, as_float))
    elif isinstance(node, (Compare, Arith, BoolOp)):
        _binary(out, node.op, node.left, node.right, columns)
    elif isinstance(node, Unary):
        out.unary_op.op = member("UN_", node.op)
        _encode(out.unary_op.child, node.child, columns)
    elif isinstance(node, Cast):
        _cast(out, node, columns)
    elif isinstance(node, When):
        _when(out, node, columns)
    elif isinstance(node, StringOp):
        out.string_op.op = member("STR_", node.op)
        _encode(out.string_op.child, node.child, columns)
        out.string_op.pattern = node.pattern
    elif isinstance(node, Regexp):
        _regexp(out, node, columns)
    elif isinstance(node, StringFn):
        out.string_fn.op = member("STRFN_", node.op)
        _encode(out.string_fn.child, node.child, columns)
    elif isinstance(node, StringFnN):
        _check_arity(node)
        out.string_fn_n.op = member("STRFNN_", node.op)
        for arg in node.args:
            _encode(out.string_fn_n.args.add(), arg, columns)
    elif isinstance(node, Substring):
        _encode(out.substring.child, node.child, columns)
        out.substring.start = node.start
        out.substring.length = -1 if node.length is None else node.length
    elif isinstance(node, MathFn):
        out.math_fn.op = member("MATH_", node.op)
        _encode(out.math_fn.child, node.child, columns)
    elif isinstance(node, MathFn2):
        out.math_fn2.op = member("MATH2_", node.op)
        _encode(out.math_fn2.left, node.left, columns)
        _encode(out.math_fn2.right, node.right, columns)
    elif isinstance(node, Extract):
        out.extract.unit = member("EXTRACT_", node.unit)
        _encode(out.extract.child, node.child, columns)
    elif isinstance(node, StructField):
        # Typing it refuses a parent that is not a struct or lacks the field.
        field_of(node, columns)
        _encode(out.struct_field.parent, node.parent, columns)
        out.struct_field.field_name = node.field
    else:
        out.alias.name = node.name
        _encode(out.alias.child, node.child, columns)


def encode_expr(node: Node, schema: Iterable[pb.WireField]) -> pb.WireExpr:
    """`node` as a `WireExpr` over the input columns `schema` (a sequence of
    `WireField`). Raises the `KeyError` of `unknown_column` for a column the
    schema lacks, before anything is encoded."""
    columns = columns_of(schema)
    check_columns(node, columns)
    out = pb.WireExpr()
    _encode(out, node, columns)
    return out
