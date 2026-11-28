"""`DataFrame.replace` and `Series.replace` of the pandas-shaped skin
(komira/_frame.py and komira/_series.py call these), as pandas 3 has them:
`replace(to_replace, value, *, inplace=False, regex=False)`.

The arguments are read as pandas reads them, into the (old, new) pairs of
each column: `to_replace` a value or a list with `value` a value, a list of
the same length (pairwise) or `{column: value}`; `{column: old}` with `value`
a value or `{column: value}`; and, with `value` left out, `{old: new}` for
every column or `{column: {old: new}}`. `value=None` is a NULL. A column a
dict names that the frame does not have is skipped, as pandas skips it.

Each column with a pair whose old value its type can hold becomes one CASE,
`WHEN x = old THEN new ... ELSE x END`, the old values with one replacement
joined by OR into one case. Every case tests the column's own values, so a
replacement is never looked for again, and an old value given twice takes
its last replacement, as in pandas. Matching is exact, by the column's type,
as pandas decides which values a column can hold:

- an int column meets an int, and a whole float, in its range; a float
  column meets an int or a float, rounded to float32 for a float32 column;
  a string column meets a str; a bool meets none of them;
- NaN looked for is a missing value: NULL, and NaN in a float column
  (komira/_missing.py, where NULL in a float column is pandas' NaN). None
  looked for is NULL in a column of any other type, and nothing in a float
  column, where pandas has no None;
- a column of any other type is refused by name when a value could be in it
  (a bool in a bool column, a number in range in a decimal or a narrow int
  column, a str in a date or timestamp column, which pandas parses), since
  the engine's CASE gives int64, float64 or string only; otherwise it is the
  same column.

The replacement keeps the column's type: None (a NULL of that type), an int
or a whole float for an int column, an int or a float for a float column
(rounded to float32 for a float32 one, as pandas puts it), a str for a string
column. Any other is refused, where pandas would change the column's type. An
int32 or float32 column's CASE is computed in int64 or float64 and cast back,
as `fillna`'s is (komira/_verbs.py). A column no pair meets is the same
column with its type.

`regex=` other than False and `inplace=True` are refused by name;
`to_replace=None`, which pandas reads as patterns, and argument shapes pandas
refuses are refused with pandas' class.
"""

from __future__ import annotations

import math
import struct
from typing import Any

from . import _ops
from ._errors import UnsupportedOperation
from ._missing import FLOAT_TYPES, present
from ._series import _UNSET as UNSET
from ._series import _fits

__all__ = ["UNSET", "check_args", "column_pairs", "replaced", "series_pairs"]

_LOOKS_FOR = (type(None), bool, int, float, str)
_CHANGES = "int32, int64, float32, float64 and string"
_WITH = {
    "int32": "an int",
    "int64": "an int",
    "float32": "an int or a float",
    "float64": "an int or a float",
    "string": "a str",
}
_WIDE = {"int32": "int64", "float32": "float64"}
_NARROW_INTS = frozenset({"int8", "int16", "uint8", "uint16", "uint32", "uint64"})
_FLOAT32_MAX = struct.unpack("<f", b"\xff\xff\x7f\x7f")[0]

# The kinds of value a column of another type `replace` does not change
# could hold, as pandas compares them (a narrow int column is checked by
# range instead); a type not named holds none of them.
_NUMBER = ("bool", "int", "float")
_COULD_HOLD = {
    "bool": ("bool",),
    "float16": ("int", "float"),
    "decimal128": _NUMBER,
    "decimal256": _NUMBER,
    "large_string": ("str",),
    "string_view": ("str",),
    "utf8_view": ("str",),
    "dictionary": _NUMBER + ("str",),
    **{
        name: ("str",)
        for name in (
            "date32",
            "date64",
            "timestamp",
            "timestamp_s",
            "timestamp_ms",
            "timestamp_us",
            "timestamp_ns",
            "time32_s",
            "time32_ms",
            "time64_us",
            "time64_ns",
            "duration_s",
            "duration_ms",
            "duration_us",
            "duration_ns",
        )
    },
}


