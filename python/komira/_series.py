"""`Series`: a column of a pandas-shaped `DataFrame`, or an expression over its
columns (docs/design/dataframe_surface.md).

A Series is bound to the frame it was taken from, and to that frame's plan at
the time: it holds an expression node of the private node tree (komira/_ops)
over the frame's columns and the field the engine derives for it. It runs
nothing, with one exception: `quantile` runs a one-row aggregate of its frame
now and returns a Python float (komira/_series.py, `Series.quantile`). Otherwise
it is used inside its own frame's verbs: `df[s]` filters by it and
`df.assign(name=s)` and `df["name"] = s` make a column of it.

- A Series of another frame, or of a frame whose plan `df["x"] = ...` replaced
  after the Series was taken (a stale one), raises `UnsupportedOperation` where
  it is used: a frame has no index to align two plans by. The one exception is
  `isin(other["k"])`, a semi join of the two frames (komira/_merge.py).
- Operators build expressions: comparisons, `+ - * /` (true division: the left
  operand of an integer division is cast to float64, as Python divides), unary
  `-`, and `& | ~` over boolean Series. `isin` takes a list of values, or a
  Series of a frame of the same session (a semi join, which only `df[...]`
  takes).
- `isna()` and `notna()` (and their aliases `isnull()` and `notnull()`) say
  whether each value is missing, a boolean Series that is never NULL: a value
  is missing when it is NULL, or NaN in a float Series (komira/_missing.py).
- `astype(dtype)` casts to one Arrow type (komira/_cast.py). `s.str` gives the
  string methods of a string Series and `s.dt` the date and time methods of a
  timestamp or date32 Series (komira/_accessors.py); on a Series of another
  type each raises `AttributeError`, so `hasattr(s, "str")` is False.
- The window verbs (`cumsum`, `cummin`, `cummax`, `rank`, `rolling`) give a
  Series that reads windows (komira/_windows.py); operators combine it with
  others as any Series, carrying the windows along.
- Numeric operands of an operator or a comparison are widened to one type
  first, as SQL's binder widens them, since the plan door runs the plan as
  given: integers to the wider integer type (a signed and an unsigned one to
  the next signed type that holds both), anything meeting a float64 to
  float64, and an integer or a float16 meeting a float32 to float32. An int literal takes the integer type of the other
  operand when its value fits that type, as SQL types a literal by its value:
  so `s * 2` and `2 * s` have the type of an int32 `s`. The engine's
  arithmetic runs on int64 and float64, so an operator over a narrower type
  is computed there and cast back to that type.
- `quantile(q, interpolation="linear")` is the one method that runs a query: it
  is pandas' scalar answer, a float, so it reads the rows at once, through a
  one-row AGGREGATE of `quantile_cont` over the frame's plan. `q` is one number
  in [0, 1]; a list of them, and an interpolation other than "linear", are
  refused by name.
- No dunder runs a query: `bool`, `len`, `iter`, `__array__` and the Arrow
  stream raise `UnsupportedOperation`. A name the class does not define raises
  `AttributeError` (komira/_refusals.py), and no attribute can be set.
"""

from __future__ import annotations

from typing import TYPE_CHECKING

