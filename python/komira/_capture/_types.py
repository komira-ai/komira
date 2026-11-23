"""The types of a captured function: `return_dtype=`, `schema=`, and the return
hint (docs/design/optimized_plan_udfs.md, section 10.5). Only the types the
komira/python runtime carries are accepted: `_vocab.UDF_DTYPES`."""

from __future__ import annotations

import types
import typing

from komira._errors import UnsupportedOperation
from komira._ops import _vocab

_HINT_DTYPES = {int: "int64", float: "float64"}


def carried() -> str:
    # The narrow integer first, then the wide one, then the float.
    return ", ".join(t for t in ("int32", "int64", "float64") if t in _vocab.UDF_DTYPES)


def check_dtype(value, what: str) -> str:
    """`value` when it names a carried type; `what` names where it was given."""
    if not isinstance(value, str):
        raise TypeError(f"{what} must be a dtype name (str), not {type(value).__name__}")
    if value not in _vocab.UDF_DTYPES:
        raise UnsupportedOperation(
            f"UDF_RETURN_TYPE_UNMAPPABLE: {what} {value!r} is not a type komira/python carries; "
            f"the carried types are {carried()}"
        )
    return value


def check_schema(schema) -> tuple:
    """The `(name, dtype)` pairs of a `schema=` given as a dict or as pairs."""
    items = list(schema.items()) if isinstance(schema, dict) else schema
    if isinstance(items, (str, bytes)) or not isinstance(items, (list, tuple)):
        raise TypeError(f"schema= must be a dict or a list of (name, dtype) pairs, not {type(schema).__name__}")
    pairs = []
    for item in items:
        if not (isinstance(item, (tuple, list)) and len(item) == 2):
            raise TypeError("schema= holds (name, dtype) pairs")
        column, dtype = item
        if not isinstance(column, str):
            raise TypeError(f"schema= column names must be str, not {type(column).__name__}")
        if column == "":
            raise ValueError("schema= holds an empty column name")
        pairs.append((column, check_dtype(dtype, f"schema= column {column!r}")))
    if not pairs:
        raise ValueError("schema= names at least one column")
    names = [p[0] for p in pairs]
    for column in names:
        if names.count(column) > 1:
            raise ValueError(f"schema= names the column {column!r} more than once")
    return tuple(pairs)


def hints_of(fn, name: str) -> dict:
    """`typing.get_type_hints(fn)`, which also resolves the string annotations of
    `from __future__ import annotations`."""
    try:
        return typing.get_type_hints(fn)
    except Exception as e:  # a hint may fail to evaluate in any way
        raise UnsupportedOperation(
            f"UDF_CAPTURE_UNSUPPORTED: the type hints of `{name}()` cannot be resolved: {type(e).__name__}: {e}"
        ) from None


def show(tp) -> str:
    """A hint as written, the same on every supported Python."""
    if typing.get_origin(tp) in (typing.Union, types.UnionType):
        return " | ".join(show(a) for a in typing.get_args(tp))
    if tp is type(None):
        return "None"
    if isinstance(tp, type) and tp.__module__ == "builtins" and not typing.get_args(tp):
        return tp.__qualname__
    return repr(tp)


def _without_none(tp):
    """`T` for `Optional[T]` or `T | None`; every other hint unchanged."""
    if typing.get_origin(tp) in (typing.Union, types.UnionType):
        args = typing.get_args(tp)
        rest = [a for a in args if a is not type(None)]
        if len(rest) == 1 and len(args) == 2:
            return rest[0]
    return tp


def dtype_from_hints(name: str, fn_name: str, hints: dict) -> str:
    """The dtype of the return hint: int is int64, float is float64, and an
    Optional of either is the same."""
    if "return" not in hints:
        raise UnsupportedOperation(
            f"UDF_RETURN_TYPE_MISSING: `{name}()` has no return type. Annotate it "
            f"(`def {fn_name}(...) -> int`) or pass return_dtype= to udf "
            f"(`@udf(return_dtype=\"int64\")`); a lambda takes return_dtype=. "
            f"The carried types are {carried()}"
        )
    hint = hints["return"]
    dtype = _HINT_DTYPES.get(_without_none(hint))
    if dtype is None:
        raise UnsupportedOperation(
            f"UDF_RETURN_TYPE_UNMAPPABLE: the return hint `{show(hint)}` of `{name}()` names no type "
            f"komira/python carries. Pass return_dtype= to udf; the carried types are {carried()} "
            f"(the hints int and float map to int64 and float64)"
        )
    return dtype


def schema_missing(name: str) -> UnsupportedOperation:
    return UnsupportedOperation(
        f"UDF_RETURN_TYPE_MISSING: `{name}()` has no output schema. Pass schema= to udf "
        f"(`@udf(kind=\"map_batches_frame\", schema={{\"total\": \"int64\"}})`); a frame function's "
        f"type hints do not give one. The carried types are {carried()}"
    )