def check_args(owner: str, inplace: object, regex: object) -> None:
    """The refusals of `inplace=True` and of patterns; `owner` is "frame" or
    "Series"."""
    if inplace is not False:
        if owner == "frame":
            raise UnsupportedOperation(
                "replace(inplace=True) changes the frame in place, and komira frames do not change: "
                "use the frame replace returns"
            )
        raise UnsupportedOperation(
            "replace(inplace=True) changes the Series in place, and a komira Series does not change: "
            "use the Series replace returns"
        )
    if regex is not False:
        raise UnsupportedOperation(
            f"replace(regex={regex!r}) matches by regular expression, and replace() matches exact values only: "
            "leave regex out, or use s.str.replace(pattern, repl, regex=True) on a string column"
        )


def _no_value(owner: str) -> ValueError:
    return ValueError(f"{owner}.replace must specify either 'value', a dict-like 'to_replace', or dict-like 'regex'.")


def _no_none(to_replace: object) -> None:
    if to_replace is None:
        raise TypeError(
            "replace(None, ...) is pandas' form that looks for the patterns of regex=, and replace() matches exact "
            "values only: fill missing values with fillna(value)"
        )


def _is_list(value: object) -> bool:
    return isinstance(value, (list, tuple))


def _check_old(value: object) -> None:
    if not isinstance(value, _LOOKS_FOR):
        raise UnsupportedOperation(
            f"replace() looks for None, bool, int, float and str values, not a {type(value).__name__}"
        )


def _check_new(value: object) -> None:
    if not isinstance(value, _LOOKS_FOR):
        raise UnsupportedOperation(
            f"replace() replaces with None, bool, int, float and str values, not a {type(value).__name__}"
        )


def series_pairs(to_replace: object, value: object, owner: str = "Series") -> list[tuple[object, object]]:
    """The (old, new) pairs of one Series' `replace(to_replace, value)`, as
    pandas' `Series.replace` reads them; `value` is UNSET when left out, and
    `owner` names the verb in pandas' own refusal of that."""
    if isinstance(to_replace, dict):
        if value is not UNSET:
            raise ValueError("Series.replace cannot specify both a dict-like 'to_replace' and a 'value'")
        if any(isinstance(v, dict) for v in to_replace.values()):
            raise ValueError("to_replace and value cannot be dict-like for Series.replace")
        pairs = list(to_replace.items())
    elif value is UNSET:
        raise _no_value(owner)
    elif isinstance(value, dict):
        raise ValueError("Series.replace cannot use dict-value and non-None to_replace")
    elif _is_list(to_replace):
        if _is_list(value):
            if len(to_replace) != len(value):
                raise ValueError(
                    f"Replacement lists must match in length. Expecting {len(to_replace)} got {len(value)} "
                )
            pairs = list(zip(to_replace, value))
        else:
            pairs = [(old, value) for old in to_replace]
    else:
        _no_none(to_replace)
        if _is_list(value):
            raise TypeError(f'Invalid "to_replace" type: {type(to_replace).__name__!r}')
        pairs = [(to_replace, value)]
    for old, new in pairs:
        _check_old(old)
        _check_new(new)
    return pairs


