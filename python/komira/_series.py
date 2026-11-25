"""`Series`: a column of a pandas-shaped `DataFrame`, or an expression over its
columns (docs/design/dataframe_surface.md).

A Series is bound to the frame it was taken from, and to that frame's plan at
the time: it holds an expression node of the private node tree (komira/_ops)
over the frame's columns and the field the engine derives for it. It runs
nothing. It is used inside its own frame's verbs: `df[s]` filters by it and
`df.assign(name=s)` and `df["name"] = s` make a column of it.

- A Series of another frame, or of a frame whose plan `df["x"] = ...` replaced
  after the Series was taken (a stale one), raises `UnsupportedOperation` where
  it is used: a frame has no index to align two plans by.
- Operators build expressions: comparisons, `+ - * /` (true division: the left
  operand of an integer division is cast to float64, as Python divides), unary
  `-`, and `& | ~` over boolean Series. `isin` takes a list of values.
- Numeric operands of an operator or a comparison are widened to one type
  first, as SQL's binder widens them, since the plan door runs the plan as
  given: integers to the wider integer type (a signed and an unsigned one to
  the next signed type that holds both), and an integer or a float32 meeting a
  float64 to float64. An int literal takes the integer type of the other
  operand when its value fits that type, as SQL types a literal by its value:
  so `s * 2` and `2 * s` have the type of an int32 `s`. The engine's
  arithmetic runs on int64 and float64, so an operator over a narrower type
  is computed there and cast back to that type.
- No dunder runs a query: `bool`, `len`, `iter`, `__array__` and the Arrow
  stream raise `UnsupportedOperation`. A name the class does not define raises
  `AttributeError` (komira/_refusals.py), and no attribute can be set.
"""

from __future__ import annotations

from typing import TYPE_CHECKING

from . import _ops, _refusals
from ._errors import UnsupportedOperation

if TYPE_CHECKING:
    from ._frame import DataFrame

__all__ = ["Series", "operand"]

# The Arrow types of the integer columns (komira/_ops/_vocab.py names), each
# with its rank: 1 for 8 bits up to 4 for 64.
_SIGNED = {"int8": 1, "int16": 2, "int32": 3, "int64": 4}
_UNSIGNED = {"uint8": 1, "uint16": 2, "uint32": 3, "uint64": 4}
_SIGNED_OF_RANK = {rank: name for name, rank in _SIGNED.items()}
_INTEGERS = frozenset(_SIGNED) | frozenset(_UNSIGNED)
_FLOATS = frozenset({"float16", "float32", "float64"})


def _fits(value: int, dtype: str) -> bool:
    """Whether the int `value` is in the range of the integer type `dtype`."""
    if dtype in _SIGNED:
        bits = 8 << (_SIGNED[dtype] - 1)
        return -(1 << (bits - 1)) <= value < (1 << (bits - 1))
    bits = 8 << (_UNSIGNED[dtype] - 1)
    return 0 <= value < (1 << bits)


# The type the engine computes an arithmetic operator over a narrower operand
# type in.
_COMPUTED_IN = {
    "int8": "int64",
    "int16": "int64",
    "int32": "int64",
    "uint8": "int64",
    "uint16": "int64",
    "uint32": "int64",
    "float16": "float64",
    "float32": "float64",
}


def _computed(node: _ops.Node, wide: str) -> _ops.Node:
    """`node` as an operand of the type `wide`: an int literal as it is (the
    wire carries it as int64), anything else cast."""
    if isinstance(node, _ops.Cast) and node.try_cast is False and _int_literal(node.child) and wide == "int64":
        return node.child
    if _int_literal(node) and wide == "int64":
        return node
    return _ops.Cast(node, wide)


def _int_literal(node: _ops.Node) -> bool:
    return isinstance(node, _ops.Lit) and isinstance(node.value, int) and not isinstance(node.value, bool)


