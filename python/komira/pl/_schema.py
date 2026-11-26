"""A frame's output fields as pyarrow types, for `LazyFrame.schema`.

The fields are the ones the plan encoder derives for the frame's plan, which
the engine derives again and checks when the plan runs. A dtype of komira.pl
is a `pyarrow.DataType` (rules section 8, ruling 14); pyarrow is imported when
a schema is asked for, not before.
"""

from __future__ import annotations

from komira._errors import UnsupportedOperation

__all__ = ["arrow_type"]

_SIMPLE = {
    "null": "null",
    "bool": "bool_",
    "int8": "int8",
    "int16": "int16",
    "int32": "int32",
    "int64": "int64",
    "uint8": "uint8",
    "uint16": "uint16",
    "uint32": "uint32",
    "uint64": "uint64",
    "float16": "float16",
    "float32": "float32",
    "float64": "float64",
    "string": "string",
    "large_string": "large_string",
    "binary": "binary",
    "large_binary": "large_binary",
    "date32": "date32",
    "date64": "date64",
    "string_view": "string_view",
    "utf8_view": "string_view",
    "binary_view": "binary_view",
}

_UNITS = {"s": "s", "ms": "ms", "us": "us", "ns": "ns"}


def arrow_type(field):
    """The `pyarrow.DataType` of the `WireField` `field`. A type with no
    pyarrow spelling here (a map, a union, an interval) is refused by name."""
    import pyarrow as pa

    from komira._plan._wire import arrow_name

    name = arrow_name(field.arrow_type_id)
    if name in _SIMPLE:
        return getattr(pa, _SIMPLE[name])()
    kind, _, unit = name.rpartition("_")
    if kind == "timestamp" and unit in _UNITS:
        return pa.timestamp(unit, tz=field.tz or None)
    if kind in ("time32", "time64") and unit in _UNITS:
        return getattr(pa, kind)(unit)
    if kind == "duration" and unit in _UNITS:
        return pa.duration(unit)
    if name == "decimal128":
        return pa.decimal128(field.decimal_precision, field.decimal_scale)
    if name in ("list", "large_list") and len(field.children) == 1:
        item = field.children[0]
        build = pa.list_ if name == "list" else pa.large_list
        return build(pa.field(item.name, arrow_type(item), item.nullable))
    if name == "struct":
        return pa.struct([pa.field(c.name, arrow_type(c), c.nullable) for c in field.children])
    raise UnsupportedOperation(
        f"the column '{field.name}' has the type {name}, which LazyFrame.schema does not name yet"
    )
