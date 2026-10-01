"""`komira_serde` — the `Serializable` / `WireFormat` codec runtime.

The Mojo-side substrate every generated message struct conforms to: a
message is described ONCE (`Serializable`) and serializes as
protobuf-binary *or* proto3-canonical-JSON, with the format chosen at
COMPTIME — zero runtime branching, zero dynamic dispatch, no trampoline, no
fn-ptr, no vtable.

Modules:
  - wire_format.mojo : the `Serializable` + `WireEncoder` + `WireDecoder`
                       traits, `Proto3JsonWkt` (a well-known type's
                       canonical-JSON hook) + the `FieldKey` decode-loop handle.
  - proto_binary.mojo: `PbEncoder` / `PbDecoder` — the protobuf-binary
                       backend, delegating to the `komira_protobuf`
                       primitives. Carries the POOLED SCRATCH BUFFER for
                       `write_message_field` framing.
  - proto3_json.mojo : `JsonEncoder` / `JsonDecoder` — the proto3-canonical-
                       JSON backend (including the map mapping).
  - json_number.mojo : the direct-byte JSON number writers the JSON encoder
                       appends with.
  - json_value.mojo  : a self-contained JSON object scanner for the JSON
                       decode side.
  - base64.mojo      : RFC 4648 §4 standard base64 (proto3-JSON `bytes`).
  - codec.mojo       : `encode_proto` / `decode_proto` / `encode_json` /
                       `decode_json` — top-level convenience entry points.

Dependency direction (cycle-free):
  komira_serde -> komira_protobuf  (ProtoBinaryWire backend)
  NOT komira_serde -> the gRPC runtime (which consumes this package)

Its only first-party dependency is `komira_protobuf`, so every generated
client can import it cheaply.

Encapsulation: the public API exposes only typed values, owned
`List`/`String`, `Span` views, and the codec handle structs. No
UnsafePointer crosses the module boundary; no wildcard origins; no
`unsafe_from_address`.
"""

from .wire_format import (
    ProtoEnum,
    Serializable,
    Proto3JsonWkt,
    WireEncoder,
    WireDecoder,
    FieldKey,
)

# `PB_MAX_DECODE_DEPTH` / `PB_DECODE_TOO_DEEP` are exported so the bound can be
# FALSIFIED from outside this package — a recursion bound nothing can assert
# against by name is a bound that can be deleted with nothing going red.
from .proto_binary import (
    PbEncoder,
    PbDecoder,
    PB_MAX_DECODE_DEPTH,
    PB_DECODE_TOO_DEEP,
)

from .proto3_json import (
    JsonEncoder,
    JsonDecoder,
    UnknownFields,
    write_json_string,
)
# The JSON number writers the encoder uses, for a `Proto3JsonWkt` body that
# writes a number (one formatter, so a WKT number and a plain double field
# render byte-identically).
from .json_number import write_i64_dec, write_f64_dtoa

from .json_value import (
    JsonValue,
    parse_json_value,
    JSON_NULL,
    JSON_BOOL,
    JSON_NUMBER,
    JSON_STRING,
    JSON_ARRAY,
    JSON_OBJECT,
)

from .base64 import base64_encode, base64_decode

from .codec import (
    encode_proto,
    decode_proto,
    encode_json,
    decode_json,
    decode_json_lenient,
)