def column_pairs(
    to_replace: object, value: object, columns: tuple[str, ...]
) -> tuple[dict[str, list[tuple[object, object]]], bool]:
    """The (old, new) pairs of each column a frame's `replace(to_replace,
    value)` names, as pandas' `DataFrame.replace` reads them, and whether
    the form is one for every column (so a refusal can say to pass a dict)."""
    if value is UNSET:
        if not isinstance(to_replace, dict):
            raise _no_value("DataFrame")
        nested = [isinstance(v, dict) for v in to_replace.values()]
        if any(nested):
            if not all(nested):
                raise TypeError("If a nested mapping is passed, all values of the top level mapping must be mappings")
            return {c: series_pairs(to_replace[c], UNSET) for c in columns if c in to_replace}, False
        pairs = series_pairs(to_replace, UNSET)
        return {c: pairs for c in columns}, True
    if isinstance(to_replace, dict):
        if isinstance(value, dict):
            named = [c for c in columns if c in to_replace and c in value]
            return {c: series_pairs(to_replace[c], value[c]) for c in named}, False
        if _is_list(value):
            raise TypeError("value argument must be scalar, dict, or Series")
        return {c: series_pairs(to_replace[c], value) for c in columns if c in to_replace}, False
    if isinstance(value, dict):
        if _is_list(to_replace):
            raise TypeError("replace() takes a dict value with one to_replace value, not a list")
        _no_none(to_replace)
        return {c: series_pairs(to_replace, value[c]) for c in columns if c in value}, False
    pairs = series_pairs(to_replace, value)
    return {c: pairs for c in columns}, True


# ---- one column ----------------------------------------------------------


class _Where:
    """How a refusal names the column or Series a CASE is built for."""

    def __init__(self, name: str | None, dtype: str, pick: bool) -> None:
        self.dtype = dtype
        column = name is not None
        self.thing = f"the column {name!r}" if column else "the Series"
        self.typed = f"the {dtype} column {name!r}" if column else f"the {dtype} Series"
        self.noun = "column" if column else "Series"
        self.it = "the column" if column else "it"
        self.pick = ", or pass a dict to replace in some columns only" if pick else ""


def _kind(value: object) -> str:
    return "bool" if isinstance(value, bool) else type(value).__name__


def _a(value: object) -> str:
    """The kind of `value` with its article: "an int", "a str"."""
    kind = _kind(value)
    return f"an {kind}" if kind == "int" else f"a {kind}"


def _is_nan(value: object) -> bool:
    return isinstance(value, float) and math.isnan(value)


def _float32(number: float) -> float:
    """`number` rounded to the nearest float32, as numpy rounds it (an
    infinity beyond float32's range), as a Python float."""
    if math.isnan(number) or math.isinf(number):
        return number
    try:
        return struct.unpack("<f", struct.pack("<f", number))[0]
    except OverflowError:
        return math.copysign(math.inf, number)


def _whole(value: object) -> int | None:
    """`value` as an int when it is an int or a whole float, else None."""
    if isinstance(value, bool):
        return None
    if isinstance(value, float):
        return int(value) if value.is_integer() else None
    return value if isinstance(value, int) else None


# Looked for: a missing value, NULL or NaN.
_MISSING: Any = object()


def _old_key(value: object, dtype: str) -> object | None:
    """What the old value `value` is looked for as in a column of the type
    `dtype`, one `replace` changes: _MISSING, or the literal compared with
    the column in its CASE's type; None when no value of the column can
    equal it."""
    if _is_nan(value) or (value is None and dtype not in FLOAT_TYPES):
        return _MISSING
    if value is None or isinstance(value, bool):
        return None
    if dtype in ("int32", "int64"):
        whole = _whole(value)
        return whole if whole is not None and _fits(whole, dtype) else None
    if dtype in FLOAT_TYPES:
        if isinstance(value, int):
            try:
                value = float(value)
            except OverflowError:
                return None
        if not isinstance(value, float):
            return None
        return _float32(value) if dtype == "float32" else value
    return value if isinstance(value, str) else None


def _could_hold(value: object, dtype: str) -> bool:
    """Whether a column of the type `dtype`, one `replace` does not change,
    could hold the old value `value`, as pandas compares them."""
    if dtype in _NARROW_INTS:
        whole = _whole(value)
        return whole is not None and _fits(whole, dtype)
    return _kind(value) in _COULD_HOLD.get(dtype, ())


