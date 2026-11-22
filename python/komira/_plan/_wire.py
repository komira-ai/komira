"""The generated plan modules and the numbering of the plan wire.

The node tree names operators, units, casts and Arrow types by the members of
the wire's enumerations with the prefix removed and lower-cased
(komira/_ops/_vocab.py); `member` turns such a name back into the enum value.
Arrow types travel as raw Arrow type ids, which are the `ArrowType` member's
value minus one (src/plan_proto/plan_vocabulary.proto), and `arrow_id` gives
that id.
"""

from __future__ import annotations

from komira.plan.v1 import plan_pb2 as pb
from komira.plan.v1 import plan_vocabulary_pb2 as vocab

__all__ = [
    "DICT_INDEX_INT32",
    "NUMERIC_DTYPES",
    "TIMESTAMP_TYPES",
    "arrow_id",
    "arrow_name",
    "dtype_code",
    "field",
    "member",
    "pb",
    "physical_dtype",
    "vocab",
]

# The column types that have a DType of their own: each one's DType code is
# `_DT_<NAME>` (plan_vocabulary.proto, DTypeCode).
NUMERIC_DTYPES = frozenset(
    {
        "bool",
        "int8",
        "int16",
        "int32",
        "int64",
        "uint8",
        "uint16",
        "uint32",
        "uint64",
        "float16",
        "float32",
        "float64",
    }
)

TIMESTAMP_TYPES = frozenset(
    {"timestamp", "timestamp_s", "timestamp_ms", "timestamp_us", "timestamp_ns"}
)

# The physical DType the engine gives a cast to each Arrow type that is not a
# numeric one (`_arrow_to_physical_dtype`, src/plan_expr/expr.mojo). Every
# other Arrow type has none (`_DT_INVALID`).
_PHYSICAL_DTYPE = {
    "date32": "int32",
    "date64": "int64",
    "time32_s": "int32",
    "time32_ms": "int32",
    "time64_us": "int64",
    "time64_ns": "int64",
    "duration_s": "int64",
    "duration_ms": "int64",
    "duration_us": "int64",
    "duration_ns": "int64",
} | {t: "int64" for t in TIMESTAMP_TYPES}

# A field's dictionary index type when nothing sets one: INT32, the engine's
# default for every `Field` it builds.
DICT_INDEX_INT32 = vocab.ARROW_TYPE_INT32 - 1

_ARROW_NAMES = {
    value - 1: name.removeprefix("ARROW_TYPE_").lower()
    for name, value in vocab.ArrowType.items()
    if value > 0
}


def member(prefix: str, name: str) -> int:
    """The wire value of the enum member `<prefix><NAME>`."""
    return getattr(vocab, prefix + name.upper())


def arrow_id(name: str) -> int:
    """The raw Arrow type id of the Arrow type `name` (`int64` is 5)."""
    return member("ARROW_TYPE_", name) - 1


def arrow_name(type_id: int) -> str:
    """The name of the Arrow type with the raw id `type_id`."""
    return _ARROW_NAMES[type_id]


def dtype_code(name: str | None) -> int:
    """The DType code of a numeric type name; `_DT_INVALID` for None."""
    return vocab._DT_INVALID if name is None else member("_DT_", name)


def physical_dtype(arrow: str) -> int:
    """The DType code a cast to the Arrow type `arrow` carries beside it."""
    if arrow in NUMERIC_DTYPES:
        return dtype_code(arrow)
    return dtype_code(_PHYSICAL_DTYPE.get(arrow))


def field(name: str, type_id: int, nullable: bool) -> pb.WireField:
    """The field the engine builds from a name, an Arrow type and nullability
    (`Field(name, arrow_type, nullable)`, src/arrow/schema.mojo): its DType is
    the type's own for a numeric type, int64 for a timestamp, and none
    otherwise; its dictionary index type is INT32."""
    arrow = arrow_name(type_id)
    if arrow in NUMERIC_DTYPES:
        code = dtype_code(arrow)
    elif arrow in TIMESTAMP_TYPES:
        code = vocab._DT_INT64
    else:
        code = vocab._DT_INVALID
    return pb.WireField(
        name=name,
        arrow_type_id=type_id,
        dtype_code=code,
        nullable=nullable,
        dict_index_type_id=DICT_INDEX_INT32,
    )