def _common_type(a: str, b: str) -> str | None:
    """The type two numeric operand types are widened to, or None when they
    are equal, not both numeric, or have no integer type in common (uint64
    with a signed type), which the engine then answers or refuses itself."""
    if a == b:
        return None
    if a in _FLOATS or b in _FLOATS:
        if not ({a, b} <= _FLOATS | _INTEGERS):
            return None
        return "float64" if "float64" in (a, b) or a in _INTEGERS or b in _INTEGERS else "float32"
    if a in _SIGNED and b in _SIGNED:
        return a if _SIGNED[a] > _SIGNED[b] else b
    if a in _UNSIGNED and b in _UNSIGNED:
        return a if _UNSIGNED[a] > _UNSIGNED[b] else b
    if a in _INTEGERS and b in _INTEGERS:
        signed, unsigned = (a, b) if a in _SIGNED else (b, a)
        return _SIGNED_OF_RANK.get(max(_SIGNED[signed], _UNSIGNED[unsigned] + 1))
    return None

_NO_TRUTH = (
    "a komira Series has no truth value: combine conditions with & and |, each in parentheses, "
    "and filter with df[cond]"
)


def _needs_terminal(what: str) -> str:
    return f"{what} needs the rows, and a komira Series is part of a plan: run its frame with .materialize()"


