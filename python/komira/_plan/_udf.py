"""User functions on the plan wire: the `UdfRef` of a `UdfSpec`, the table that
holds the plan's `UdfRef`s, and the komira/python descriptor.

A call (`WireUdfApply`) and a `MapBatches` node name a `UdfRef` by its index in
`WirePlanEnvelope.udfs`. `UdfTable` gives each distinct `UdfRef` one index: two
`UdfRef`s are the same when their canonical serialized bytes are equal, and the
indexes follow the order the encoder first meets them.

A `UdfRef` carries, for the spec it comes from:

    kind          scalar, map_batches_column, row, map_batches_frame
    code          runtime `komira/python`, the code form, the entry, one
                  `CodeDigest` per code object, descriptor version 1 and the
                  descriptor
    arg_types     scalar and map_batches_column: the field each argument
                  expression derives over the input; row and map_batches_frame:
                  the input's field of each read-set column, in read-set order
    return_type   the dtype as a nullable field named `out`; a frame's is a
                  struct field whose children are its columns
    stability, null_mode
    resources     set and left at its defaults, which let the host choose, as
                  the engine writes it
    read_set      row and map_batches_frame only, set even when empty

The komira/python runtime carries int32, int64 and float64 only, so any other
argument or read-set column type is refused by name.

The descriptor is the protobuf `PythonDescriptor` v1 that
docs/design/udf_python_worker.md section 6 declares (no .proto file holds it
yet), written by hand in canonical form
(fields ascending, shortest varints, no field at its default except
`recorded_fields`): 1 entry, 2 shapes (the kind's one shape bit), 6
recorded_fields (row and map_batches_frame only, emitted even when empty: the
read-set columns' fields, ascending by name), 7 batch_format. Fields 3 and 4
are not written: the runtime does not read them and the `UdfRef` already
carries the types.
"""

from __future__ import annotations

from collections.abc import Sequence

from komira._errors import UnsupportedOperation
from komira._ops._expr import UdfSpec
from komira._ops._vocab import UDF_READ_SET_KINDS

from ._wire import arrow_id, arrow_name, field, pb

__all__ = ["RETURN_NAME", "RUNTIME", "UdfTable", "descriptor", "udf_ref"]

RUNTIME = "komira/python"
DESCRIPTOR_VERSION = 1
# The name of a `UdfRef`'s return field: a column call is named by the alias
# above it, and a frame's columns are the children.
RETURN_NAME = "out"

_KINDS = {
    "scalar": pb.SCALAR,
    "map_batches_column": pb.MAP_BATCHES_COLUMN,
    "row": pb.ROW,
    "map_batches_frame": pb.MAP_BATCHES_FRAME,
}
_FORMS = {"package": pb.PACKAGE, "bundle": pb.BUNDLE}
_STABILITIES = {
    "immutable": pb.UDF_STABILITY_IMMUTABLE,
    "stable": pb.UDF_STABILITY_STABLE,
    "volatile": pb.UDF_STABILITY_VOLATILE,
}
_NULL_MODES = {"manual": pb.UDF_NULL_MANUAL, "propagate": pb.UDF_NULL_PROPAGATE}

# KOMIRA_UDF_SHAPE_* (src/udf_abi/komira_udf_runtime.h).
_SHAPES = {"scalar": 1 << 0, "row": 1 << 1, "map_batches_column": 1 << 2, "map_batches_frame": 1 << 3}
# BatchFormat (docs/design/udf_python_worker.md section 6).
_BATCH_FORMATS = {"values": 1, "arrow": 2}

_CARRIED = frozenset(arrow_id(name) for name in ("int32", "int64", "float64"))
_STRUCT = arrow_id("struct")


def _varint(value: int) -> bytes:
    out = bytearray()
    while value > 0x7F:
        out.append((value & 0x7F) | 0x80)
        value >>= 7
    out.append(value)
    return bytes(out)


def _len_field(number: int, payload: bytes) -> bytes:
    return _varint(number << 3 | 2) + _varint(len(payload)) + payload


def _varint_field(number: int, value: int) -> bytes:
    return _varint(number << 3) + _varint(value)


def descriptor(spec: UdfSpec, recorded: Sequence[pb.WireField]) -> bytes:
    """The canonical `PythonDescriptor` bytes of `spec`. `recorded` are the
    read-set columns' fields, written only for a row or frame function."""
    out = _len_field(1, spec.entry.encode("utf-8")) + _varint_field(2, _SHAPES[spec.kind])
    if spec.kind in UDF_READ_SET_KINDS:
        message = pb.RecordedFields(fields=recorded)
        out += _len_field(6, message.SerializeToString(deterministic=True))
    return out + _varint_field(7, _BATCH_FORMATS[spec.batch_format])


def _return_field(spec: UdfSpec) -> pb.WireField:
    if spec.kind != "map_batches_frame":
        return field(RETURN_NAME, arrow_id(spec.return_type), True)
    out = field(RETURN_NAME, _STRUCT, True)
    for name, dtype in spec.return_type:
        out.children.append(field(name, arrow_id(dtype), True))
    return out


def _check_carried(spec: UdfSpec, fields: Sequence[pb.WireField]) -> None:
    for i, f in enumerate(fields):
        if f.arrow_type_id not in _CARRIED:
            what = f"column '{spec.read_set[i]}'" if spec.read_set is not None else f"argument {i}"
            raise UnsupportedOperation(
                f"{spec.name}: the {what} has the Arrow type {arrow_name(f.arrow_type_id)}, "
                "and the komira/python runtime carries only int32, int64 and float64"
            )


def udf_ref(spec: UdfSpec, arg_fields: Sequence[pb.WireField]) -> pb.UdfRef:
    """The `UdfRef` of `spec` called on `arg_fields`: the fields of its
    argument expressions, or, for a row or frame function, of the columns of
    its read set in the set's order."""
    _check_carried(spec, arg_fields)
    ref = pb.UdfRef(
        kind=_KINDS[spec.kind],
        stability=_STABILITIES[spec.stability],
        null_mode=_NULL_MODES[spec.null_mode],
    )
    ref.resources.SetInParent()
    ref.code.runtime = RUNTIME
    ref.code.form = _FORMS[spec.form]
    ref.code.entry = spec.entry
    for role, digest in spec.code:
        ref.code.code.add(role=role, sha256=digest)
    ref.code.descriptor_version = DESCRIPTOR_VERSION
    ref.code.descriptor = descriptor(spec, arg_fields)
    ref.arg_types.extend(arg_fields)
    ref.return_type.CopyFrom(_return_field(spec))
    if spec.read_set is not None:
        ref.read_set.SetInParent()
        ref.read_set.columns.extend(spec.read_set)
    return ref


class UdfTable:
    """The `UdfRef`s of a plan, one per distinct message, in the order they
    were first added."""

    def __init__(self) -> None:
        self.refs: list[pb.UdfRef] = []
        self._index: dict[bytes, int] = {}

    def add(self, ref: pb.UdfRef) -> int:
        """The index of `ref`, added when no equal `UdfRef` is held."""
        key = ref.SerializeToString(deterministic=True)
        if key not in self._index:
            self._index[key] = len(self.refs)
            self.refs.append(ref)
        return self._index[key]
