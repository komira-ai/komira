"""`komira_wkt` — the protobuf well-known-type (WKT) runtime.

The Mojo-side runtime structs for the `google.protobuf.*` well-known types —
the concrete types a `protoc-gen-mojo`-generated client `import`s when a
`.proto` message references a WKT (`google.protobuf.Timestamp`, `Duration`,
etc.).

-- Why a separate `komira_wkt` package, not part of `komira_proto_codec` ----------
`komira_proto_codec` is the format-NEUTRAL trait SUBSTRATE (the `Serializable` /
`WireEncoder` / `WireDecoder` traits). `komira_wkt` is a set of CONCRETE
generated-equivalent message types. Keeping them as separate sibling
packages:
  - keeps each package single-responsibility;
  - keeps the generated client's `import` line clean and dedicated —
    `from komira_wkt import Timestamp`, not a mix into the runtime
    substrate's namespace;
  - mirrors the proto ecosystem itself: `google.protobuf.*` WKTs are their
    own proto package; `komira_wkt` is the natural Mojo analogue.
Dependency direction (cycle-free): `komira_wkt -> komira_proto_codec`, plus the leaf libraries `komira_json` and `komira_encoding`.

-- The proto3 canonical-JSON special case -----------------------------------
A WKT does NOT serialize to proto3-canonical-JSON as a `{field: value}`
object. The protobuf JSON mapping mandates a SPECIAL JSON form per WKT:
  - Timestamp -> an RFC-3339 string  ("1972-01-01T10:00:20.021Z")
  - Duration  -> a "<seconds>[.<nanos>]s" string  ("1.000340012s")
  - Empty     -> the empty object `{}`
  - the scalar wrappers (Int32Value, StringValue, ...) -> the bare scalar's
    JSON form (a number / string / bool — NOT an object).
  - FieldMask -> a comma-joined lowerCamelCase path string.
  - Struct / Value / ListValue -> the literal JSON value they model.
The `komira_proto_codec` `Serializable` trait has ONE shared `encode[E]` body
across both backends, written with the generic `write_*_field` primitives —
it cannot itself express "a different shape on JSON than on proto-binary".
So each WKT here:
  1. conforms to `Serializable` for the protobuf-BINARY wire form (its
     `encode[E]` / `decode[D]` body uses the standard field primitives —
     correct + round-trip-safe on `PbEncoder` / `PbDecoder`);
  2. ALSO exposes explicit `to_proto3_json()` / `from_proto3_json()` methods
     that implement the canonical-JSON special form.
This is exactly how mainstream protobuf libraries handle WKTs (a custom JSON
codec separate from the generic message codec). It needs no change to the
`Serializable` trait surface: no additive parallel trait API, no trait
reshape.

Encapsulation: every WKT struct stores only owned `Int64` / `Int32` /
`String` / `List` / `Optional` fields. No `UnsafePointer`, no wildcard
origin, no `unsafe_from_address` crosses this module boundary. The
recursive `Value` / `Struct` / `ListValue` triad breaks its size cycle with
a `List[T]` 0-or-1 box (a `List` is a finitely-sized pointer+len+cap; this
is the same `Copyable`-preserving recursion break the generated code uses,
since `Serializable` requires `Copyable` and `OwnedPointer` is not).
"""

from .timestamp import Timestamp, Duration

from .empty import Empty

from .wrappers import (
    DoubleValue,
    FloatValue,
    Int64Value,
    UInt64Value,
    Int32Value,
    UInt32Value,
    BoolValue,
    StringValue,
    BytesValue,
)

from .field_mask import FieldMask

from .structpb import (
    Struct,
    Value,
    ListValue,
    NullValue,
    NULL_VALUE,
    VALUE_KIND_UNSET,
    VALUE_KIND_NULL,
    VALUE_KIND_NUMBER,
    VALUE_KIND_STRING,
    VALUE_KIND_BOOL,
    VALUE_KIND_STRUCT,
    VALUE_KIND_LIST,
)
