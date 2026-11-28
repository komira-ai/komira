"""The `.str` and `.dt` accessors of a `Series` (docs/design/dataframe_surface_verbs.md).

`s.str` is a `StringMethods` for a string column and `s.dt` a `DatetimeMethods`
for a timestamp or date32 column; on a Series of another type the attribute
raises `AttributeError`, so `hasattr(s, "str")` is False. Every method returns a
Series of the same frame (`Series._derive`): it builds one expression node over
the Series' node and runs nothing. A missing value in gives a missing value out
(`extract` of a string that does not match gives '', as the engine's
regexp_extract does, where pandas gives NaN).

`.str` builds, with the pandas defaults kept:

- `lower`, `upper`, `len` (characters, int64);
- `startswith`, `endswith` and `contains(regex=False)` as string tests, and
  `contains`, `match` and `fullmatch` as regular-expression tests (`match` is
  `contains` anchored at the start, `fullmatch` anchored at both ends);
- `replace`, of every occurrence, literal or by regular expression;
- `slice(start, stop)` with non-negative bounds and no step;
- `pad`, which never cuts a string longer than `width` (the engine's padding
  does, so the node keeps a longer string as it is);
- `extract(pat, expand=False)` of the one capture group; a string that does
  not match gives '', not a missing value.

`.dt` builds `year`, `quarter`, `month`, `day`, `dayofweek` (Monday is 0),
`dayofyear` of a timestamp or a date, `hour`, `minute`, `second` and
`microsecond` (the part of the second, as pandas) of a timestamp only, each int64,
and `floor(freq)` of a timestamp to one fixed unit.

Arguments pandas has that this release cannot honour raise
`UnsupportedOperation` at the call and name what to write instead. A method
the accessor lacks raises `AttributeError` with the message of its row in
komira/_refusals.py (`STRING`, `DATETIME`), or Python's own for a name in no
row; no attribute can be set; `dir` lists the defined methods only.
"""

from __future__ import annotations

import re
from typing import TYPE_CHECKING

from . import _ops, _refusals
from ._errors import UnsupportedOperation

if TYPE_CHECKING:
    from ._series import Series

__all__ = ["DatetimeMethods", "StringMethods", "accessor_message", "is_datetimelike", "is_string"]


def is_string(dtype: str) -> bool:
    """Whether a column of the Arrow type `dtype` has the `.str` accessor."""
    return dtype in ("string", "large_string")


def is_datetimelike(dtype: str) -> bool:
    """Whether a column of the Arrow type `dtype` has the `.dt` accessor."""
    return dtype == "date32" or dtype.startswith("timestamp")


def accessor_message(name: str, dtype: str) -> str:
    """The `AttributeError` message of `.str` or `.dt` on a Series of `dtype`."""
    if name == "str":
        return f"Can only use .str accessor with string values, not {dtype}"
    return f"Can only use .dt accessor with datetimelike values, not {dtype}"


def _check_bool(value: object, name: str, verb: str) -> None:
    if not isinstance(value, bool):
        raise TypeError(f"{verb}: {name} must be a bool, not {type(value).__name__}")


def _check_text(value: object, name: str, verb: str) -> None:
    if not isinstance(value, str):
        raise TypeError(f"{verb}: {name} must be a str, not {type(value).__name__}")


def _check_int(value: object, name: str, verb: str) -> None:
    if isinstance(value, bool) or not isinstance(value, int):
        raise TypeError(f"{verb}: {name} must be an int, not {type(value).__name__}")


def _check_na(na: object, verb: str) -> None:
    if na is not None:
        raise UnsupportedOperation(
            f"{verb}(na={na!r}) would give a chosen value for a missing value, and a komira result stays "
            "missing there: leave na out, and a filter df[cond] drops the rows where it is missing"
        )


def _check_flags(flags: object, verb: str, spelling: str) -> None:
    _check_int(flags, "flags", verb + "()")
    if flags != 0:
        raise UnsupportedOperation(f"{verb}(flags={flags!r}) is not supported: {spelling}")


_NO_FLAGS = "the engine's regular expressions take no Python flags"
_FLAGS_WITH_CASE = f"{_NO_FLAGS}; pass case=False to ignore case"


