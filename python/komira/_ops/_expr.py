"""Expression nodes: frozen, structurally comparable values built from tuples.

A node checks its own fields when it is built: the vocabulary an operator
belongs to, the Python type of each field and the arity. It does not know
column types, so nothing here derives a result type.
"""

from __future__ import annotations

import datetime
import decimal
import math
import struct
from dataclasses import dataclass

from komira._errors import UnsupportedOperation
from komira._ops import _dtype, _vocab


def _need_node(value, field, owner):
    if not isinstance(value, EXPR_NODES):
        raise TypeError(f"{owner}.{field} must be an expression node, not {type(value).__name__}")


def _need_name(value, field, owner):
    if not isinstance(value, str):
        raise TypeError(f"{owner}.{field} must be a str, not {type(value).__name__}")
    if value == "":
        raise ValueError(f"{owner}.{field} must not be empty")


def _need_str(value, field, owner):
    if not isinstance(value, str):
        raise TypeError(f"{owner}.{field} must be a str, not {type(value).__name__}")


def _need_op(op, vocab, owner):
    if not isinstance(op, str):
        raise TypeError(f"{owner} op must be a str, not {type(op).__name__}")
    if op not in vocab:
        raise ValueError(f"{owner} op {op!r} is not one of: " + ", ".join(sorted(vocab)))


def _need_dtype(value, owner):
    if not isinstance(value, str):
        raise TypeError(f"{owner} op must be a str, not {type(value).__name__}")
    spelled = _dtype.canonical(value, owner)
    if spelled != value:
        raise ValueError(f"{owner} {value!r} is not a canonical dtype; write {spelled!r}")


def _need_int(value, field, owner, minimum):
    if isinstance(value, bool) or not isinstance(value, int):
        raise TypeError(f"{owner}.{field} must be an int, not {type(value).__name__}")
    if minimum is not None and value < minimum:
        raise ValueError(f"{owner}.{field} must be at least {minimum}, not {value}")


def _need_tuple(value, field, owner):
    if not isinstance(value, tuple):
        raise TypeError(f"{owner}.{field} must be a tuple, not {type(value).__name__}")


@dataclass(frozen=True, slots=True)
class ColRef:
    """A column of the input frame, or of one side of a join when `side` is set."""

    name: str
    side: str | None = None

    def __post_init__(self):
        _need_name(self.name, "name", "ColRef")
        if self.side is not None and (
            not isinstance(self.side, str) or self.side not in _vocab.COL_SIDES
        ):
            raise ValueError(f"ColRef side {self.side!r} is not one of: left, right")


_LIT_TYPES = (
    bool,
    int,
    float,
    str,
    bytes,
    decimal.Decimal,
    datetime.date,
    datetime.datetime,
    datetime.time,
    datetime.timedelta,
)


def _lit_key(value):
    if isinstance(value, float):
        return (float, struct.pack("<d", value) if math.isnan(value) else value)
    if isinstance(value, decimal.Decimal) and value.is_nan():
        return (decimal.Decimal, repr(value))
    return (type(value), value)


@dataclass(frozen=True, slots=True, eq=False)
class Lit:
    """A constant. Equality tells `1`, `True` and `1.0` apart, and NaN equals NaN."""

    value: object

    def __post_init__(self):
        if self.value is not None and not isinstance(self.value, _LIT_TYPES):
            raise TypeError(f"Lit cannot hold a {type(self.value).__name__}")

    def __eq__(self, other):
        if other.__class__ is not Lit:
            return NotImplemented
        return _lit_key(self.value) == _lit_key(other.value)

    def __hash__(self):
        return hash(("Lit", _lit_key(self.value)))


@dataclass(frozen=True, slots=True)
class Compare:
    """A comparison of two values; the result is a predicate."""

    op: str
    left: "Node"
    right: "Node"

    def __post_init__(self):
        _need_op(self.op, _vocab.COMPARE_OPS, "Compare")
        _need_node(self.left, "left", "Compare")
        _need_node(self.right, "right", "Compare")


@dataclass(frozen=True, slots=True)
class Arith:
    """Arithmetic on two values."""

    op: str
    left: "Node"
    right: "Node"

    def __post_init__(self):
        _need_op(self.op, _vocab.ARITH_OPS, "Arith")
        _need_node(self.left, "left", "Arith")
        _need_node(self.right, "right", "Arith")


