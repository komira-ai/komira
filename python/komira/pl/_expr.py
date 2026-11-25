"""`Expr`, the polars-shaped expression, and the functions that make one:
`col`, `lit`, `when` and `len`.

An `Expr` names columns but no frame. It holds how to lower itself to a node of
the private tree (komira._ops) against a frame's `Scope`, the output name
polars gives it, and whether it holds an aggregate. A verb of `LazyFrame`
lowers it; nothing here builds or reads SQL text.

The output name is polars' (rules section 8, ruling 12): an alias, else the
name of the leftmost column or function of the expression, `literal` for a
literal and `len` for `len()`.

The types are polars 1.44.2's where the engine can give them (komira/pl/
_types.py): a sum keeps polars' type for a signed or a float input, `mean`,
`median`, `std` and `var` of a Float32 are Float32, an int literal beside an
Int32 column is an Int32, and a bare int literal is an Int32. A count, `len()`
and `str.len_chars()` are Int64 where polars gives UInt32, as is the sum of a
boolean or a UInt32 column. The sum of no values is 0 (ruling 10). `/` is true
division, and `//` and `%` floor as Python does (ruling 9).
"""

from __future__ import annotations

import builtins
import datetime
import decimal

from komira._errors import UnsupportedOperation
from komira._ops import (
    Agg,
    Arith,
    BoolOp,
    Cast,
    ColRef,
    Compare,
    Lit,
    MathFn,
    Node,
    StringFn,
    StringOp,
    Unary,
    When,
    between,
    is_in,
)

from . import _names, _types

__all__ = ["Expr", "ExprStringNameSpace", "col", "len", "lit", "when"]