class _Accessor:
    """What `StringMethods` and `DatetimeMethods` share: the Series they work
    on, and the attribute rules."""

    __slots__ = ("_series",)

    def __init__(self, *args: object, **kwargs: object) -> None:
        raise TypeError('an accessor is taken from a Series: s.str or s.dt')

    @classmethod
    def _of(cls, series: Series) -> _Accessor:
        out = object.__new__(cls)
        object.__setattr__(out, "_series", series)
        return out

    def _child(self) -> _ops.Node:
        """The node of the Series, once it is known to be current."""
        self._series._check_current()
        return self._series._node

    def _derive(self, node: _ops.Node) -> Series:
        return self._series._derive(node)

    _TABLE: dict[str, str] = {}

    def __getattr__(self, name: str) -> object:
        message = None if name.startswith("_") else _refusals.refused(self._TABLE, name)
        if message is None:
            message = f"'{type(self).__name__}' object has no attribute '{name}'"
        raise AttributeError(message, name=name, obj=self)

    def __setattr__(self, name: str, value: object) -> None:
        raise AttributeError(
            f"cannot set the attribute '{name}' of a komira {type(self).__name__}: "
            "an accessor is part of a plan and does not change",
            name=name,
            obj=self,
        )

    def __dir__(self) -> list[str]:
        return sorted(n for n in dir(type(self)) if not n.startswith("_"))

    def __repr__(self) -> str:
        return f"<komira.{type(self).__name__}>"


