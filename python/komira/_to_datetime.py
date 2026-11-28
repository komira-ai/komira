"""`komira.to_datetime`: a Series of Unix counts as a timestamp Series.

pandas.to_datetime(arg, unit=...) reads an integer as a count of `unit` since
the Unix epoch (`origin="unix"`), naive, with `unit` defaulting to "ns". This
serves that reading for a komira Series of integers and units "s", "ms", "us"
and "ns", and lowers it the way SQL's `make_timestamp` does:

- "s" and "ms": the count times 1_000_000 or 1_000 (the engine's checked
  int64 multiplication, so a count too large raises an overflow error rather
  than wrapping), relabelled as microseconds: `timestamp_us`;
- "us": the count relabelled as microseconds: `timestamp_us`;
- "ns": the count relabelled as nanoseconds: `timestamp_ns`.

A narrower integer is widened to int64 first. Text, floats, uint64 and the
arguments for parsing text or for zones (`format`, `dayfirst`, `yearfirst`,
`exact`, `infer_datetime_format`, `utc`), a non-unix `origin` and
`errors="coerce"` / `"ignore"` are refused by name.
"""

from __future__ import annotations

from . import _ops
from ._errors import UnsupportedOperation
from ._series import Series

__all__ = ["to_datetime"]

# pandas' marker for "not given" on `exact` and `infer_datetime_format`.
_NOT_GIVEN = object()

# The integer dtypes a count may have: every one that fits in int64.
_COUNTS = frozenset({"int8", "int16", "int32", "int64", "uint8", "uint16", "uint32"})

# unit -> the factor to microseconds (None: relabel only) and the timestamp type.
_UNITS = {
    "s": (1_000_000, "timestamp_us"),
    "ms": (1_000, "timestamp_us"),
    "us": (None, "timestamp_us"),
    "ns": (None, "timestamp_ns"),
}


def _refuse(argument: str, why: str) -> UnsupportedOperation:
    return UnsupportedOperation(f"komira.to_datetime({argument}) is not supported: {why}")


def to_datetime(
    arg: object,
    errors: str = "raise",
    dayfirst: bool = False,
    yearfirst: bool = False,
    utc: bool = False,
    format: str | None = None,
    exact: object = _NOT_GIVEN,
    unit: str | None = None,
    infer_datetime_format: object = _NOT_GIVEN,
    origin: object = "unix",
    cache: bool = True,
) -> Series:
    """The integers of the Series `arg` as timestamps: each a count of `unit`
    ("s", "ms", "us" or "ns"; pandas' default "ns") since 1970-01-01
    00:00:00, naive. "s", "ms" and "us" answer `timestamp_us` and "ns"
    answers `timestamp_ns`; a missing value stays missing. Runs nothing.
    `cache` is accepted and changes nothing."""
    if format is not None:
        raise _refuse("format=...", "parsing text into timestamps is not served; it takes integer counts with unit=")
    if dayfirst is not False or yearfirst is not False:
        name = "dayfirst" if dayfirst is not False else "yearfirst"
        raise _refuse(f"{name}=...", "it is for parsing text, which is not served")
    if exact is not _NOT_GIVEN or infer_datetime_format is not _NOT_GIVEN:
        name = "exact" if exact is not _NOT_GIVEN else "infer_datetime_format"
        raise _refuse(f"{name}=...", "it is for parsing text, which is not served")
    if utc is not False:
        raise _refuse("utc=True", "the answer is a naive timestamp; a zone-aware timestamp is not served")
    if not (isinstance(errors, str) and errors == "raise"):
        raise _refuse(f"errors={errors!r}", 'a value that does not convert raises; use errors="raise", the default')
    if not (isinstance(origin, str) and origin == "unix"):
        raise _refuse(f"origin={origin!r}", 'the counts are since the Unix epoch, origin="unix", the default')
    if not isinstance(cache, bool):
        raise TypeError(f"to_datetime() cache must be a bool, not a {type(cache).__name__}")
    if unit is None:
        unit = "ns"
    if not isinstance(unit, str) or unit not in _UNITS:
        raise _refuse(f"unit={unit!r}", 'unit is one of "s", "ms", "us" and "ns"')
    if not isinstance(arg, Series):
        raise _refuse(
            f"<{type(arg).__name__}>",
            'it takes a komira Series of integers, as komira.to_datetime(df["column"], unit="s")',
        )
    arg._check_current()
    dtype = arg._type
    if dtype not in _COUNTS:
        raise _refuse(
            f"<a {dtype} Series>",
            f"it takes a Series of integer counts of unit={unit!r}; "
            "a float, uint64, text or temporal Series is not served",
        )
    node = arg._node if dtype == "int64" else _ops.Cast(arg._node, "int64")
    factor, timestamp = _UNITS[unit]
    if factor is not None:
        node = _ops.Arith("mul", node, _ops.Lit(factor))
    return arg._derive(_ops.Cast(node, None, arrow=timestamp))