@dataclass(frozen=True, slots=True)
class BoolOp:
    """`and` / `or` of two predicates."""

    op: str
    left: "Node"
    right: "Node"

    def __post_init__(self):
        _need_op(self.op, _vocab.BOOL_OPS, "BoolOp")
        _need_node(self.left, "left", "BoolOp")
        _need_node(self.right, "right", "BoolOp")
        for side, x in (("left", self.left), ("right", self.right)):
            if not is_predicate(x):
                raise TypeError(
                    f"BoolOp {self.op} needs predicates, and its {side} operand is a "
                    f"{type(x).__name__}"
                )


@dataclass(frozen=True, slots=True)
class Unary:
    """A one-operand operator."""

    op: str
    child: "Node"

    def __post_init__(self):
        _need_op(self.op, _vocab.UNARY_OPS, "Unary")
        _need_node(self.child, "child", "Unary")
        if self.op == "not" and not is_predicate(self.child):
            raise TypeError(f"Unary not needs a predicate, not a {type(self.child).__name__}")


INT32_MIN, INT32_MAX = -(1 << 31), (1 << 31) - 1


@dataclass(frozen=True, slots=True)
class RoundDigits:
    """A value rounded to `digits` decimal places by the rule `op` names
    (`round`, `trunc` or `round_half_even`); a negative count rounds left of
    the point. `digits` is a plain int of the plan, within int32."""

    op: str
    child: "Node"
    digits: int

    def __post_init__(self):
        _need_op(self.op, _vocab.ROUND_DIGITS_OPS, "RoundDigits")
        _need_node(self.child, "child", "RoundDigits")
        _need_int(self.digits, "digits", "RoundDigits", None)
        if not INT32_MIN <= self.digits <= INT32_MAX:
            raise ValueError(f"RoundDigits.digits must be within int32, not {self.digits}")


@dataclass(frozen=True, slots=True)
class Cast:
    """A conversion to a primitive type, an Arrow type, or both.

    `target` is a primitive type name, or None when `arrow` alone names the
    type. `arrow` names an Arrow logical type; `precision` and `scale` are for a
    `decimal128` arrow type only. `try_cast` yields null instead of failing.
    """

    child: "Node"
    target: str | None
    try_cast: bool = False
    arrow: str | None = None
    precision: int = 0
    scale: int = 0

    def __post_init__(self):
        _need_node(self.child, "child", "Cast")
        if self.target is None:
            if self.arrow is None:
                raise ValueError("Cast needs a target or an arrow type")
        else:
            _need_op(self.target, _vocab.CAST_TARGETS, "Cast")
        if self.arrow is not None:
            _need_op(self.arrow, _vocab.ARROW_TYPES, "Cast arrow")
        if not isinstance(self.try_cast, bool):
            raise TypeError(f"Cast.try_cast must be a bool, not {type(self.try_cast).__name__}")
        _need_int(self.precision, "precision", "Cast", 0)
        _need_int(self.scale, "scale", "Cast", 0)
        if self.arrow == "decimal128":
            if self.precision < 1:
                raise ValueError("Cast to decimal128 needs a precision of at least 1")
        elif self.precision != 0 or self.scale != 0:
            raise ValueError("Cast precision and scale are for a decimal128 arrow type only")


@dataclass(frozen=True, slots=True)
class When:
    """Ordered (condition, result) cases and a default; the first match wins."""

    cases: tuple[tuple["Node", "Node"], ...]
    default: "Node"

    def __post_init__(self):
        _need_tuple(self.cases, "cases", "When")
        if not self.cases:
            raise ValueError("When needs at least one (condition, result) case")
        for i, case in enumerate(self.cases):
            if not isinstance(case, tuple) or len(case) != 2:
                raise TypeError(f"When case {i} must be a (condition, result) tuple")
            condition, result = case
            _need_node(condition, f"cases[{i}] condition", "When")
            _need_node(result, f"cases[{i}] result", "When")
            if not is_predicate(condition):
                raise TypeError(
                    f"When case {i}: the condition is a {type(condition).__name__}, "
                    "not a predicate"
                )
        _need_node(self.default, "default", "When")