class StringMethods(_Accessor):
    """`s.str` of a string Series."""

    __slots__ = ()
    _TABLE = _refusals.STRING

    def lower(self) -> Series:
        """Each string in lower case (Unicode-aware)."""
        return self._derive(_ops.StringFn("lower", self._child()))

    def upper(self) -> Series:
        """Each string in upper case (Unicode-aware)."""
        return self._derive(_ops.StringFn("upper", self._child()))

    def len(self) -> Series:
        """The number of characters of each string, an int64 Series."""
        return self._derive(_ops.StringFn("length", self._child()))

    def _affix(self, op: str, verb: str, pat: object, na: object) -> Series:
        child = self._child()
        if isinstance(pat, tuple):
            raise UnsupportedOperation(
                f"{verb}() of a tuple of {'prefixes' if op == 'starts_with' else 'suffixes'} is not supported: "
                f"combine one {verb}() per value with |"
            )
        _check_text(pat, "pat", f"{verb}()")
        _check_na(na, verb)
        return self._derive(_ops.StringOp(op, child, pat))

    def startswith(self, pat: str, na: object = None) -> Series:
        """Whether each string starts with the str `pat`."""
        return self._affix("starts_with", "str.startswith", pat, na)

    def endswith(self, pat: str, na: object = None) -> Series:
        """Whether each string ends with the str `pat`."""
        return self._affix("ends_with", "str.endswith", pat, na)

    def contains(
        self, pat: str, case: bool = True, flags: int = 0, na: object = None, regex: bool = True
    ) -> Series:
        """Whether each string contains `pat`: a regular expression found
        anywhere in it (`regex=True`), or the text itself (`regex=False`)."""
        verb = "str.contains"
        child = self._child()
        _check_text(pat, "pat", f"{verb}()")
        _check_bool(case, "case", f"{verb}()")
        _check_flags(flags, verb, _FLAGS_WITH_CASE)
        _check_na(na, verb)
        _check_bool(regex, "regex", f"{verb}()")
        if not regex:
            if not case:
                raise UnsupportedOperation(
                    "str.contains(case=False, regex=False) is not supported: the text test is case-sensitive; "
                    "escape the text with re.escape() and use regex=True with case=False"
                )
            return self._derive(_ops.StringOp("contains", child, pat))
        return self._derive(_ops.Regexp("like", child, pat, flags="" if case else "i"))

    def match(self, pat: str, case: bool = True, flags: int = 0, na: object = None) -> Series:
        """Whether `pat`, a regular expression, matches at the start of each string."""
        verb = "str.match"
        child = self._child()
        _check_text(pat, "pat", f"{verb}()")
        _check_bool(case, "case", f"{verb}()")
        _check_flags(flags, verb, _FLAGS_WITH_CASE)
        _check_na(na, verb)
        return self._derive(_ops.Regexp("like", child, "^(?:" + pat + ")", flags="" if case else "i"))

    def fullmatch(self, pat: str, case: bool = True, flags: int = 0, na: object = None) -> Series:
        """Whether `pat`, a regular expression, matches the whole of each string."""
        verb = "str.fullmatch"
        child = self._child()
        _check_text(pat, "pat", f"{verb}()")
        _check_bool(case, "case", f"{verb}()")
        _check_flags(flags, verb, _FLAGS_WITH_CASE)
        _check_na(na, verb)
        return self._derive(_ops.Regexp("full_match", child, pat, flags="" if case else "i"))

    def replace(
        self,
        pat: str,
        repl: str,
        n: int = -1,
        case: bool | None = None,
        flags: int = 0,
        regex: bool = False,
    ) -> Series:
        """Each string with every occurrence of `pat` replaced by `repl`: the
        text itself (`regex=False`, as pandas) or a regular expression."""
        verb = "str.replace"
        child = self._child()
        _check_text(pat, "pat", f"{verb}()")
        if callable(repl):
            raise UnsupportedOperation(
                "str.replace() with a function as repl is not supported: the plan has no node that calls it; "
                "pass a str"
            )
        _check_text(repl, "repl", f"{verb}()")
        _check_int(n, "n", f"{verb}()")
        if n != -1:
            raise UnsupportedOperation(
                f"str.replace(n={n}) replaces the first n occurrences, and the engine replaces every one: use n=-1"
            )
        if case is not None:
            _check_bool(case, "case", f"{verb}()")
        _check_flags(flags, verb, _FLAGS_WITH_CASE)
        _check_bool(regex, "regex", f"{verb}()")
        if not regex:
            if case is False:
                raise UnsupportedOperation(
                    "str.replace(case=False, regex=False) is not supported: the text replacement is case-sensitive; "
                    "escape the text with re.escape() and use regex=True with case=False"
                )
            if pat == "":
                raise UnsupportedOperation(
                    "str.replace() of the empty text inserts repl between every two characters in pandas, "
                    "and the engine's replace leaves the string as it is: give a pat with a character in it"
                )
            return self._derive(_ops.StringFnN("replace", (child, _ops.Lit(pat), _ops.Lit(repl))))
        return self._derive(
            _ops.Regexp("replace", child, pat, replacement=repl, flags="gi" if case is False else "g")
        )

    def slice(self, start: int | None = None, stop: int | None = None, step: int | None = None) -> Series:
        """The characters of each string from `start` up to `stop`, counted from 0."""
        verb = "str.slice"
        child = self._child()
        for name, value in (("start", start), ("stop", stop), ("step", step)):
            if value is not None:
                _check_int(value, name, f"{verb}()")
        if step is not None and step != 1:
            raise UnsupportedOperation(f"str.slice(step={step}) is not supported: take every character, with step=None")
        for name, value in (("start", start), ("stop", stop)):
            if value is not None and value < 0:
                raise UnsupportedOperation(
                    f"str.slice({name}={value}) counts from the end of each string, which needs each value's "
                    f"length: give a {name} of 0 or more"
                )
        first = 0 if start is None else start
        length = None if stop is None else max(stop - first, 0)
        return self._derive(_ops.Substring(child, first + 1, length))

    def pad(self, width: int, side: str = "left", fillchar: str = " ") -> Series:
        """Each string padded with `fillchar` to `width` characters on the
        `side`; a string already `width` long or longer stays as it is."""
        verb = "str.pad"
        child = self._child()
        _check_int(width, "width", f"{verb}()")
        _check_text(side, "side", f"{verb}()")
        if not isinstance(fillchar, str) or len(fillchar) != 1:
            raise TypeError(f"fillchar must be a character, not {type(fillchar).__name__}")
        if side == "both":
            raise UnsupportedOperation(
                "str.pad(side='both') centres the string, which this release does not build: "
                "pad to one side with side='left' or side='right'"
            )
        if side not in ("left", "right"):
            raise ValueError(f"str.pad() side must be 'left', 'right' or 'both', not {side!r}")
        op = "lpad" if side == "left" else "rpad"
        long_enough = _ops.Compare("ge", _ops.StringFn("length", child), _ops.Lit(width))
        padded = _ops.StringFnN(op, (child, _ops.Lit(width), _ops.Lit(fillchar)))
        return self._derive(_ops.When(((long_enough, child),), padded))

    def extract(self, pat: str, flags: int = 0, expand: bool = True) -> Series:
        """The text of the one capture group of `pat` in each string, as a
        Series (`expand=False`). A string that does not match gives '' (the
        engine's regexp_extract), where pandas gives NaN."""
        verb = "str.extract"
        child = self._child()
        _check_text(pat, "pat", f"{verb}()")
        _check_flags(flags, verb, _NO_FLAGS)
        _check_bool(expand, "expand", f"{verb}()")
        groups = re.compile(pat).groups
        if expand:
            raise UnsupportedOperation(
                "str.extract(expand=True) returns a frame with a column per group: "
                "pass expand=False for one group as a Series"
            )
        if groups != 1:
            raise UnsupportedOperation(
                f"str.extract() of a pattern with {groups} capture groups is not supported: "
                "use a pattern with exactly one, and extract each group in its own call"
            )
        return self._derive(_ops.Regexp("extract", child, pat, group=1))


