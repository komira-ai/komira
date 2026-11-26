"""The dtype argument of `astype` and the cast node it builds
(docs/design/dataframe_surface_verbs.md, "dtypes").

`parse_dtype` turns what a user writes into the name of one Arrow type, and
`cast_node` wraps an expression node in the cast to it. Both skins' verbs call
them, so a column and a Series are cast by the same rules. A cast is never a
`try_cast`: a value that does not convert is the engine's error at the
terminal, not a missing value.

A dtype is one of:

- the names `bool`, `int8` .. `int64`, `uint8` .. `uint64`, `float32`,
  `float64`, `string`, `binary` and `date32`;
- pandas' spellings `"Int8"` .. `"Int64"`, `"UInt8"` .. `"UInt64"`,
  `"Float32"`, `"Float64"`, `"boolean"` and `"str"`, and the builtins `bool`,
  `int` (int64), `float` (float64) and `str` (string);
- a pyarrow `DataType` of one of those types (`pa.int64()`, `pa.float32()`
  spelled `float`, `pa.float64()` spelled `double`, `pa.string()`,
  `pa.utf8()`, `pa.binary()`, `pa.date32()`), recognised by its class's module
  and its text, so pyarrow is not imported here.

`"object"`, `"category"` and any other pyarrow type raise `UnsupportedOperation`
naming it; any other text or object raises `TypeError`.
"""

from __future__ import annotations

from . import _ops
from ._errors import UnsupportedOperation

__all__ = ["cast_node", "check_astype_args", "parse_dtype"]

# The types a cast can name, in the order the messages list them.
_NAMES = (
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
    "string",
    "binary",
    "date32",
)
_LISTED = ", ".join(_NAMES)

# The types Cast names by its primitive target; the others by an Arrow type.
_ARROW_ONLY = frozenset({"string", "binary", "date32"})

_PANDAS = {
    "Int8": "int8",
    "Int16": "int16",
    "Int32": "int32",
    "Int64": "int64",
    "UInt8": "uint8",
    "UInt16": "uint16",
    "UInt32": "uint32",
    "UInt64": "uint64",
    "Float32": "float32",
    "Float64": "float64",
    "boolean": "bool",
    "str": "string",
}

# The text of a pyarrow type (`str(pa.float32())` is "float") and the type it names.
_PYARROW = {
    "bool": "bool",
    "int8": "int8",
    "int16": "int16",
    "int32": "int32",
    "int64": "int64",
    "uint8": "uint8",
    "uint16": "uint16",
    "uint32": "uint32",
    "uint64": "uint64",
    "float": "float32",
    "double": "float64",
    "string": "string",
    "utf8": "string",
    "binary": "binary",
    "date32[day]": "date32",
}

_BUILTINS = ((bool, "bool"), (int, "int64"), (float, "float64"), (str, "string"))


def parse_dtype(dtype: object, verb: str) -> str:
    """The name of the Arrow type `dtype` means, for the verb `verb` (named in
    the messages), or the error the module docstring lists."""
    if isinstance(dtype, str):
        if dtype in _PANDAS:
            return _PANDAS[dtype]
        if dtype in _NAMES:
            return dtype
        if dtype in ("object", "category"):
            raise _no_arrow_type(verb, repr(dtype))
        raise TypeError(
            f"data type {dtype!r} not understood: {verb}() takes {_LISTED}, "
            "a pandas spelling such as 'Int64', or a pyarrow type"
        )
    if dtype is object:
        raise _no_arrow_type(verb, "object")
    for builtin, name in _BUILTINS:
        if dtype is builtin:
            return name
    if type(dtype).__module__.startswith("pyarrow"):
        text = str(dtype)
        if text in _PYARROW:
            return _PYARROW[text]
        raise UnsupportedOperation(
            f"{verb}() cannot cast to the Arrow type {text}: it casts to {_LISTED}"
        )
    raise TypeError(
        f"{verb}() takes a dtype name or a pyarrow type, not a {type(dtype).__name__}: it casts to {_LISTED}"
    )


def _no_arrow_type(verb: str, written: str) -> UnsupportedOperation:
    return UnsupportedOperation(
        f"{verb}({written}) names no one Arrow type, and a komira column has exactly one: "
        f"cast to one of {_LISTED}"
    )


def check_astype_args(copy: object, errors: object, verb: str) -> None:
    """The `copy` and `errors` arguments of `astype`: `copy` is None or a bool
    and changes nothing; `errors` is "raise"; "ignore" is refused because it
    returns the column uncast when a value fails to convert, which a plan
    cannot decide before it runs."""
    if copy is not None and not isinstance(copy, bool):
        raise TypeError(f"{verb}() copy must be a bool or None, not a {type(copy).__name__}")
    if errors == "raise" and isinstance(errors, str):
        return
    if errors == "ignore" and isinstance(errors, str):
        raise UnsupportedOperation(
            f'{verb}(errors="ignore") would return the column uncast when a value does not convert, '
            "which a plan cannot decide before it runs: use errors=\"raise\", the default"
        )
    raise ValueError(
        f"Expected value of kwarg 'errors' to be one of ['raise', 'ignore']. Supplied value is {errors!r}"
    )


def cast_node(node: _ops.Node, current: str, dtype: object, verb: str) -> _ops.Node | None:
    """`node`, of the Arrow type `current`, cast to `dtype`; None when it has
    that type already."""
    target = parse_dtype(dtype, verb)
    if current == target:
        return None
    if target in _ARROW_ONLY:
        return _ops.Cast(node, None, arrow=target)
    return _ops.Cast(node, target)