@dataclass(frozen=True, slots=True)
class StringOp:
    """A string test against a literal pattern; the result is a predicate."""

    op: str
    child: "Node"
    pattern: str

    def __post_init__(self):
        _need_op(self.op, _vocab.STRING_OPS, "StringOp")
        _need_node(self.child, "child", "StringOp")
        _need_str(self.pattern, "pattern", "StringOp")


@dataclass(frozen=True, slots=True)
class Regexp:
    """A regular-expression operation on a string."""

    op: str
    child: "Node"
    pattern: str
    replacement: str = ""
    flags: str = ""
    group: int = 0

    def __post_init__(self):
        _need_op(self.op, _vocab.REGEXP_OPS, "Regexp")
        _need_node(self.child, "child", "Regexp")
        _need_str(self.pattern, "pattern", "Regexp")
        _need_str(self.replacement, "replacement", "Regexp")
        _need_str(self.flags, "flags", "Regexp")
        _need_int(self.group, "group", "Regexp", 0)
        if self.replacement != "" and self.op != "replace":
            raise ValueError(f"Regexp op {self.op!r} does not take a replacement")
        if self.group != 0 and self.op not in ("extract", "extract_all", "substr"):
            raise ValueError(f"Regexp op {self.op!r} does not take a group")


@dataclass(frozen=True, slots=True)
class StringFn:
    """A one-argument string function."""

    op: str
    child: "Node"

    def __post_init__(self):
        _need_op(self.op, _vocab.STRING_FNS, "StringFn")
        _need_node(self.child, "child", "StringFn")


@dataclass(frozen=True, slots=True)
class StringFnN:
    """A string function over several arguments."""

    op: str
    args: tuple["Node", ...]

    def __post_init__(self):
        _need_op(self.op, _vocab.STRING_FNS_N, "StringFnN")
        _need_tuple(self.args, "args", "StringFnN")
        if not self.args:
            raise ValueError("StringFnN needs at least one argument")
        for i, arg in enumerate(self.args):
            _need_node(arg, f"args[{i}]", "StringFnN")


@dataclass(frozen=True, slots=True)
class Substring:
    """A slice of a string from the 1-based `start`, `length` characters long."""

    child: "Node"
    start: int
    length: int | None = None

    def __post_init__(self):
        _need_node(self.child, "child", "Substring")
        _need_int(self.start, "start", "Substring", None)
        if self.length is not None:
            _need_int(self.length, "length", "Substring", 0)


@dataclass(frozen=True, slots=True)
class MathFn:
    """A one-argument math function."""

    op: str
    child: "Node"

    def __post_init__(self):
        _need_op(self.op, _vocab.MATH_FNS, "MathFn")
        _need_node(self.child, "child", "MathFn")


@dataclass(frozen=True, slots=True)
class MathFn2:
    """A two-argument math function."""

    op: str
    left: "Node"
    right: "Node"

    def __post_init__(self):
        _need_op(self.op, _vocab.MATH_FNS_2, "MathFn2")
        _need_node(self.left, "left", "MathFn2")
        _need_node(self.right, "right", "MathFn2")


@dataclass(frozen=True, slots=True)
class Extract:
    """A date or time part of a temporal value, or a truncation to it."""

    unit: str
    child: "Node"

    def __post_init__(self):
        _need_op(self.unit, _vocab.EXTRACT_UNITS, "Extract")
        _need_node(self.child, "child", "Extract")


@dataclass(frozen=True, slots=True)
class StructField:
    """A named field of a struct value."""

    parent: "Node"
    field: str

    def __post_init__(self):
        _need_node(self.parent, "parent", "StructField")
        _need_name(self.field, "field", "StructField")


@dataclass(frozen=True, slots=True)
class Alias:
    """An expression with an explicit output name."""

    child: "Node"
    name: str

    def __post_init__(self):
        _need_node(self.child, "child", "Alias")
        _need_name(self.name, "name", "Alias")
        if isinstance(self.child, Alias):
            raise ValueError("an Alias cannot wrap another Alias")


def _utf8_key(name):
    return name.encode("utf-8")


