"""The types of a captured function: `return_dtype=`, `schema=`, and the return
hint (docs/design/optimized_plan_udfs.md, section 10.5). Only the types the
komira/python runtime carries are accepted (`_ops/_dtype.py`), and a dtype is
kept in its canonical spelling."""

from __future__ import annotations

import datetime
import decimal
import types
import typing

from komira._errors import UnsupportedOperation
from komira._ops import _dtype

from . import _readset

# The return hints that name one carried type, matched by identity.
_HINT_LEAVES = (
    (bool, "bool"),
    (int, "int64"),
    (float, "float64"),
    (str, "large_string"),
    (bytes, "large_binary"),
    (datetime.datetime, "timestamp[us]"),
    (datetime.date, "date32[day]"),
)
# How deep a return hint is followed: a dataclass that holds itself is read this far.
_MAX_HINT_DEPTH = 8
_HINT_MAP = (
    "the hints int, float, bool, str, bytes, datetime.date, datetime.datetime, list[T], "
    "and a TypedDict or dataclass of them map to carried types"
)


def check_dtype(value, what: str) -> str:
    """The canonical spelling of `value` when it names a carried type; `what`
    names where it was given."""
    if not isinstance(value, str):
        raise TypeError(f"{what} must be a dtype name (str), not {type(value).__name__}")
    return _dtype.canonical(value, what)


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


def _nests(top, name: str, child: str) -> UnsupportedOperation:
    return UnsupportedOperation(
        f"UDF_RETURN_TYPE_UNMAPPABLE: the return hint `{show(top)}` of `{name}()` nests {child} "
        f"in a list or struct, which a komira column cannot hold; the carried types are {_dtype.CARRIED}"
    )


def _optional_key(hint, key: str, resolved) -> bool:
    """Whether the TypedDict `hint` lets `key` be left out. The key's resolved
    hint decides first: `NotRequired[...]` or `Required[...]`, which the class
    cannot see when the annotation is a string (`from __future__ import
    annotations`); otherwise the class's own record, which follows `total=`."""
    origin = typing.get_origin(resolved)
    if origin is typing.NotRequired:
        return True
    if origin is typing.Required:
        return False
    return key in hint.__optional_keys__


def _struct_of(hint, top, name: str, names: list, depth: int) -> str | None:
    """The struct dtype of the TypedDict or dataclass `hint` with the fields
    `names`, or None when a field's hint names no carried type. A TypedDict with
    optional keys is refused: a struct column's fields are all required."""
    try:
        field_hints = typing.get_type_hints(hint)
        extras = typing.get_type_hints(hint, include_extras=True) if typing.is_typeddict(hint) else {}
    except Exception as e:  # a hint may fail to evaluate in any way
        raise UnsupportedOperation(
            f"UDF_CAPTURE_UNSUPPORTED: the type hints of `{show(hint)}` cannot be resolved: "
            f"{type(e).__name__}: {e}"
        ) from None
    if typing.is_typeddict(hint):
        optional = [key for key in hint.__annotations__ if _optional_key(hint, key, extras.get(key))]
        if optional:
            raise UnsupportedOperation(
                f"UDF_RETURN_TYPE_UNMAPPABLE: the return hint `{show(top)}` of `{name}()` holds the TypedDict "
                f"`{hint.__qualname__}` with the optional keys {optional!r}, which a struct column cannot hold: "
                f"every field of a struct is required. Declare every key required, or pass return_dtype= to udf"
            )
    if not names:
        return None
    fields = []
    for field in names:
        problem = _dtype.field_name_problem(field)
        if problem is not None:
            raise UnsupportedOperation(
                f"UDF_RETURN_TYPE_UNMAPPABLE: the return hint `{show(top)}` of `{name}()` has the field name "
                f"{field!r}, which {problem}"
            )
        child = _of_hint(field_hints[field], top, name, depth + 1)
        if child is None:
            return None
        fields.append(f"{field}: {child}")
    return "struct<" + ", ".join(fields) + ">"


def _of_hint(hint, top, name: str, depth: int) -> str | None:
    """The dtype text of `hint`, a part of the return hint `top` that lies
    `depth` lists and structs down; None when it names no carried type. A list,
    struct or decimal below the top is refused: a column holds only flat
    children."""
    hint = _without_none(hint)
    for tp, dtype in _HINT_LEAVES:
        if hint is tp:
            return dtype
    if hint is decimal.Decimal:
        if depth > 0:
            raise _nests(top, name, "decimal.Decimal")
        raise UnsupportedOperation(
            f"UDF_RETURN_TYPE_UNMAPPABLE: the return hint `{show(top)}` of `{name}()` is a decimal.Decimal, "
            f"which carries no precision or scale. Pass return_dtype=\"decimal128(p, s)\" to udf"
        )
    if depth > _MAX_HINT_DEPTH:
        return None
    is_list = typing.get_origin(hint) is list and len(typing.get_args(hint)) == 1
    names = None if is_list else _readset.row_type_columns(hint)
    if is_list:
        item = _of_hint(typing.get_args(hint)[0], top, name, depth + 1)
        dtype = None if item is None else f"large_list<item: {item}>"
    elif names is not None:
        dtype = _struct_of(hint, top, name, names, depth)
    else:
        return None
    if dtype is not None and depth > 0:
        raise _nests(top, name, dtype)
    return dtype


def dtype_from_hints(name: str, fn_name: str, hints: dict) -> str:
    """The dtype of the return hint: int is int64, float is float64, bool is
    bool, str is large_string, bytes is large_binary, datetime.date is
    date32[day], datetime.datetime is timestamp[us], list[T] is large_list of
    T's dtype, and a TypedDict or dataclass is the struct of its fields' dtypes
    in declaration order (a TypedDict with an optional key is refused, and so
    is a TypedDict or dataclass with no field). An Optional is the same as its
    type, at every level.
    A list item or struct field is not a list, a struct or a decimal."""
    if "return" not in hints:
        raise UnsupportedOperation(
            f"UDF_RETURN_TYPE_MISSING: `{name}()` has no return type. Annotate it "
            f"(`def {fn_name}(...) -> int`) or pass return_dtype= to udf "
            f"(`@udf(return_dtype=\"int64\")`); a lambda takes return_dtype=. "
            f"The carried types are {_dtype.CARRIED}"
        )
    hint = hints["return"]
    dtype = _of_hint(hint, hint, name, 0)
    if dtype is None:
        raise UnsupportedOperation(
            f"UDF_RETURN_TYPE_UNMAPPABLE: the return hint `{show(hint)}` of `{name}()` names no type "
            f"komira/python carries. Pass return_dtype= to udf; the carried types are {_dtype.CARRIED} "
            f"({_HINT_MAP})"
        )
    return dtype


def schema_missing(name: str) -> UnsupportedOperation:
    return UnsupportedOperation(
        f"UDF_RETURN_TYPE_MISSING: `{name}()` has no output schema. Pass schema= to udf "
        f"(`@udf(kind=\"map_batches_frame\", schema={{\"total\": \"int64\"}})`); a frame function's "
        f"type hints do not give one. The carried types are {_dtype.CARRIED}"
    )