class Series:
    """A column of a komira `DataFrame`, or an expression over its columns.

    It is made by `df["column"]` and by the operators of another Series of the
    same frame, never by calling the class.
    """

    __slots__ = ("_frame", "_generation", "_node", "_field")

    def __init__(self, *args: object, **kwargs: object) -> None:
        raise TypeError('a komira Series is taken from a frame: df["column"]')

    @classmethod
    def _of(cls, frame: DataFrame, node: _ops.Node) -> Series:
        """The Series of `node` over the columns of `frame` as it is now; the
        field is derived here, so a type the engine would refuse fails now."""
        out = object.__new__(cls)
        object.__setattr__(out, "_frame", frame)
        object.__setattr__(out, "_generation", frame._generation)
        object.__setattr__(out, "_node", node)
        object.__setattr__(out, "_field", frame._field_of(node))
        return out

    # ---- binding --------------------------------------------------------

    def _bound_node(self, frame: DataFrame) -> _ops.Node:
        """The node, for a verb of `frame`: refused unless this Series is of
        that frame, as the frame is now."""
        if self._frame is not frame:
            raise UnsupportedOperation(
                "this Series belongs to another frame, and a komira frame has no index to align two frames by: "
                'take the column from the frame you use it with, or pass a function, as in assign(name=lambda d: d["column"])'
            )
        self._check_current()
        return self._node

    def _check_current(self) -> None:
        if self._generation != self._frame._generation:
            raise UnsupportedOperation(
                'this Series was taken from its frame before df["name"] = ... replaced the frame\'s columns: '
                "take it from the frame again"
            )

    def _derive(self, node: _ops.Node) -> Series:
        return Series._of(self._frame, node)

    def _other(self, other: object) -> _ops.Node:
        """The node of the right-hand side of an operator: a Series of the same
        frame, or a literal."""
        self._check_current()
        if isinstance(other, Series):
            return other._bound_node(self._frame)
        return _literal(other, "a komira Series")

    @property
    def _type(self) -> str:
        return self._frame._type_name(self._field)

    def _predicate(self) -> _ops.Node:
        return _predicate_of(self)

    # ---- public members -------------------------------------------------

    @property
    def dtype(self) -> str:
        """The name of the Arrow type of the values (`int64`, `float64`,
        `string`, `bool`, ...), as the engine derives it; runs nothing."""
        self._check_current()
        return self._type

    def isin(self, values: object) -> Series:
        """Whether each value equals one of `values`, a list or tuple of at
        most 64 literals, as the OR of one comparison per value (each widened
        as a comparison is); an empty list is false everywhere."""
        self._check_current()
        if isinstance(values, Series):
            raise UnsupportedOperation(
                "isin() with a Series is a semi join, which this release does not build: pass a list of values"
            )
        if not isinstance(values, (list, tuple)):
            raise TypeError(f"isin() takes a list or tuple of values, not a {type(values).__name__}")
        if len(values) > _ops.IN_LIST_MAX:
            raise UnsupportedOperation(
                f"isin() takes at most {_ops.IN_LIST_MAX} values, and was given {len(values)}"
            )
        tests = tuple(
            _ops.Compare("eq", *self._widened(self._node, _literal(v, "isin()"))) for v in values
        )
        return self._derive(_ops.or_all(tests) if tests else _ops.Lit(False))

    def __repr__(self) -> str:
        if self._generation != self._frame._generation:
            return "<komira.Series (stale)>"
        return f"<komira.Series dtype={self._type}>"

    # ---- comparisons ----------------------------------------------------

    def _widened(self, left: _ops.Node, right: _ops.Node) -> tuple[_ops.Node, _ops.Node]:
        """`left` and `right`, each cast to their common numeric type when
        they differ (`_common_type`)."""
        lt, rt = self._type_of(left), self._type_of(right)
        if _int_literal(left) and rt in _INTEGERS and _fits(left.value, rt):
            return (left if lt == rt else _ops.Cast(left, rt)), right
        if _int_literal(right) and lt in _INTEGERS and _fits(right.value, lt):
            return left, (right if lt == rt else _ops.Cast(right, lt))
        target = _common_type(lt, rt)
        if target is None:
            return left, right
        return (
            left if lt == target else _ops.Cast(left, target),
            right if rt == target else _ops.Cast(right, target),
        )

    def _type_of(self, node: _ops.Node) -> str:
        return self._frame._type_name(self._frame._field_of(node))

    def _compare(self, op: str, other: object) -> Series:
        left, right = self._widened(self._node, self._other(other))
        return self._derive(_ops.Compare(op, left, right))

    def __eq__(self, other: object) -> Series:  # type: ignore[override]
        return self._compare("eq", other)

    def __ne__(self, other: object) -> Series:  # type: ignore[override]
        return self._compare("ne", other)

    def __lt__(self, other: object) -> Series:
        return self._compare("lt", other)

    def __le__(self, other: object) -> Series:
        return self._compare("le", other)

    def __gt__(self, other: object) -> Series:
        return self._compare("gt", other)

    def __ge__(self, other: object) -> Series:
        return self._compare("ge", other)

    __hash__ = None  # type: ignore[assignment]

    # ---- arithmetic -----------------------------------------------------

    def _arith(self, op: str, other: object, reflected: bool = False) -> Series:
        right = self._other(other)
        left = self._node
        if reflected:
            left, right = right, left
        if op == "div" and self._type_of(left) in _INTEGERS and self._type_of(right) in _INTEGERS:
            left = _ops.Cast(left, "float64")
        left, right = self._widened(left, right)
        common = self._type_of(left)
        wide = _COMPUTED_IN.get(common)
        if wide is None:
            return self._derive(_ops.Arith(op, left, right))
        # The engine's arithmetic runs on int64 and float64: a narrower
        # operand type is computed there and the answer cast back to it, so
        # the column has the type SQL gives it.
        inner = _ops.Arith(op, _computed(left, wide), _computed(right, wide))
        return self._derive(_ops.Cast(inner, common))

    def __add__(self, other: object) -> Series:
        return self._arith("add", other)

    def __radd__(self, other: object) -> Series:
        return self._arith("add", other, reflected=True)

    def __sub__(self, other: object) -> Series:
        return self._arith("sub", other)

    def __rsub__(self, other: object) -> Series:
        return self._arith("sub", other, reflected=True)

    def __mul__(self, other: object) -> Series:
        return self._arith("mul", other)

    def __rmul__(self, other: object) -> Series:
        return self._arith("mul", other, reflected=True)

    def __truediv__(self, other: object) -> Series:
        return self._arith("div", other)

    def __rtruediv__(self, other: object) -> Series:
        return self._arith("div", other, reflected=True)

    def __neg__(self) -> Series:
        self._check_current()
        return self._derive(_ops.Unary("negate", self._node))

    # ---- boolean logic --------------------------------------------------

    def _logic(self, op: str, other: object, reflected: bool = False) -> Series:
        mine = self._predicate()
        if isinstance(other, Series):
            other._bound_node(self._frame)
            theirs = _predicate_of(other)
        elif isinstance(other, bool):
            theirs = _ops.Lit(other)
        else:
            raise TypeError(
                f"& and | combine boolean Series (or True and False), not a {type(other).__name__}"
            )
        left, right = (theirs, mine) if reflected else (mine, theirs)
        return self._derive(_ops.BoolOp(op, left, right))

    def __and__(self, other: object) -> Series:
        return self._logic("and", other)

    def __rand__(self, other: object) -> Series:
        return self._logic("and", other, reflected=True)

    def __or__(self, other: object) -> Series:
        return self._logic("or", other)

    def __ror__(self, other: object) -> Series:
        return self._logic("or", other, reflected=True)

    def __invert__(self) -> Series:
        return self._derive(_ops.Unary("not", self._predicate()))

    # ---- no dunder runs a query -----------------------------------------

    def __bool__(self) -> bool:
        raise UnsupportedOperation(_NO_TRUTH)

    def __len__(self) -> int:
        raise UnsupportedOperation(_needs_terminal("len() of a Series"))

    def __iter__(self):
        raise UnsupportedOperation(_needs_terminal("iterating a Series"))

    def __array__(self, *args: object, **kwargs: object) -> object:
        raise UnsupportedOperation(_needs_terminal("converting a Series to an array"))

    def __arrow_c_stream__(self, requested_schema: object | None = None) -> object:
        raise UnsupportedOperation(_needs_terminal("reading a Series as Arrow"))

    # ---- attributes never fall through ----------------------------------

    def __getattr__(self, name: str) -> object:
        message = None if name.startswith("_") else _refusals.refused(_refusals.SERIES, name)
        if message is None:
            message = f"'Series' object has no attribute '{name}'"
        raise AttributeError(message, name=name, obj=self)

    def __setattr__(self, name: str, value: object) -> None:
        raise AttributeError(
            f"cannot set the attribute '{name}' of a komira Series: a Series is part of a plan and does not change; "
            'to set a column, write df["name"] = ...',
            name=name,
            obj=self,
        )


def _predicate_of(series: Series) -> _ops.Node:
    """The node of a boolean Series as a predicate: a comparison or other
    predicate node as it is, a boolean column as `column = true` (NULL stays
    NULL), anything else refused."""
    series._check_current()
    node = series._node
    if _ops.is_predicate(node):
        return node
    if series._type == "bool":
        return _ops.Compare("eq", node, _ops.Lit(True))
    raise TypeError(f"a condition must be a boolean Series, and this one is {series._type}")


_LITERALS = "None, bool, int, float, str, bytes, Decimal, date, datetime, time or timedelta"


def _literal(value: object, what: str) -> _ops.Lit:
    """The literal node of a Python value, or the `TypeError` naming `what`."""
    try:
        return _ops.Lit(value)
    except TypeError:
        raise TypeError(
            f"{what} takes a literal ({_LITERALS}) or a Series of the same frame, not a {type(value).__name__}"
        ) from None


def operand(frame: DataFrame, value: object, verb: str) -> _ops.Node:
    """The node of a value given to a verb of `frame`: a Series of that frame,
    or a literal."""
    if isinstance(value, Series):
        return value._bound_node(frame)
    return _literal(value, verb)