from . import _accessors, _cast, _groupby, _ops, _refusals, _windows
from ._errors import UnsupportedOperation
from ._missing import present
from ._windows import Windows, merged

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
    """`node`, an operand as the user gave it, as an operand of the type
    `wide`: an int literal as it is when `wide` is int64 (the wire carries it
    as int64), anything else cast."""
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
        # float64 when one side is float64; otherwise the float side is
        # float16 or float32 and the answer float32, as SQL types FLOAT with
        # an integer.
        return "float64" if "float64" in (a, b) else "float32"
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

    __slots__ = ("_frame", "_generation", "_node", "_field", "_windows")

    def __init__(self, *args: object, **kwargs: object) -> None:
        raise TypeError('a komira Series is taken from a frame: df["column"]')

    @classmethod
    def _of(cls, frame: DataFrame, node: _ops.Node, windows: Windows = ()) -> Series:
        """The Series of `node` over the columns of `frame` as it is now, and
        the windows `windows` it reads by their placeholders
        (komira/_windows.py); the field is derived here, so a type the
        engine would refuse fails now."""
        out = object.__new__(cls)
        object.__setattr__(out, "_frame", frame)
        object.__setattr__(out, "_generation", frame._generation)
        object.__setattr__(out, "_node", node)
        object.__setattr__(out, "_windows", windows)
        object.__setattr__(out, "_field", frame._field_of(node, windows))
        return out

    # ---- binding --------------------------------------------------------

    def _bound(self, frame: DataFrame) -> tuple[_ops.Node, Windows]:
        """The node and its windows, for a verb of `frame`: refused unless
        this Series is of that frame, as the frame is now."""
        if self._frame is not frame:
            raise UnsupportedOperation(
                "this Series belongs to another frame, and a komira frame has no index to align two frames by: "
                'take the column from the frame you use it with, or pass a function, as in assign(name=lambda d: d["column"])'
            )
        self._check_current()
        return self._node, self._windows

    def _check_current(self) -> None:
        if self._generation != self._frame._generation:
            raise UnsupportedOperation(
                'this Series was taken from its frame before df["name"] = ... replaced the frame\'s columns: '
                "take it from the frame again"
            )

    def _derive(self, node: _ops.Node, windows: Windows = ()) -> Series:
        """A Series of this one's frame: `node`, reading this Series' windows
        and `windows`."""
        return Series._of(self._frame, node, merged(self._windows, windows))

    def _windowed(self, node: _ops.Node, windows: Windows) -> Series:
        """The Series of a window verb of this one: `node` over the frame,
        reading `windows` (and not this Series' own expression)."""
        self._check_current()
        return Series._of(self._frame, node, windows)

    def _other(self, other: object) -> tuple[_ops.Node, Windows]:
        """The node and windows of the right-hand side of an operator: a
        Series of the same frame, or a literal."""
        self._check_current()
        if isinstance(other, Series):
            return other._bound(self._frame)
        return _literal(other, "a komira Series"), ()

    @property
    def _type(self) -> str:
        return self._frame._type_name(self._field)

    def _column(self, verb: str) -> str:
        """The name of this Series' column, for a window verb of one column."""
        self._check_current()
        if self._windows or not isinstance(self._node, _ops.ColRef):
            raise UnsupportedOperation(
                f"{verb} takes a column of the frame, and this Series is an expression: "
                'assign it as a column first, as df.assign(x=...), then take df["x"]'
            )
        return self._node.name

    def _predicate(self) -> _ops.Node:
        return _predicate_of(self)

    # ---- public members -------------------------------------------------

    @property
    def dtype(self) -> str:
        """The name of the Arrow type of the values (`int64`, `float64`,
        `string`, `bool`, ...), as the engine derives it; runs nothing."""
        self._check_current()
        return self._type

    def astype(self, dtype: object, copy: bool | None = None, errors: str = "raise") -> Series:
        """The Series cast to `dtype` (komira/_cast.py): a name, a pandas
        spelling, a builtin or a pyarrow type of one of the Arrow types it
        lists. A value that does not convert is the engine's error when the
        frame runs. A Series that has the type already is returned as an
        equal one. `copy` changes nothing, and `errors="ignore"` is refused."""
        self._check_current()
        _cast.check_astype_args(copy, errors, "astype")
        node = _cast.cast_node(self._node, self._type, dtype, "astype")
        return self._derive(self._node if node is None else node)

    @property
    def str(self) -> _accessors.StringMethods:
        """The string methods of a string Series (komira/_accessors.py);
        `AttributeError` for a Series of another type."""
        self._check_current()
        if not _accessors.is_string(self._type):
            raise AttributeError(_accessors.accessor_message("str", self._type), name="str", obj=self)
        return _accessors.StringMethods._of(self)

    @property
    def dt(self) -> _accessors.DatetimeMethods:
        """The date and time methods of a timestamp or date32 Series
        (komira/_accessors.py); `AttributeError` for a Series of another type."""
        self._check_current()
        if not _accessors.is_datetimelike(self._type):
            raise AttributeError(_accessors.accessor_message("dt", self._type), name="dt", obj=self)
        return _accessors.DatetimeMethods._of(self)

    def isin(self, values: object) -> Series:
        """Whether each value equals one of `values`, a list or tuple of at
        most 64 literals, as the OR of one comparison per value (each widened
        as a comparison is); an empty list is false everywhere.

        `values` may instead be a Series of a frame of the same session (this
        frame or another): `df[df["k"].isin(other["k"])]` is then the rows of
        `df` whose `k` equals a value of `other["k"]`, a semi join, and
        `df[~df["k"].isin(other["k"])]` the other rows, an anti join (rules
        section 8, ruling 16). That form is a condition of `df[...]` and
        nothing else: it is not combined with `&` or `|`, assigned or
        compared. A missing key equals nothing, so `isin` leaves out a row
        whose key is missing and `~isin` keeps it (ruling 7)."""
        self._check_current()
        if isinstance(values, Series):
            return _Membership._new(self, values)
        if not isinstance(values, (list, tuple)):
            raise TypeError(f"isin() takes a list or tuple of values, not a {type(values).__name__}")
        if len(values) > _ops.IN_LIST_MAX:
            raise UnsupportedOperation(
                f"isin() takes at most {_ops.IN_LIST_MAX} values, and was given {len(values)}"
            )
        tests = tuple(
            _ops.Compare("eq", *self._widened(self._node, _literal(v, "isin()"), self._windows)) for v in values
        )
        return self._derive(_ops.or_all(tests) if tests else _ops.Lit(False))

    # ---- missing values (komira/_missing.py) ----------------------------

    def isna(self) -> Series:
        """Whether each value is missing: NULL, or NaN in a float Series
        (rules section 8, ruling 6). A boolean Series that is never NULL, the
        negation of `notna`; `isnull` is the same method."""
        return self._derive(_ops.Unary("not", self._present()))

    def notna(self) -> Series:
        """Whether each value is present: not NULL, and in a float Series not
        NaN either. A boolean Series that is never NULL, the negation of
        `isna`; `notnull` is the same method."""
        return self._derive(self._present())

    isnull = isna
    notnull = notna

    def _present(self) -> _ops.Node:
        self._check_current()
        return present(self._node, self._type)

    # ---- quantile (the one method that runs) ----------------------------

    def quantile(self, q: float = 0.5, interpolation: str = "linear") -> float:
        """The `q` quantile of the values that are not missing, as a Python
        float, by linear interpolation between the two nearest values (SQL's
        `quantile_cont`); NaN when the Series has no values. `q` is one number
        from 0 to 1 (0.5 is the median); a list of fractions, and any
        `interpolation` other than "linear", are refused by name.

        This is the first Series method that runs: pandas gives a scalar, so
        it runs a one-row aggregate over the Series' frame now, as
        `.materialize()` runs a frame, and returns its value. The Series must
        be numeric or boolean (a boolean counts as 0 and 1)."""
        self._check_current()
        if isinstance(q, (list, tuple, set, range)) or hasattr(q, "__array__"):
            raise UnsupportedOperation(
                "quantile() of several fractions gives a Series indexed by them in pandas, and a komira Series "
                "has no index: ask for one fraction at a time, as s.quantile(0.25)"
            )
        if isinstance(q, bool) or not isinstance(q, (int, float)):
            raise TypeError(f"quantile q must be a number from 0 to 1, not {type(q).__name__}")
        if not 0 <= q <= 1:
            raise ValueError("percentiles should all be in the interval [0, 1]")
        if interpolation != "linear":
            raise UnsupportedOperation(
                f"quantile(interpolation={interpolation!r}) is not supported: only 'linear' is, which is "
                "SQL's quantile_cont"
            )
        if self._windows:
            raise UnsupportedOperation(
                "quantile() of a Series that reads windows is not supported: assign it as a column first, "
                'as df.assign(x=...), then take df["x"]'
            )
        dtype = self._type
        if dtype not in _groupby._NUMERIC_TYPES:
            raise UnsupportedOperation(
                f"quantile() needs a numeric or boolean Series, and this one is {dtype}"
            )
        # A boolean counts as 0 and 1; a float32 is widened, exactly, since the
        # engine's quantile reads doubles and refuses a FLOAT32 column.
        node = _ops.Cast(self._node, "float64") if dtype in ("bool", "float32") else self._node
        plan = _ops.aggregate(
            self._frame._plan, (), (("q", _ops.Agg("quantile_cont", (node, _ops.Lit(float(q))))),)
        )
        table = self._frame._derive(plan).materialize().to_arrow()
        value = table.column(0).to_pylist()[0]
        return float("nan") if value is None else float(value)

    # ---- windows (komira/_windows.py) -----------------------------------

    def cumsum(self, axis: object = None, skipna: bool = True) -> Series:
        """The running sum of the column in the frame's sort order: each
        row's value is the sum of the values from the first row to it. The
        frame must be sorted (`sort_values`); a missing value stays missing."""
        _check_axis(axis, "cumsum")
        return self._cumulative("sum", skipna)

    def cummin(self, axis: object = None, skipna: bool = True) -> Series:
        """The running least value of the column in the frame's sort order."""
        _check_axis(axis, "cummin")
        return self._cumulative("min", skipna)

    def cummax(self, axis: object = None, skipna: bool = True) -> Series:
        """The running greatest value of the column in the frame's sort order."""
        _check_axis(axis, "cummax")
        return self._cumulative("max", skipna)

    def _cumulative(self, how: str, skipna: object) -> Series:
        built = _windows.cumulative(self._frame, self._column(f"cum{how}()"), (), False, how, skipna)
        return self._windowed(built.node, built.windows)

    def rank(
        self,
        axis: object = 0,
        method: str = "average",
        numeric_only: bool = False,
        na_option: str = "keep",
        ascending: bool = True,
        pct: bool = False,
    ) -> Series:
        """The rank of each value among the column's values, as float64:
        `method="min"` gives tied values the lowest rank of their run,
        `method="dense"` numbers the distinct values 1, 2, ...; pandas'
        default `method="average"` is refused (no window function computes
        it). A missing value has a missing rank (`na_option="keep"`), or
        ranks after every value (`"bottom"`) or before every value
        (`"top"`)."""
        _check_axis(axis, "rank")
        if numeric_only is not False:
            raise UnsupportedOperation("rank(numeric_only=True) is for a frame's columns; a Series ranks its own values")
        column = self._column("rank()")
        built = _windows.rank(self._frame, column, (), False, method, ascending, na_option, pct)
        return self._windowed(built.node, built.windows)

    def rolling(
        self,
        window: int,
        min_periods: int | None = None,
        center: bool = False,
        win_type: object = None,
        on: object = None,
        closed: object = None,
        step: object = None,
        method: str = "single",
    ) -> _windows.Rolling:
        """The windows of `window` rows, each row and the ones before it in
        the frame's sort order, for `sum()`, `mean()`, `min()` and `max()`;
        a row's answer is missing when fewer than `min_periods` (by default
        `window`) of its window's rows hold a value."""
        column = self._column("rolling()")
        if center is not False:
            raise UnsupportedOperation(
                "rolling(center=True) centres each window on its row, which this release does not build: "
                "use center=False, a window of the row and the ones before it"
            )
        for name, value, default in (
            ("win_type", win_type, None),
            ("on", on, None),
            ("closed", closed, None),
            ("step", step, None),
            ("method", method, "single"),
        ):
            if value != default:
                raise UnsupportedOperation(f"rolling({name}={value!r}) is not supported: leave {name} at its default")
        return _windows.Rolling._of(self, column, window, min_periods)

    def __repr__(self) -> str:
        if self._generation != self._frame._generation:
            return "<komira.Series (stale)>"
        return f"<komira.Series dtype={self._type}>"

    # ---- comparisons ----------------------------------------------------

    def _widened(
        self, left: _ops.Node, right: _ops.Node, windows: Windows
    ) -> tuple[_ops.Node, _ops.Node]:
        """`left` and `right`, each cast to their common numeric type when
        they differ (`_common_type`); they read the windows `windows`."""
        lt, rt = self._type_of(left, windows), self._type_of(right, windows)
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

    def _type_of(self, node: _ops.Node, windows: Windows) -> str:
        return self._frame._type_name(self._frame._field_of(node, windows))

    def _compare(self, op: str, other: object) -> Series:
        right, theirs = self._other(other)
        windows = merged(self._windows, theirs)
        left, right = self._widened(self._node, right, windows)
        return self._derive(_ops.Compare(op, left, right), theirs)

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
        right, theirs = self._other(other)
        windows = merged(self._windows, theirs)
        left = self._node
        if reflected:
            left, right = right, left
        if op == "div" and self._type_of(left, windows) in _INTEGERS and self._type_of(right, windows) in _INTEGERS:
            left = _ops.Cast(left, "float64")
        wide_left, wide_right = self._widened(left, right, windows)
        common = self._type_of(wide_left, windows)
        wide = _COMPUTED_IN.get(common)
        if wide is None:
            return self._derive(_ops.Arith(op, wide_left, wide_right), theirs)
        # The engine's arithmetic runs on int64 and float64: over a narrower
        # common type each operand is cast there once and the answer cast
        # back, so the column has the type SQL gives it.
        inner = _ops.Arith(op, _computed(left, wide), _computed(right, wide))
        return self._derive(_ops.Cast(inner, common), theirs)

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
        windows: Windows = ()
        if isinstance(other, Series):
            _, windows = other._bound(self._frame)
            theirs = _predicate_of(other)
        elif isinstance(other, bool):
            theirs = _ops.Lit(other)
        else:
            raise TypeError(
                f"& and | combine boolean Series (or True and False), not a {type(other).__name__}"
            )
        left, right = (theirs, mine) if reflected else (mine, theirs)
        return self._derive(_ops.BoolOp(op, left, right), windows)

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
        # Python calls this after the `str` or `dt` property raised its
        # AttributeError: the message is the accessor's, not "no attribute".
        if name in ("str", "dt"):
            raise AttributeError(_accessors.accessor_message(name, self._type), name=name, obj=self)
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