@dataclass(frozen=True, slots=True)
class UdfSpec:
    """A captured user function, as the plan names it: its call shape, where
    its code is, and its declared types. Built by komira._capture; nothing here
    reads code or hashes bytes.

    - `name`: the function's qualified name, for messages.
    - `kind`: one of `_vocab.UDF_KINDS`.
    - `form`, `entry`: how the komira/python runtime reaches the code
      (`"package"` or `"bundle"`) and its `"module:qualname"`.
    - `code`: `(role, sha256)` of every code object, the digest 32 bytes:
      one `("bundle", ...)` for a bundle, none for a package.
    - `return_type`: a canonical dtype text (`_dtype.canonical`, the spelling of
      the pyarrow type) for a column kind; for `map_batches_frame`, the output
      columns as `(name, dtype)` pairs.
    - `stability`, `null_mode`, `batch_format`: the declarations of
      `_vocab.UDF_STABILITIES`, `UDF_NULL_MODES` and `UDF_BATCH_FORMATS`.
    - `read_set`: the columns a `row` or `map_batches_frame` function reads,
      ascending by UTF-8 bytes, possibly empty; `None` for every other kind.
    """

    name: str
    kind: str
    form: str
    entry: str
    code: tuple
    return_type: object
    stability: str
    null_mode: str
    batch_format: str
    read_set: tuple | None = None

    def __post_init__(self):
        _need_name(self.name, "name", "UdfSpec")
        _need_op(self.kind, _vocab.UDF_KINDS, "UdfSpec kind")
        _need_op(self.form, _vocab.UDF_FORMS, "UdfSpec form")
        _need_name(self.entry, "entry", "UdfSpec")
        if self.entry.count(":") != 1 or "" in self.entry.split(":"):
            raise ValueError(f"UdfSpec.entry must be 'module:qualname', not {self.entry!r}")
        _need_tuple(self.code, "code", "UdfSpec")
        for item in self.code:
            if not (isinstance(item, tuple) and len(item) == 2 and isinstance(item[0], str) and item[0]):
                raise TypeError("UdfSpec.code holds (role, sha256) pairs with a non-empty role")
            if not isinstance(item[1], bytes) or len(item[1]) != 32:
                raise ValueError("UdfSpec.code digests are 32 bytes")
        if (self.form == "bundle") != (len(self.code) == 1 and self.code[0][0] == "bundle"):
            raise ValueError("UdfSpec.code is one ('bundle', sha256) for a bundle and empty for a package")
        if self.kind == "map_batches_frame":
            _need_tuple(self.return_type, "return_type", "UdfSpec")
            names = []
            for item in self.return_type:
                if not (isinstance(item, tuple) and len(item) == 2):
                    raise TypeError("UdfSpec.return_type of a frame holds (name, dtype) pairs")
                _need_name(item[0], "return_type name", "UdfSpec")
                _need_dtype(item[1], "UdfSpec return_type dtype")
                names.append(item[0])
            if not names:
                raise ValueError("UdfSpec.return_type of a frame names at least one column")
            if len(set(names)) != len(names):
                raise ValueError("UdfSpec.return_type of a frame repeats a column name")
        else:
            _need_dtype(self.return_type, "UdfSpec return_type")
        _need_op(self.stability, _vocab.UDF_STABILITIES, "UdfSpec stability")
        _need_op(self.null_mode, _vocab.UDF_NULL_MODES, "UdfSpec null_mode")
        _need_op(self.batch_format, _vocab.UDF_BATCH_FORMATS, "UdfSpec batch_format")
        if self.kind in _vocab.UDF_READ_SET_KINDS:
            if self.read_set is None:
                raise ValueError(f"UdfSpec.read_set is required for a {self.kind} function")
            _need_tuple(self.read_set, "read_set", "UdfSpec")
            for name in self.read_set:
                _need_name(name, "read_set name", "UdfSpec")
            if list(self.read_set) != sorted(set(self.read_set), key=_utf8_key):
                raise ValueError("UdfSpec.read_set must ascend by UTF-8 bytes with no repeats")
        elif self.read_set is not None:
            raise ValueError(f"UdfSpec.read_set is only for a row or map_batches_frame function, not {self.kind}")