# The frequencies floor() takes, each one fixed unit (pandas' spellings, and
# the older aliases it still takes).
_FLOOR = {
    "D": "day",
    "h": "hour",
    "H": "hour",
    "min": "minute",
    "T": "minute",
    "s": "second",
    "S": "second",
    "ms": "millisecond",
    "L": "millisecond",
    "us": "microsecond",
    "U": "microsecond",
}
_FLOOR_LISTED = "'D', 'h', 'min', 's', 'ms' or 'us'"
# The calendar rules resample() takes, which floor() refuses as pandas does.
_CALENDAR = frozenset({"W", "W-SUN", "MS", "ME", "M"})


def _part(name: str, build, *, timestamp_only: bool = False) -> property:
    """The property `name` of `.dt`: the node `build(child)` of the Series,
    refused for a date when `timestamp_only` (a date has no time of day)."""

    def getter(self: DatetimeMethods) -> Series:
        child = self._child()
        if timestamp_only and self._series._type == "date32":
            raise UnsupportedOperation(
                f".dt.{name} reads the time of day, and a date32 column has none: use year, month and day"
            )
        return self._derive(build(child))

    getter.__name__ = name
    getter.__doc__ = f"The {name} of each value, an int64 Series."
    return property(getter)


def _extract(unit: str):
    return lambda child: _ops.Extract(unit, child)


def _microsecond(child: _ops.Node) -> _ops.Node:
    # The engine's microsecond counts the whole seconds too: 30123456 for :30.123456.
    return _ops.Arith("mod", _ops.Extract("microsecond", child), _ops.Lit(1_000_000))


def _dayofweek(child: _ops.Node) -> _ops.Node:
    # ISO day of week is 1 for Monday; pandas counts Monday as 0.
    return _ops.Arith("sub", _ops.Extract("isodow", child), _ops.Lit(1))


class DatetimeMethods(_Accessor):
    """`s.dt` of a timestamp or date32 Series."""

    __slots__ = ()
    _TABLE = _refusals.DATETIME

    year = _part("year", _extract("year"))
    quarter = _part("quarter", _extract("quarter"))
    month = _part("month", _extract("month"))
    day = _part("day", _extract("day"))
    hour = _part("hour", _extract("hour"), timestamp_only=True)
    minute = _part("minute", _extract("minute"), timestamp_only=True)
    second = _part("second", _extract("second"), timestamp_only=True)
    microsecond = _part("microsecond", _microsecond, timestamp_only=True)
    dayofweek = _part("dayofweek", _dayofweek)
    day_of_week = _part("day_of_week", _dayofweek)
    weekday = _part("weekday", _dayofweek)
    dayofyear = _part("dayofyear", _extract("dayofyear"))
    day_of_year = _part("day_of_year", _extract("dayofyear"))

    def floor(self, freq: str, ambiguous: object = "raise", nonexistent: object = "raise") -> Series:
        """Each timestamp cut down to the start of its day, hour, minute,
        second, millisecond or microsecond (one fixed unit, not a multiple)."""
        child = self._child()
        if self._series._type == "date32":
            raise UnsupportedOperation(
                ".dt.floor() cuts the time of day off a timestamp, and a date32 column has none: "
                "a date is whole days already"
            )
        if not isinstance(freq, str):
            raise TypeError(f".dt.floor() freq must be a str, not {type(freq).__name__}")
        if ambiguous != "raise" or nonexistent != "raise":
            raise UnsupportedOperation(
                ".dt.floor(ambiguous=..., nonexistent=...) is for time zones, and a komira timestamp has none: "
                "leave both at their default"
            )
        unit = _FLOOR.get(freq)
        if freq in _CALENDAR:
            raise UnsupportedOperation(
                f".dt.floor({freq!r}) cuts to a week or a month, which has no fixed length, and pandas "
                f"refuses it too: bucket the rows with df.resample({freq!r}, on=column)"
            )
        if unit is None:
            if freq[:1].isdigit():
                raise UnsupportedOperation(
                    f".dt.floor({freq!r}) cuts to a multiple of a unit, and the plan cuts to one fixed unit: "
                    f"use {_FLOOR_LISTED}"
                )
            raise UnsupportedOperation(
                f".dt.floor({freq!r}) is not a unit this release cuts to: use {_FLOOR_LISTED}"
            )
        return self._derive(_ops.Extract("trunc_" + unit, child))