def _new_literal(value: object, where: _Where) -> _ops.Node:
    """The node of the replacement `value` in the CASE's type, or the refusal
    of a value that would change the column's type."""
    dtype = where.dtype
    if value is None:
        return _ops.Cast(_ops.Lit(None), None, arrow="string") if dtype == "string" else _ops.Lit(None)
    keeps = (
        f"the {where.noun} keeps its type, so replace with None or {_WITH[dtype]}, "
        f"or cast {where.it} first with astype(){where.pick}"
    )
    if dtype in ("int32", "int64"):
        whole = _whole(value)
        if whole is None:
            shown = repr(value) if isinstance(value, float) and not math.isnan(value) else _a(value)
            raise UnsupportedOperation(f"replace() cannot put {shown} in {where.typed}: {keeps}")
        if not _fits(whole, dtype):
            raise UnsupportedOperation(
                f"replace() cannot put {whole} in {where.typed}: it is out of the range of {dtype}, "
                f"so replace with a value in range, or cast {where.it} first with astype(){where.pick}"
            )
        return _ops.Lit(whole)
    if dtype in FLOAT_TYPES:
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            raise UnsupportedOperation(f"replace() cannot put {_a(value)} in {where.typed}: {keeps}")
        try:
            number = float(value)
        except OverflowError:
            raise UnsupportedOperation(
                f"replace() cannot put an int too large for a float in {where.typed}: "
                f"replace with a smaller value{where.pick}"
            ) from None
        return _ops.Lit(_float32(number) if dtype == "float32" else number)
    if not isinstance(value, str):
        raise UnsupportedOperation(f"replace() cannot put {_a(value)} in {where.typed}: {keeps}")
    return _ops.Lit(value)


def replaced(
    node: _ops.Node, dtype: str, pairs: list[tuple[object, object]], name: str | None, pick: bool
) -> _ops.Node | None:
    """`node`, of type `dtype`, with the (old, new) `pairs` replaced, as an
    expression of the same type; None when no pair changes it. `name` is the
    column's (None for a Series) and `pick` says the form is one for every
    column, both for the refusals."""
    where = _Where(name, dtype, pick)
    if dtype not in _WITH:
        for old, new in pairs:
            missing = _is_nan(old) or old is None
            if (missing and new is not None) or (not missing and _could_hold(old, dtype)):
                raise UnsupportedOperation(
                    f"replace() changes {_CHANGES} columns, and {where.thing} is {dtype}: "
                    f"cast it first with astype(){where.pick}"
                )
        return None
    # Each old value once, as what it is looked for as, with its last
    # replacement, in the order first given.
    olds: dict[object, _ops.Node] = {}
    for old, new in pairs:
        key = _old_key(old, dtype)
        if key is None:
            continue
        if key is _MISSING and new is None and dtype not in FLOAT_TYPES:
            # A NULL stays NULL: no case, and none left from an earlier pair.
            olds.pop(_MISSING, None)
            continue
        olds[key if key is _MISSING else _ops.Lit(key)] = _new_literal(new, where)
    if not olds:
        return None
    if len(olds) > _ops.IN_LIST_MAX:
        raise UnsupportedOperation(
            f"replace() looks for at most {_ops.IN_LIST_MAX} values in a column, and {where.thing} "
            f"is given {len(olds)}"
        )
    wide = _WIDE.get(dtype)
    x = node if wide is None else _ops.Cast(node, wide)
    groups: dict[_ops.Node, list[_ops.Node]] = {}
    for key, result in olds.items():
        if key is not _MISSING:
            test = _ops.Compare("eq", x, key)
        elif dtype in FLOAT_TYPES:
            test = _ops.Unary("not", present(node, dtype))
        else:
            test = _ops.Unary("is_null", node)
        groups.setdefault(result, []).append(test)
    cases = tuple((_ops.or_all(tuple(tests)), result) for result, tests in groups.items())
    built = _ops.When(cases, x)
    return built if wide is None else _ops.Cast(built, dtype)
