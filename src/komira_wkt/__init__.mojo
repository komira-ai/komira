"""`komira_wkt` — the protobuf well-known-type (WKT) runtime.

The Mojo-side runtime structs for the `google.protobuf.*` well-known types —
the concrete types a `protoc-gen-mojo`-generated client `import`s when a
`.proto` message references a WKT (`google.protobuf.Timestamp`, `Duration`,
etc.).

-- Why a separate `komira_wkt` package, not part of `komira_serde` ----------
`komira_serde` is the format-NEUTRAL trait SUBSTRATE (the `Serializable` /
`WireEncoder` / `WireDecoder` traits). `komira_wkt` is a set of CONCRETE
generated-equivalent message types. Keeping them as separate sibling
packages:
  - keeps each package single-responsibility;
  - keeps the generated client's `import` line clean and dedicated —
    `from komira_wkt import Timestamp`, not a mix into the runtime
    substrate's namespace;
  - mirrors the proto ecosystem itself: `google.protobuf.*` WKTs are their
    own proto package; `komira_wkt` is the natural Mojo analogue.
Dependency direction (cycle-free): `komira_wkt -> komira_serde` only.

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
  - Any       -> `{"@type": <type_url>, <the payload's members>}` (opaque
    here: no type registry, see any.mojo).
The `komira_serde` `Serializable` trait has ONE shared `encode[E]` body
across both backends, written with the generic `write_*_field` primitives —
it cannot itself express "a different shape on JSON than on proto-binary".
So each WKT here conforms to `komira_serde.Proto3JsonWkt` (a refinement of
`Serializable`):
  1. its `encode[E]` / `decode[D]` body is the ordinary message form — what
     runs on `PbEncoder` / `PbDecoder`;
  2. `write_proto3_json(buf)` appends the COMPLETE canonical JSON value
     (quoted where it is a string) and `read_proto3_json(JsonValue)` reads
     it back from the already-parsed value, refusing what the spec refuses.
A message field of a WKT type is written with `enc.write_wkt_field[T]` /
`write_wkt_element[T]` and read with `dec.read_wkt[T]` /
`read_into_repeated_wkt[T]` / `read_into_string_wkt_map[T]`. On the binary
backend those forward to the message arms (wire-identical); on the JSON
backend they call the two methods above. That routing is what makes
`encode_json` / `decode_json` produce and accept the canonical form — the
way mainstream protobuf libraries route their JSON codec to the WKT form.
The `to_proto3_json()` / `from_proto3_json()` string helpers remain for
standalone use (scalar text, unquoted for the string-shaped types).

Encapsulation: every WKT struct stores only owned `Int64` / `Int32` /
`String` / `List` / `Optional` fields. No `UnsafePointer`, no wildcard
origin, no `unsafe_from_address` crosses this module boundary. The
recursive `Value` / `Struct` / `ListValue` triad breaks its size cycle with
a `List[T]` 0-or-1 box (a `List` is a finitely-sized pointer+len+cap; this
is the same `Copyable`-preserving recursion break the generated code uses,
since `Serializable` requires `Copyable` and `OwnedPointer` is not).
"""

from .timestamp import Timestamp, Duration
from .any import Any

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