@dataclass(frozen=True, slots=True)
class UdfCall:
    """A call of a column-kind user function (`scalar`, `map_batches_column`
    or `row`) on argument expressions. A `row` call's arguments are its read
    set's columns, in the set's order."""

    udf: UdfSpec
    args: tuple

    def __post_init__(self):
        if not isinstance(self.udf, UdfSpec):
            raise TypeError(f"UdfCall.udf must be a UdfSpec, not {type(self.udf).__name__}")
        if self.udf.kind not in _vocab.UDF_COLUMN_KINDS:
            raise ValueError(f"UdfCall calls a column function, and {self.udf.name} is a {self.udf.kind} function")
        _need_tuple(self.args, "args", "UdfCall")
        for arg in self.args:
            _need_node(arg, "args", "UdfCall")
        if self.udf.kind == "row":
            if self.args != tuple(ColRef(c) for c in self.udf.read_set):
                raise ValueError(f"UdfCall of the row function {self.udf.name} passes exactly its read set's columns")
        elif not self.args:
            raise ValueError(f"UdfCall of {self.udf.name} takes at least one argument")


Node = (
    ColRef
    | Lit
    | Compare
    | Arith
    | BoolOp
    | Unary
    | RoundDigits
    | Cast
    | When
    | StringOp
    | Regexp
    | StringFn
    | StringFnN
    | Substring
    | MathFn
    | MathFn2
    | Extract
    | StructField
    | Alias
    | UdfCall
)

EXPR_NODES = (
    ColRef,
    Lit,
    Compare,
    Arith,
    BoolOp,
    Unary,
    RoundDigits,
    Cast,
    When,
    StringOp,
    Regexp,
    StringFn,
    StringFnN,
    Substring,
    MathFn,
    MathFn2,
    Extract,
    StructField,
    Alias,
    UdfCall,
)


def is_predicate(node) -> bool:
    """True when `node` is known to produce a boolean (or is a boolean or null literal)."""
    if isinstance(node, (Compare, BoolOp, StringOp)):
        return True
    if isinstance(node, Regexp):
        return node.op in _vocab.PREDICATE_REGEXP_OPS
    if isinstance(node, Unary):
        return node.op in _vocab.PREDICATE_UNARY_OPS
    if isinstance(node, Lit):
        return node.value is None or isinstance(node.value, bool)
    if isinstance(node, Alias):
        return is_predicate(node.child)
    return False


def as_node(value) -> Node:
    """`value` itself when it is a node, otherwise `Lit(value)`."""
    if isinstance(value, EXPR_NODES):
        return value
    return Lit(value)


def _chain(op, preds):
    result = preds[0]
    for pred in preds[1:]:
        result = BoolOp(op, result, pred)
    return result


def and_all(preds: tuple[Node, ...]) -> Node | None:
    """The predicates joined by `and`, left to right; None when there are none."""
    return _chain("and", preds) if preds else None


def or_all(preds: tuple[Node, ...]) -> Node | None:
    """The predicates joined by `or`, left to right; None when there are none."""
    return _chain("or", preds) if preds else None


def is_in(child: Node, values) -> Node:
    """`child` equals any of `values`, as an `or` chain of comparisons."""
    _need_node(child, "child", "is_in")
    if not isinstance(values, (list, tuple)):
        raise TypeError(f"is_in values must be a list or tuple, not {type(values).__name__}")
    if len(values) > _vocab.IN_LIST_MAX:
        raise UnsupportedOperation(
            f"is_in takes at most {_vocab.IN_LIST_MAX} values, and was given "
            f"{len(values)}; filter with a join instead"
        )
    if not values:
        return Lit(False)
    return _chain("or", tuple(Compare("eq", child, as_node(v)) for v in values))


_BETWEEN = {
    "both": ("ge", "le"),
    "left": ("ge", "lt"),
    "right": ("gt", "le"),
    "none": ("gt", "lt"),
}


def between(child: Node, lower, upper, closed: str = "both") -> Node:
    """`child` lies between `lower` and `upper`; `closed` says which ends count."""
    if closed not in _BETWEEN:
        raise ValueError(f"between closed {closed!r} is not one of: both, left, right, none")
    low_op, high_op = _BETWEEN[closed]
    return BoolOp(
        "and",
        Compare(low_op, child, as_node(lower)),
        Compare(high_op, child, as_node(upper)),
    )


def output_name(node: Node) -> str | None:
    """The name a node carries as a result column: an alias or a column name."""
    if isinstance(node, (Alias, ColRef)):
        return node.name
    return None
