"""The field the engine derives for an expression over an input schema.

A plan node that computes columns carries the schema of its output, and the
reader rebuilds the node and compares the schema it derives with the one on the
wire, refusing the plan when they differ. So the encoder derives each field by
the engine's own rules, `walk_expr_field` (src/plan_expr/expr_walk.mojo), arm
for arm: the same name, Arrow type, nullability, decimal precision and scale,
and the slots a column reference carries over.

An input schema is a sequence of `WireField`, the columns an expression may
name; the first column of a name is the one a reference reads, as in the
engine. A join residual reads two inputs, and each of its column references
names its side: `sided_columns` keys the columns of both by side and name, and
a sided reference is looked up by both.
"""

from __future__ import annotations

from collections.abc import Iterable

from komira._errors import UnsupportedOperation
from komira._ops._columns import unknown_column
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
    RoundDigits,
    StringFn,
    StringFnN,
    StringOp,
    StructField,
    Substring,
    UdfCall,
    Unary,
    When,
)
from komira._ops._walk import column_refs

from ._scalar import literal_field, scalar
from ._udf import udf_ref
from ._wire import arrow_id, dtype_code, field, pb, physical_dtype

__all__ = [
    "call_ref",
    "cast_parts",
    "check_columns",
    "columns_of",
    "expr_field",
    "field_of",
    "promotes",
    "sided_columns",
]

_BOOL = arrow_id("bool")
_INT8 = arrow_id("int8")
_INT32 = arrow_id("int32")
_INT64 = arrow_id("int64")
_FLOAT64 = arrow_id("float64")
_STRING = arrow_id("string")
_LIST = arrow_id("list")
_STRUCT = arrow_id("struct")
_DECIMAL128 = arrow_id("decimal128")
_INTERVAL_MDN = arrow_id("interval_month_day_nano")

_DEC128_MAX_PRECISION = 38
_INT32_MIN = -(2**31)
_INT64_MIN = -(2**63)

_STRING_FN_INT = frozenset({"length", "ascii", "unicode", "strlen", "bit_length"})
_STRING_FN_N_INT = frozenset({"strpos", "levenshtein", "damerau_levenshtein", "hamming"})
_STRING_FN_N_FLOAT = frozenset({"jaro", "jaro_winkler", "jaccard"})

# Regexp op: (field name, type), where "list" is a list of strings.
_REGEXP = {
    "like": ("regexp_like", _BOOL),
    "full_match": ("regexp_full_match", _BOOL),
    "match": ("regexp_match", "list"),
    "split_to_array": ("regexp_split", "list"),
    "extract_all": ("regexp_extract_all", "list"),
    "replace": ("regexp_replace", _STRING),
    "substr": ("regexp_substr", _STRING),
    "count": ("regexp_count", _INT64),
    "instr": ("regexp_instr", _INT64),
    "extract": ("regexp", _STRING),
}

# Unary op: the field name of an op whose type is its operand's.
_UNARY_KEEPS_TYPE = {"negate": "neg", "abs": "abs", "trunc": "trunc", "round": "round"}


def columns_of(schema: Iterable[pb.WireField]) -> dict[str, pb.WireField]:
    """The input columns by name, the first of each name."""
    columns: dict[str, pb.WireField] = {}
    for column in schema:
        if not isinstance(column, pb.WireField):
            raise TypeError(f"a schema holds WireField values, not {type(column).__name__}")
        columns.setdefault(column.name, column)
    return columns


def sided_columns(
    left: Iterable[pb.WireField], right: Iterable[pb.WireField]
) -> dict[object, pb.WireField]:
    """The columns of a join's two inputs, keyed `(side, name)`, the first of
    each name on each side: what a residual, whose references each name a
    side, is typed over."""
    columns: dict[object, pb.WireField] = {}
    for side, schema in (("left", left), ("right", right)):
        for name, column in columns_of(schema).items():
            columns[(side, name)] = column
    return columns


def _key(ref: ColRef, columns: dict) -> object:
    """The key a reference is looked up by: its side and name over the
    columns of a join's two inputs, its name otherwise."""
    sided = (ref.side, ref.name)
    return sided if sided in columns else ref.name


def check_columns(node: Node, columns: dict) -> None:
    """Raise the `KeyError` of `unknown_column` for the first column the
    expression names that the schema does not have."""
    for ref in column_refs(node):
        if _key(ref, columns) not in columns:
            names = tuple(k[1] for k in columns if isinstance(k, tuple) and k[0] == ref.side)
            if not names:
                names = tuple(k for k in columns if not isinstance(k, tuple))
            raise unknown_column(ref.name, names)


def cast_parts(node: Cast) -> tuple[int, int, int, int]:
    """The DType code, Arrow type id, precision and scale a cast carries.

    A cast to a primitive type carries that type's DType and Arrow type; a cast
    to an Arrow type carries the DType the engine gives it (none for decimal,
    string and nested types) unless `target` names one; a decimal128 cast
    carries its precision and scale.
    """
    if node.arrow is None:
        return dtype_code(node.target), arrow_id(node.target), 0, 0
    code = dtype_code(node.target) if node.target is not None else physical_dtype(node.arrow)
    if node.arrow != "decimal128":
        return code, arrow_id(node.arrow), 0, 0
    if node.precision > _DEC128_MAX_PRECISION or node.scale > node.precision:
        raise UnsupportedOperation(
            f"a cast to decimal128({node.precision}, {node.scale}) cannot be encoded: "
            "decimal128 takes a precision of 1 to 38 and a scale of at most the precision"
        )
    return code, _DECIMAL128, node.precision, node.scale