_LITERALS = (
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

# The dtype names a dtype argument takes (dataframe_surface_verbs.md, "dtypes"),
# each the Cast it builds: a primitive target, or an Arrow type alone.
_CAST_NUMERIC = frozenset(
    {
        "bool",
        "int8",
        "int16",
        "int32",
        "int64",
        "uint8",
        "uint16",
        "uint32",
        "uint64",
        "float32",
        "float64",
    }
)
_CAST_ARROW = frozenset({"string", "binary", "date32"})
# pyarrow's `str()` of a type, where it is not the dtype name.
_PYARROW_SPELLING = {"float": "float32", "double": "float64", "date32[day]": "date32"}

# The sum of each input type: (the type the argument is summed as, polars'
# type of the sum). The plan sums a signed integer or a boolean as INT64 and a
# float as FLOAT64; an unsigned integer is widened to INT64 first, since the
# engine's UINT64 sum cannot be coalesced. polars' UInt32 (a boolean's or a
# UInt32's sum) is Int64 here (komira/pl/_types.py).
_SUMS = {
    "bool": (None, "int64"),
    "int8": (None, "int64"),
    "int16": (None, "int64"),
    "int32": (None, "int32"),
    "int64": (None, "int64"),
    "uint8": ("int64", "int64"),
    "uint16": ("int64", "int64"),
    "uint32": ("int64", "int64"),
    "float32": (None, "float32"),
    "float64": (None, "float64"),
}

_STATISTICS = {
    "mean": "mean",
    "median": "median",
    "std": "stddev_samp",
    "var": "var_samp",
}


def _lower_value(value: object, scope) -> Node:
    """An `Expr`'s node, or a literal's."""
    if isinstance(value, Expr):
        return value._lower(scope)
    return Lit(_literal(value))


def _literal(value: object) -> object:
    if value is not None and not isinstance(value, _LITERALS):
        raise TypeError(
            f"a literal must be None, bool, int, float, str, bytes, a Decimal or a "
            f"date, time or timedelta, not {type(value).__name__}"
        )
    return value


def _as_expr(value: object) -> Expr:
    """`value` itself when it is an `Expr`, else `lit(value)`. A `str` is a
    literal, as polars reads it in an operator."""
    if isinstance(value, Expr):
        return value
    return lit(value)


def _dtype_name(dtype: object, verb: str) -> str:
    """The dtype name of a dtype argument: one of the names, or a
    `pyarrow.DataType` of one of those types (rules section 8, ruling 14)."""
    if isinstance(dtype, str):
        name = dtype
    elif type(dtype).__module__.split(".")[0] == "pyarrow":
        name = str(dtype)
        name = _PYARROW_SPELLING.get(name, name)
    else:
        raise TypeError(
            f"{verb}: a dtype is a pyarrow.DataType or a dtype name, not {type(dtype).__name__}"
        )
    if name not in _CAST_NUMERIC and name not in _CAST_ARROW:
        raise UnsupportedOperation(
            f"{verb}: the dtype {name!r} is not supported; use one of: "
            + ", ".join(sorted(_CAST_NUMERIC | _CAST_ARROW))
        )
    return name


def _cast(node: Node, name: str, try_cast: bool = False) -> Cast:
    if name in _CAST_NUMERIC:
        return Cast(node, name, try_cast)
    return Cast(node, None, try_cast, arrow=name)


def _sign_differs(r: Node, b: Node) -> Node | None:
    """The predicate that the remainder `r` of a division by `b` is not 0 and
    has the other sign from `b`, or None when it never holds (`b` the literal
    0, by which the remainder is null or NaN). A literal divisor's sign is
    read here; no two predicates are compared, which the engine does not do."""
    zero = Lit(0)
    if isinstance(b, Lit):
        if b.value is None:
            return None
        if b.value > 0:
            return Compare("lt", r, zero)
        if b.value < 0:
            return Compare("gt", r, zero)
        return None
    return BoolOp(
        "or",
        BoolOp("and", Compare("lt", r, zero), Compare("gt", b, zero)),
        BoolOp("and", Compare("gt", r, zero), Compare("lt", b, zero)),
    )


def _correction(r: Node, b: Node, then: Node, otherwise: Node) -> Node | None:
    """`then` where `r` and `b` differ in sign (`_sign_differs`), else
    `otherwise`; None when they never do."""
    differs = _sign_differs(r, b)
    if differs is None:
        return None
    return When(((differs, then),), otherwise)


class Expr:
    """A polars-shaped expression: a column, a literal, an operator over
    expressions, a function of one, or an aggregate. Built by `col`, `lit`,
    `when` and `len` and by the operators and methods of an `Expr`; lowered
    by the `LazyFrame` verb it is given to.

    An `Expr` has no truth value: `and`, `or`, `not` and `if` raise
    `TypeError`; write `&`, `|` and `~`.
    """

    __slots__ = ("_lower_fn", "_name", "_has_agg")

    def __init__(self, lower, name: str, has_agg: bool) -> None:
        object.__setattr__(self, "_lower_fn", lower)
        object.__setattr__(self, "_name", name)
        object.__setattr__(self, "_has_agg", has_agg)

    # ---- the attribute rule (rules section 5) --------------------------------

    def __getattr__(self, name: str):
        raise _names.missing("Expr", name)

    def __setattr__(self, name: str, value: object) -> None:
        if name.startswith("_"):
            object.__setattr__(self, name, value)
            return
        raise AttributeError(
            f"cannot set the attribute '{name}' of an Expr: an Expr is immutable; "
            "build a new one with its methods"
        )

    def __bool__(self) -> bool:
        raise TypeError(
            "the truth value of an Expr is ambiguous: combine predicates with & and | "
            "and negate one with ~, not with and, or and not"
        )

    def __repr__(self) -> str:
        return f"<komira.pl.Expr '{self._name}'>"

    # ---- building ----------------------------------------------------------------

    def _lower(self, scope) -> Node:
        return self._lower_fn(scope)

    def _unary(self, build, name: str | None = None) -> Expr:
        inner = self
        return Expr(lambda s: build(inner._lower(s), s), self._name if name is None else name, self._has_agg)

    def _binary(self, other: object, build, *, reflected: bool = False) -> Expr:
        right = _as_expr(other)
        left = self
        if reflected:
            left, right = right, left
        a, b = left, right
        return Expr(lambda s: build(a._lower(s), b._lower(s), s), a._name, a._has_agg or b._has_agg)

    def _no_agg(self, verb: str) -> None:
        if self._has_agg:
            raise UnsupportedOperation(
                f"{verb}: '{self._name}' is already an aggregate; an aggregate of an aggregate is not supported"
            )

    # ---- comparisons ----------------------------------------------------------------

    def __eq__(self, other: object) -> Expr:  # type: ignore[override]
        return self._binary(other, lambda a, b, s: Compare("eq", a, b))

    def __ne__(self, other: object) -> Expr:  # type: ignore[override]
        return self._binary(other, lambda a, b, s: Compare("ne", a, b))

    def __lt__(self, other: object) -> Expr:
        return self._binary(other, lambda a, b, s: Compare("lt", a, b))

    def __le__(self, other: object) -> Expr:
        return self._binary(other, lambda a, b, s: Compare("le", a, b))

    def __gt__(self, other: object) -> Expr:
        return self._binary(other, lambda a, b, s: Compare("gt", a, b))

    def __ge__(self, other: object) -> Expr:
        return self._binary(other, lambda a, b, s: Compare("ge", a, b))

    __hash__ = None  # type: ignore[assignment]

    # ---- boolean operators -------------------------------------------------------

    def __and__(self, other: object) -> Expr:
        return self._binary(
            other, lambda a, b, s: BoolOp("and", s.predicate(a, "&"), s.predicate(b, "&"))
        )

    def __rand__(self, other: object) -> Expr:
        return self._binary(
            other,
            lambda a, b, s: BoolOp("and", s.predicate(a, "&"), s.predicate(b, "&")),
            reflected=True,
        )

    def __or__(self, other: object) -> Expr:
        return self._binary(
            other, lambda a, b, s: BoolOp("or", s.predicate(a, "|"), s.predicate(b, "|"))
        )

    def __ror__(self, other: object) -> Expr:
        return self._binary(
            other,
            lambda a, b, s: BoolOp("or", s.predicate(a, "|"), s.predicate(b, "|")),
            reflected=True,
        )

    def __invert__(self) -> Expr:
        return self._unary(lambda a, s: Unary("not", s.predicate(a, "~")))

    def not_(self) -> Expr:
        """The negation of a boolean expression, as `~`."""
        return ~self

    # ---- arithmetic -------------------------------------------------------------------

    def __add__(self, other: object) -> Expr:
        return self._binary(other, _plain("add"))

    def __radd__(self, other: object) -> Expr:
        return self._binary(other, _plain("add"), reflected=True)

    def __sub__(self, other: object) -> Expr:
        return self._binary(other, _plain("sub"))

    def __rsub__(self, other: object) -> Expr:
        return self._binary(other, _plain("sub"), reflected=True)

    def __mul__(self, other: object) -> Expr:
        return self._binary(other, _plain("mul"))

    def __rmul__(self, other: object) -> Expr:
        return self._binary(other, _plain("mul"), reflected=True)

    def __truediv__(self, other: object) -> Expr:
        return self._binary(other, _true_div)

    def __rtruediv__(self, other: object) -> Expr:
        return self._binary(other, _true_div, reflected=True)

    def __floordiv__(self, other: object) -> Expr:
        return self._binary(other, _floor_div)

    def __rfloordiv__(self, other: object) -> Expr:
        return self._binary(other, _floor_div, reflected=True)

    def __mod__(self, other: object) -> Expr:
        return self._binary(other, _modulo)

    def __rmod__(self, other: object) -> Expr:
        return self._binary(other, _modulo, reflected=True)

    def __neg__(self) -> Expr:
        return self._unary(lambda a, s: Unary("negate", a))

    def __pos__(self) -> Expr:
        return self

    def abs(self) -> Expr:
        """The absolute value."""
        return self._unary(lambda a, s: Unary("abs", a))

    # ---- naming and types --------------------------------------------------------------

    def alias(self, name: str) -> Expr:
        """The same expression under the output name `name`."""
        if not isinstance(name, str):
            raise TypeError(f"alias: the name must be a str, not {type(name).__name__}")
        if name == "":
            raise ValueError("alias: the name must not be empty")
        return Expr(self._lower_fn, name, self._has_agg)

    def cast(self, dtype: object, *, strict: bool = True) -> Expr:
        """The value as `dtype` (a dtype name or a `pyarrow.DataType`). With
        `strict=False` a value that does not convert is null; with the default
        it fails the query. A float becomes an integer by truncation, as in
        polars. The casts supported are among int32, int64, float32, float64
        and string, and from a narrower integer to one of those numbers; any
        other is refused at the verb."""
        if not isinstance(strict, bool):
            raise TypeError(f"cast: strict must be a bool, not {type(strict).__name__}")
        name = _dtype_name(dtype, "cast")
        return self._unary(lambda a, s: _checked_cast(a, s, name, not strict))

    # ---- missing values ---------------------------------------------------------------

    def is_null(self) -> Expr:
        """Whether the value is null. A NaN is not null (rules section 8, ruling 6)."""
        return self._unary(lambda a, s: Unary("is_null", a))

    def is_not_null(self) -> Expr:
        """Whether the value is not null."""
        return self._unary(lambda a, s: Unary("is_not_null", a))

    def fill_null(self, value: object = None, strategy: object = None, limit: object = None) -> Expr:
        """The value, or `value` where it is null. A `strategy` or a `limit`,
        which fill from neighbouring rows, are refused: a frame has no row order
        to fill by."""
        if strategy is not None or limit is not None:
            raise UnsupportedOperation(
                "fill_null: strategy= and limit= fill from neighbouring rows, which a "
                "plan does not order; fill with a value: fill_null(value)"
            )
        if value is None:
            raise TypeError("fill_null needs a value")
        fill = _as_expr(value)
        inner = self
        return Expr(
            lambda s: _fill(inner._lower(s), fill._lower(s), s),
            self._name,
            self._has_agg or fill._has_agg,
        )

    # ---- membership ---------------------------------------------------------------

    def is_in(self, other: object) -> Expr:
        """Whether the value equals one of the values of the list or tuple
        `other` (at most 64); a null value is never in it."""
        if not isinstance(other, (list, tuple)):
            raise UnsupportedOperation(
                f"is_in takes a list or tuple of values, not {type(other).__name__}"
            )
        values = tuple(_literal(v) for v in other)
        return self._unary(lambda a, s: is_in(a, values))

    def is_between(self, lower_bound: object, upper_bound: object, closed: str = "both") -> Expr:
        """Whether the value lies between the bounds; `closed` (`both`, `left`,
        `right` or `none`) says which bounds count."""
        if closed not in ("both", "left", "right", "none"):
            raise ValueError(f"is_between: closed {closed!r} is not one of: both, left, right, none")
        lo, hi = _as_expr(lower_bound), _as_expr(upper_bound)
        inner = self
        return Expr(
            lambda s: between(inner._lower(s), lo._lower(s), hi._lower(s), closed),
            self._name,
            self._has_agg or lo._has_agg or hi._has_agg,
        )

    # ---- aggregates ---------------------------------------------------------------

    def _aggregate(self, verb: str, build) -> Expr:
        """An aggregate of this expression: `build(arg, arg_type)` gives the
        `Agg` and the node polars' answer is over the aggregate's reference."""
        self._no_agg(verb)
        inner, name = self, self._name

        def lower(scope):
            row = scope.row()
            arg = inner._lower(row)
            agg, finish = build(arg, row.arrow_type(arg))
            return finish(scope.aggregate(agg, name))

        return Expr(lower, name, True)

    def sum(self) -> Expr:
        """The sum, 0 over no values, in polars' type for the input's (Int64
        where polars gives UInt32). The sum of a UInt64, a decimal or any other
        type is not supported yet."""

        def build(arg, found):
            if found not in _SUMS:
                raise UnsupportedOperation(
                    f"sum of a column of type {found} is not supported yet"
                )
            widen, final = _SUMS[found]
            work = "float64" if final.startswith("float") else "int64"

            def finish(ref):
                zero = Lit(0.0) if work == "float64" else Lit(0)
                total = When(((Unary("is_null", ref), zero),), ref)
                return _types.finish(total, work, final)

            return Agg("sum", (arg if widen is None else Cast(arg, widen),)), finish

        return self._aggregate("sum", build)

    def min(self) -> Expr:
        """The smallest value; null over no values."""
        return self._aggregate("min", lambda arg, found: (Agg("min", (arg,)), _same))

    def max(self) -> Expr:
        """The largest value; null over no values."""
        return self._aggregate("max", lambda arg, found: (Agg("max", (arg,)), _same))

    def count(self) -> Expr:
        """The number of values that are not null, an Int64 (polars: UInt32)."""
        return self._aggregate("count", lambda arg, found: (Agg("count", (arg,)), _same))

    def n_unique(self) -> Expr:
        """The number of distinct values, an Int64 (polars: UInt32). A null
        counts as one value, as polars counts it."""
        self._no_agg("n_unique")
        inner, name = self, self._name

        def lower(scope):
            arg = inner._lower(scope.row())
            distinct = scope.aggregate(Agg("count_distinct", (arg,)), name)
            nulls = scope.aggregate(Agg("count_if", (Unary("is_null", arg),)), name)
            extra = When(((Compare("gt", nulls, Lit(0)), Lit(1)),), Lit(0))
            return Arith("add", distinct, extra)

        return Expr(lower, name, True)

    def _statistic(self, verb: str, ddof: object = None) -> Expr:
        if ddof is not None and (isinstance(ddof, bool) or ddof != 1):
            raise UnsupportedOperation(f"{verb}: ddof={ddof!r} is not supported; only ddof=1 is")

        def build(arg, found):
            finish = (lambda ref: Cast(ref, "float32")) if found == "float32" else _same
            return Agg(_STATISTICS[verb], (arg,)), finish

        return self._aggregate(verb, build)

    def mean(self) -> Expr:
        """The mean; null over no values."""
        return self._statistic("mean")

    def median(self) -> Expr:
        """The median; null over no values."""
        return self._statistic("median")

    def std(self, ddof: int = 1) -> Expr:
        """The sample standard deviation (`ddof=1`)."""
        return self._statistic("std", ddof)

    def var(self, ddof: int = 1) -> Expr:
        """The sample variance (`ddof=1`)."""
        return self._statistic("var", ddof)

    # ---- namespaces ------------------------------------------------------------

    @property
    def str(self) -> ExprStringNameSpace:
        """The string functions of this expression."""
        return ExprStringNameSpace(self)


def _same(ref: Node) -> Node:
    return ref


def _case(cases: tuple, default: Node, scope, verb: str) -> Node:
    """A `When` of `cases` ((predicate, value) pairs) and `default`, every
    value computed in the work type and the whole cast to polars' type
    (komira/pl/_types.py)."""
    values = [v for _, v in cases] + [default]
    kinds = [_types.kind(v, scope) for v in values]
    work, final = _types.case_types(kinds, verb)
    worked = [_types.to_work(v, k, work) for v, k in zip(values, kinds)]
    built = When(tuple((c, w) for (c, _), w in zip(cases, worked)), worked[-1])
    return _types.finish(built, work, final)


def _fill(value: Node, fill: Node, scope) -> Node:
    return _case(((Unary("is_null", value), fill),), value, scope, "fill_null")


def _plain(op: str):
    """`a <op> b` for `+`, `-` and `*`: a dynamic literal beside an Int32 or
    Float32 column takes the column's type, as in polars."""

    def build(a: Node, b: Node, scope) -> Node:
        ka, kb = _types.kind(a, scope), _types.kind(b, scope)
        return Arith(op, _narrowed(a, ka, kb), _narrowed(b, kb, ka))

    return build


def _narrowed(node: Node, k: str, other: str) -> Node:
    """A dynamic literal `node` beside a column of type `other`, as polars
    types it: an Int32 or Float32 beside one."""
    if k == _types.DYN_INT and other == "int32":
        return Cast(node, "int32")
    if k == _types.DYN_INT and other == "float32":
        return Cast(Lit(float(node.value)), "float32")
    if k == _types.DYN_FLOAT and other == "float32":
        return Cast(node, "float32")
    return node


def _numbers(a: Node, b: Node, scope, verb: str) -> tuple[str, str, str]:
    """(kind of a, kind of b, polars' result type) of an arithmetic operator
    over two numbers; `UnsupportedOperation` for another type."""
    ka, kb = _types.kind(a, scope), _types.kind(b, scope)
    for k in (ka, kb):
        if k not in _types.NUM4 and k not in (_types.DYN_INT, _types.DYN_FLOAT):
            raise UnsupportedOperation(
                f"{verb} needs numbers (int32, int64, float32, float64), and an operand is of type {k}"
            )
    _, final = _types.case_types([ka, kb], verb)
    return ka, kb, final


def _true_div(a: Node, b: Node, scope) -> Node:
    """`a / b` as true division: both operands as Float64, unless both are
    Float32 (or a Float32 and a literal), which polars divides as Float32."""
    ka, kb, final = _numbers(a, b, scope, "/")
    if final == "float32":
        return Arith("div", _narrowed(a, ka, kb), _narrowed(b, kb, ka))
    return Arith("div", _as_float64(a, ka), _as_float64(b, kb))


def _as_float64(node: Node, k: str) -> Node:
    if k == "float64" or k == _types.DYN_FLOAT:
        return node
    if k == _types.DYN_INT:
        return Lit(float(node.value))
    return Cast(node, "float64")


def _floor_div(a: Node, b: Node, scope) -> Node:
    """`a // b`, floored: over integers (computed as Int64) the plan's
    truncating quotient minus one where the remainder has the other sign from
    `b`; over floats the floor of the true quotient."""
    ka, kb, final = _numbers(a, b, scope, "//")
    if final.startswith("float"):
        return MathFn("floor", _true_div(a, b, scope))
    a64, b64 = _types.to_work(a, ka, "int64"), _types.to_work(b, kb, "int64")
    q = Arith("div", a64, b64)
    step = _correction(Arith("mod", a64, b64), b64, Lit(1), Lit(0))
    out = q if step is None else Arith("sub", q, step)
    return _types.finish(out, "int64", final)


def _modulo(a: Node, b: Node, scope) -> Node:
    """`a % b` with the sign of `b`: the plan's truncating remainder plus `b`
    where the remainder has the other sign from `b`, computed as Int64 or
    Float64."""
    ka, kb, final = _numbers(a, b, scope, "%")
    if final.startswith("float"):
        work = "float64"
        aw, bw = _as_float64(a, ka), _as_float64(b, kb)
    else:
        work = "int64"
        aw, bw = _types.to_work(a, ka, work), _types.to_work(b, kb, work)
    r = Arith("mod", aw, bw)
    zero = Lit(0.0) if work == "float64" else Lit(0)
    step = _correction(r, bw, bw, zero)
    out = r if step is None else Arith("add", r, step)
    return _types.finish(out, work, final)


def _checked_cast(node: Node, scope, target: str, try_cast: bool) -> Node:
    """`node` cast to `target`, when the engine runs that cast."""
    source = scope.arrow_type(node)
    numbers = _types.NUM4
    if source == target:
        return node
    if source in numbers and target in numbers:
        if source.startswith("float") and target.startswith("int"):
            return _cast(Unary("trunc", node), target, try_cast)
        return _cast(node, target, try_cast)
    if source in _types.SMALL_INTEGERS and target in numbers and not (
        source == "uint32" and target == "int32"
    ):
        return _cast(node, target, try_cast)
    if (source in numbers and target == "string") or (source in _types.STRINGS and target in numbers):
        return _cast(node, target, try_cast)
    raise UnsupportedOperation(f"cast: a cast from {source} to {target} is not supported yet")


class ExprStringNameSpace:
    """The string functions of an `Expr`, as `expr.str`."""

    __slots__ = ("_expr",)

    def __init__(self, expr: Expr) -> None:
        object.__setattr__(self, "_expr", expr)

    def __getattr__(self, name: str):
        raise _names.missing("ExprStringNameSpace", name)

    def __setattr__(self, name: str, value: object) -> None:
        if name.startswith("_"):
            object.__setattr__(self, name, value)
            return
        raise AttributeError(f"cannot set the attribute '{name}' of a string namespace")

    def to_lowercase(self) -> Expr:
        """The string in lower case."""
        return self._expr._unary(lambda a, s: StringFn("lower", a))

    def to_uppercase(self) -> Expr:
        """The string in upper case."""
        return self._expr._unary(lambda a, s: StringFn("upper", a))

    def len_chars(self) -> Expr:
        """The number of characters, an Int64 (polars: UInt32)."""
        return self._expr._unary(lambda a, s: StringFn("length", a))

    def starts_with(self, prefix: str) -> Expr:
        """Whether the string starts with the text `prefix`."""
        _need_text("str.starts_with", "prefix", prefix)
        return self._expr._unary(lambda a, s: StringOp("starts_with", a, prefix))

    def ends_with(self, suffix: str) -> Expr:
        """Whether the string ends with the text `suffix`."""
        _need_text("str.ends_with", "suffix", suffix)
        return self._expr._unary(lambda a, s: StringOp("ends_with", a, suffix))

    def contains(self, pattern: str, *, literal: bool = False, strict: bool = True) -> Expr:
        """Whether the string contains the text `pattern`. Only `literal=True`
        is supported: a regular expression is not yet."""
        _need_text("str.contains", "pattern", pattern)
        if literal is not True:
            raise UnsupportedOperation(
                "str.contains: a regular expression pattern is not supported yet; "
                "match the text itself with str.contains(pattern, literal=True)"
            )
        return self._expr._unary(lambda a, s: StringOp("contains", a, pattern))


def _need_text(verb: str, what: str, value: object) -> None:
    if not isinstance(value, builtins.str):
        raise TypeError(f"{verb}: {what} must be a str, not {type(value).__name__}")


def col(name: str) -> Expr:
    """The column `name` of the frame the expression is given to. One name: a
    list, a wildcard or a dtype selector is not supported yet."""
    if not isinstance(name, str):
        raise UnsupportedOperation(
            f"col() takes one column name, a str, not {type(name).__name__}; "
            "name each column with its own col()"
        )
    if name == "*" or (name.startswith("^") and name.endswith("$")):
        raise UnsupportedOperation(
            f"col({name!r}) selects columns by pattern, which is not supported yet; "
            "name each column with its own col()"
        )
    return Expr(lambda s: s.column(name), name, False)


def lit(value: object) -> Expr:
    """The constant `value`, named `literal`. An int is an Int32 where it is a
    column of its own, as in polars, and takes the type of a column beside it."""
    if isinstance(value, Expr):
        return value
    constant = Lit(_literal(value))
    return Expr(lambda s: constant, "literal", False)


def len() -> Expr:  # noqa: A001 - polars' own name
    """The number of rows, an Int64 (polars: UInt32), named `len`."""

    def lower(scope):
        return scope.aggregate(Agg("count"), "len")

    return Expr(lower, "len", True)


def when(condition: object) -> When_:
    """The first branch of `when(...).then(...).otherwise(...)`: the value of
    the first `then` whose condition holds, else the `otherwise` value."""
    return When_((), _as_condition(condition))


def _as_condition(condition: object) -> Expr:
    if not isinstance(condition, Expr):
        raise TypeError(f"when: the condition must be an Expr, not {type(condition).__name__}")
    return condition


class When_:
    """`when(condition)` before its `then`."""

    __slots__ = ("_cases", "_condition")

    def __init__(self, cases: tuple, condition: Expr) -> None:
        object.__setattr__(self, "_cases", cases)
        object.__setattr__(self, "_condition", condition)

    def __getattr__(self, name: str):
        raise _names.missing("When", name)

    def then(self, value: object) -> Then:
        """The value where the condition holds."""
        return Then(self._cases + ((self._condition, _as_expr(value)),))


class Then:
    """`when(...).then(...)`: needs `otherwise`, or another `when`."""

    __slots__ = ("_cases",)

    def __init__(self, cases: tuple) -> None:
        object.__setattr__(self, "_cases", cases)

    def __getattr__(self, name: str):
        if not name.startswith("_") and hasattr(Expr, name):
            raise AttributeError(
                f"when(...).then(...) needs .otherwise(value) before .{name}(): "
                "say what the rows no condition holds for are"
            )
        raise _names.missing("Then", name)

    def when(self, condition: object) -> When_:
        """The next branch, tried when no earlier condition holds."""
        return When_(self._cases, _as_condition(condition))

    def otherwise(self, value: object) -> Expr:
        """The value where no condition holds: the finished expression, named
        after the first `then` value. The values are numbers or strings, in
        polars' common type of them; boolean values are not supported yet."""
        cases = self._cases
        default = _as_expr(value)
        has_agg = default._has_agg or any(c._has_agg or v._has_agg for c, v in cases)

        def lower(scope):
            built = tuple(
                (scope.predicate(c._lower(scope), "when"), v._lower(scope)) for c, v in cases
            )
            return _case(built, default._lower(scope), scope, "when")

        return Expr(lower, cases[0][1]._name, has_agg)
