"""Decoding the `komira.plan.v1` WireSchema bytes that `komira_parquet_schema`
returns into a `pyarrow.Schema`.

The bytes are protobuf (`src/komira_plan_proto/plan.proto`, messages
`WireSchema` and `WireField`), not an Arrow IPC stream. Only the fields a flat
column needs are read; a type outside the table below is refused by name and
never guessed, since a wrong type is worse than no schema.
"""

from __future__ import annotations

import pyarrow as pa

from ._native import KomiraError

# `WireField.arrow_type_id` is the engine's `ArrowType.type_id`
# (src/komira_arrow/arrow_types.mojo), verbatim.
_SIMPLE = {
    0: pa.null(), 1: pa.bool_(),
    2: pa.int8(), 3: pa.int16(), 4: pa.int32(), 5: pa.int64(),
    6: pa.uint8(), 7: pa.uint16(), 8: pa.uint32(), 9: pa.uint64(),
    10: pa.float16(), 11: pa.float32(), 12: pa.float64(),
    13: pa.string(), 14: pa.binary(), 15: pa.date32(), 16: pa.date64(),
    26: pa.large_string(), 27: pa.large_binary(),
    30: pa.time32("s"), 31: pa.time32("ms"), 32: pa.time64("us"), 33: pa.time64("ns"),
    34: pa.duration("s"), 35: pa.duration("ms"), 36: pa.duration("us"), 37: pa.duration("ns"),
}
_TIMESTAMP_UNIT = {17: "us", 22: "s", 23: "ms", 24: "us", 25: "ns"}  # 17 is the legacy microseconds id
_DECIMAL128 = 18


def _varint(buf: bytes, i: int):
    shift = value = 0
    while True:
        if i >= len(buf) or shift > 63:
            raise KomiraError("the schema bytes end inside a varint")
        b = buf[i]
        i += 1
        value |= (b & 0x7F) << shift
        if not b & 0x80:
            return value, i
        shift += 7


def _fields(buf: bytes):
    """`(field number, wire type, value)` of one message; value is an int or bytes."""
    i = 0
    while i < len(buf):
        key, i = _varint(buf, i)
        number, wire = key >> 3, key & 7
        if wire == 0:
            value, i = _varint(buf, i)
        elif wire == 2:
            n, i = _varint(buf, i)
            if i + n > len(buf):
                raise KomiraError("the schema bytes end inside a field")
            value, i = buf[i : i + n], i + n
        elif wire in (1, 5):
            n = 8 if wire == 1 else 4
            if i + n > len(buf):
                raise KomiraError("the schema bytes end inside a fixed-width field")
            value, i = buf[i : i + n], i + n
        else:
            raise KomiraError("the schema bytes hold wire type %d" % wire)
        yield number, wire, value


def _text(value: bytes, what: str) -> str:
    try:
        return value.decode("utf-8")
    except UnicodeDecodeError:
        raise KomiraError("the schema bytes hold a %s that is not UTF-8" % what) from None


def _signed(v: int) -> int:
    return v - (1 << 64) if v >= 1 << 63 else v


def _field(buf: bytes) -> pa.Field:
    name, type_id, nullable, precision, scale, tz, children = "", 0, False, 0, 0, "", False
    for number, wire, value in _fields(buf):
        if number == 1 and wire == 2:
            name = _text(value, "column name")
        elif number == 2 and wire == 0:
            type_id = value
        elif number == 4 and wire == 0:
            nullable = value != 0
        elif number == 5 and wire == 0:
            precision = _signed(value)
        elif number == 6 and wire == 0:
            scale = _signed(value)
        elif number == 7 and wire == 2:
            tz = _text(value, "timezone")
        elif number in (13, 14, 15, 16):
            children = True
    if children:
        raise KomiraError("column %r is a nested type, which this binding does not decode" % name)
    if type_id in _SIMPLE:
        typ = _SIMPLE[type_id]
    elif type_id in _TIMESTAMP_UNIT:
        typ = pa.timestamp(_TIMESTAMP_UNIT[type_id], tz=tz or None)
    elif type_id == _DECIMAL128:
        typ = pa.decimal128(precision, scale)
    else:
        raise KomiraError("column %r has Arrow type id %d, which this binding does not decode" % (name, type_id))
    return pa.field(name, typ, nullable=nullable)


def schema_from_wire(data: bytes) -> pa.Schema:
    """The `pyarrow.Schema` of WireSchema `data`. Table metadata is kept."""
    fields, keys, values = [], [], []
    for number, wire, value in _fields(data):
        if number == 1 and wire == 2:
            fields.append(_field(value))
        elif number == 2 and wire == 2:
            keys.append(value)
        elif number == 3 and wire == 2:
            values.append(value)
    if len(set(keys)) != len(keys):
        raise KomiraError("the schema metadata repeats a key")
    if len(keys) != len(values):
        raise KomiraError("the schema metadata has %d keys and %d values" % (len(keys), len(values)))
    return pa.schema(fields, metadata=dict(zip(keys, values)) or None)