def _promotable(node: Node) -> bool:
    """A literal a float64 CASE turns into a float64: an int or None."""
    return isinstance(node, Lit) and (
        node.value is None or (isinstance(node.value, int) and not isinstance(node.value, bool))
    )


def _branch_fields(node: When, columns: dict[str, pb.WireField]) -> list[pb.WireField]:
    """The fields of a CASE's results, then of its default, each typed once."""
    return [field_of(result, columns) for _, result in node.cases] + [field_of(node.default, columns)]


def _float_case(fields: list[pb.WireField]) -> bool:
    return any(f.arrow_type_id == _FLOAT64 for f in fields)


def promotes(node: When, columns: dict[str, pb.WireField]) -> bool:
    """Whether a CASE is float64: a result or the default is. Its int and NULL
    literal results are then float64 literals, as the SQL binder makes them,
    so that every branch has the CASE's type."""
    return _float_case(_branch_fields(node, columns))


def _when(node: When, columns: dict[str, pb.WireField]) -> pb.WireField:
    """A CASE is typed by its first result, a literal one as `promotes` makes it."""
    fields = _branch_fields(node, columns)
    first, first_field = node.cases[0][1], fields[0]
    if _float_case(fields) and _promotable(first):
        first_field = literal_field(scalar(first.value, as_float=True))
    return field("case", first_field.arrow_type_id, True)


def _carry(column: pb.WireField, name: str) -> pb.WireField:
    """The field a column reference resolves to: the column's type,
    nullability, precision, scale, zone and children, and nothing else (no
    metadata), as the engine's plan-side reference does."""
    f = field(name, column.arrow_type_id, column.nullable)
    f.decimal_precision = column.decimal_precision
    f.decimal_scale = column.decimal_scale
    f.tz = column.tz
    f.child_names.extend(column.child_names)
    f.child_type_ids.extend(column.child_type_ids)
    f.child_nullables.extend(column.child_nullables)
    return f


def _decimal(precision: int, scale: int) -> pb.WireField:
    f = field("expr", _DECIMAL128, True)
    f.decimal_precision = precision
    f.decimal_scale = scale
    return f


def _decimal_add(p1: int, s1: int, p2: int, s2: int) -> pb.WireField:
    scale = max(s1, s2)
    return _decimal(min(max(p1 - s1, p2 - s2) + scale + 1, _DEC128_MAX_PRECISION), scale)


def _decimal_mul(p1: int, s1: int, p2: int, s2: int) -> pb.WireField:
    return _decimal(min(p1 + p2 + 1, _DEC128_MAX_PRECISION), s1 + s2)


def _int_outside_int32(node: Node) -> bool:
    """An int literal the wire carries as int64 that int32 cannot hold."""
    if not isinstance(node, Lit) or isinstance(node.value, bool) or not isinstance(node.value, int):
        return False
    return _INT64_MIN <= node.value < -_INT64_MIN and not _INT32_MIN <= node.value < -_INT32_MIN


def _arith(node: Arith, columns: dict[str, pb.WireField]) -> pb.WireField:
    left = field_of(node.left, columns)
    right = field_of(node.right, columns)
    lt, rt, op = left.arrow_type_id, right.arrow_type_id, node.op
    if lt == _INTERVAL_MDN and rt == _INTERVAL_MDN and op in ("add", "sub"):
        return field("expr", _INTERVAL_MDN, True)
    if lt == _DECIMAL128 and rt == _DECIMAL128:
        p1, s1 = left.decimal_precision, left.decimal_scale
        p2, s2 = right.decimal_precision, right.decimal_scale
        if op in ("add", "sub"):
            return _decimal_add(p1, s1, p2, s2)
        if op == "mul":
            return _decimal_mul(p1, s1, p2, s2)
        if op == "div":
            return field("expr", _FLOAT64, True)
        return _decimal(p1, s1)
    if _DECIMAL128 in (lt, rt):
        if _FLOAT64 in (lt, rt):
            return field("expr", _FLOAT64, True)
        dec, other = (left, rt) if lt == _DECIMAL128 else (right, lt)
        p, s = dec.decimal_precision, dec.decimal_scale
        if other == _INT64:
            if op == "div":
                return field("expr", _FLOAT64, True)
            if op == "mul":
                return _decimal_mul(p, s, 19, 0)
            if op in ("add", "sub"):
                return _decimal_add(p, s, 19 + s, s)
        return _decimal(p, s)
    result = _FLOAT64 if _FLOAT64 in (lt, rt) else lt
    if result == _INT32 and op != "mod" and _int_outside_int32(node.right):
        result = _INT64
    return field("expr", result, True)