def operand(frame: DataFrame, value: object, verb: str) -> tuple[_ops.Node, Windows]:
    """The node of a value given to a verb of `frame`, and the windows it
    reads: a Series of that frame, or a literal."""
    if isinstance(value, Series):
        return value._bound(frame)
    return _literal(value, verb), ()


def _check_axis(axis: object, verb: str) -> None:
    if axis not in (None, 0, "index") or isinstance(axis, bool):
        raise UnsupportedOperation(f"{verb}(axis={axis!r}) runs along a row, and a Series has one column: use axis=0")


_MEMBERSHIP = (
    "isin() with another Series is a semi join, which is a condition of df[...] and nothing else: "
    'filter with it alone, as df[df["k"].isin(other["k"])], and filter that frame by the other conditions'
)


class _Membership(Series):
    """`s.isin(t)` for a Series `t`: whether each value of the column `s` is a
    value of `t`, a semi join of `s`'s frame with `t`'s (an anti join when
    negated by `~`), which only `df[...]` takes (ruling 16)."""

    __slots__ = ("_values", "_negated")

    @classmethod
    def _new(cls, series: Series, values: Series) -> _Membership:
        frame = series._frame
        column = series._column("isin() with a Series")
        if isinstance(values, _Membership):
            raise UnsupportedOperation(_MEMBERSHIP)
        values._check_current()
        if values._windows:
            raise UnsupportedOperation(
                "isin() with a Series of windows is not supported: assign the windows as a column of their frame "
                "first, and pass that column"
            )
        if values._frame._session is not frame._session:
            raise UnsupportedOperation(
                "isin() with a Series of a frame on another session: frames of two sessions never meet; "
                "read both frames on one session"
            )
        out = object.__new__(cls)
        object.__setattr__(out, "_frame", frame)
        object.__setattr__(out, "_generation", frame._generation)
        object.__setattr__(out, "_node", _ops.ColRef(column))
        object.__setattr__(out, "_windows", ())
        object.__setattr__(out, "_field", frame._field_of(_ops.Lit(True)))
        object.__setattr__(out, "_values", values)
        object.__setattr__(out, "_negated", False)
        return out

    def _join(self, frame: DataFrame) -> tuple[str, str, Series]:
        """For `frame[self]`: the join kind, the key column of `frame` and the
        Series of values; refused unless this is of that frame, as it is now."""
        Series._bound(self, frame)
        self._values._check_current()
        return ("anti" if self._negated else "semi"), self._node.name, self._values

    def __invert__(self) -> Series:
        self._check_current()
        out = object.__new__(_Membership)
        for name in ("_frame", "_generation", "_node", "_windows", "_field", "_values"):
            object.__setattr__(out, name, getattr(self, name))
        object.__setattr__(out, "_negated", not self._negated)
        return out

    def __repr__(self) -> str:
        what = "not in" if self._negated else "in"
        return f"<komira.Series {self._node.name} {what} another Series' values>"

    def _refuse(self, *args: object, **kwargs: object):
        raise UnsupportedOperation(_MEMBERSHIP)

    _bound = _predicate = _compare = _arith = _refuse
    __neg__ = isin = astype = cumsum = cummin = cummax = rank = rolling = _refuse
    isna = notna = isnull = notnull = _refuse