def _unary(node: Unary, columns: dict[str, pb.WireField]) -> pb.WireField:
    if node.op == "not":
        return field("not", _BOOL, True)
    if node.op in ("sign", "bit_count"):
        return field(node.op, _INT8, True)
    if node.op in ("is_null", "is_not_null"):
        return field(node.op, _BOOL, False)
    child = field_of(node.child, columns)
    return field(_UNARY_KEEPS_TYPE[node.op], child.arrow_type_id, child.nullable)


def _round_digits(node: RoundDigits, columns: dict[str, pb.WireField]) -> pb.WireField:
    """The type of a digit-count round of an integer or float operand is the
    operand's, named `trunc` for `trunc` and `round` otherwise, as the engine
    names it. A DECIMAL operand, whose scale the engine derives from the digit
    count, is refused here: no verb of this package builds one."""
    child = field_of(node.child, columns)
    if child.arrow_type_id == _DECIMAL128:
        raise UnsupportedOperation(
            "a digit-count round of a decimal128 operand cannot be encoded here"
        )
    name = "trunc" if node.op == "trunc" else "round"
    return field(name, child.arrow_type_id, child.nullable)


def _cast(node: Cast, columns: dict[str, pb.WireField]) -> pb.WireField:
    child = field_of(node.child, columns)
    _, type_id, precision, scale = cast_parts(node)
    f = field(child.name, type_id, child.nullable or node.try_cast)
    f.decimal_precision = precision
    f.decimal_scale = scale
    return f


def _regexp(node: Regexp) -> pb.WireField:
    name, type_id = _REGEXP[node.op]
    if type_id != "list":
        return field(name, type_id, True)
    f = field(name, _LIST, True)
    f.child_names.append("item")
    f.child_type_ids.append(_STRING)
    f.child_nullables.append(True)
    return f


def _string_fn_n(node: StringFnN) -> pb.WireField:
    if node.op in _STRING_FN_N_INT:
        return field("string_fn_n", _INT64, True)
    if node.op in _STRING_FN_N_FLOAT:
        return field("string_fn_n", _FLOAT64, True)
    return field("string_fn_n", _STRING, True)


def _struct_field(node: StructField, columns: dict[str, pb.WireField]) -> pb.WireField:
    parent = field_of(node.parent, columns)
    if parent.arrow_type_id != _STRUCT:
        raise TypeError(
            f"StructField reads the field '{node.field}' of a value of Arrow type id "
            f"{parent.arrow_type_id}, and only a struct (id {_STRUCT}) has fields"
        )
    for name, type_id, nullable in zip(
        parent.child_names, parent.child_type_ids, parent.child_nullables
    ):
        if name == node.field:
            return field(name, type_id, nullable)
    raise KeyError(
        f"the struct has no field named '{node.field}'; its fields are: "
        + ", ".join(parent.child_names)
    )


def call_ref(node: UdfCall, columns: dict[str, pb.WireField]) -> pb.UdfRef:
    """The `UdfRef` a call names: its arguments' fields over `columns`, refused
    when one is not a type the komira/python runtime carries."""
    return udf_ref(node.udf, [field_of(arg, columns) for arg in node.args])


def field_of(node: Node, columns: dict[str, pb.WireField]) -> pb.WireField:
    """The field of `node` over `columns`, whose names `check_columns` has
    found in it."""
    if isinstance(node, ColRef):
        return _carry(columns[_key(node, columns)], node.name)
    if isinstance(node, Alias):
        f = field_of(node.child, columns)
        f.name = node.name
        return f
    if isinstance(node, Lit):
        return literal_field(scalar(node.value))
    if isinstance(node, (Compare, BoolOp)):
        return field("expr", _BOOL, True)
    if isinstance(node, Arith):
        return _arith(node, columns)
    if isinstance(node, Unary):
        return _unary(node, columns)
    if isinstance(node, RoundDigits):
        return _round_digits(node, columns)
    if isinstance(node, Cast):
        return _cast(node, columns)
    if isinstance(node, When):
        return _when(node, columns)
    if isinstance(node, StringOp):
        return field("str_op", _BOOL, True)
    if isinstance(node, Regexp):
        return _regexp(node)
    if isinstance(node, StringFn):
        return field("string_fn", _INT64 if node.op in _STRING_FN_INT else _STRING, True)
    if isinstance(node, StringFnN):
        return _string_fn_n(node)
    if isinstance(node, Substring):
        return field("substring", _STRING, True)
    if isinstance(node, (MathFn, MathFn2)):
        return field("math_fn", _FLOAT64, True)
    if isinstance(node, Extract):
        if node.unit.startswith("trunc_"):
            f = field_of(node.child, columns)
            f.name = "date_trunc"
            return f
        return field("extract", _INT64, True)
    if isinstance(node, UdfCall):
        return call_ref(node, columns).return_type
    return _struct_field(node, columns)


def expr_field(node: Node, schema: Iterable[pb.WireField]) -> pb.WireField:
    """The output field the engine derives for `node` over the input columns
    `schema`: what a projection of it declares in its node's output schema."""
    columns = columns_of(schema)
    check_columns(node, columns)
    return field_of(node, columns)
