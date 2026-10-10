"""`komira_proto_codec` — the `Serializable` / `WireFormat` codec runtime.

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
                       JSON backend (including the map mapping), on
                       `komira_json` (the JSON value, parser and writers)
                       and `komira_encoding` (base64 for `bytes`).
  - proto3_json_float.mojo: `write_proto3_json_f32` / `read_proto3_json_f32`
                       — the proto3-JSON form of a float32 (shortest
                       round-trip decimal, the non-finite strings, the
                       float32 range check on read), shared by the `float`
                       field paths and `google.protobuf.FloatValue`.
  - float32_parse.mojo: `parse_decimal_f32` — a decimal correctly rounded
                       straight to float32 (the reader's core).
  - float32_bignum.mojo: the fixed-width big integers both use.
  - codec.mojo       : `encode_proto` / `decode_proto` / `encode_json` /
                       `decode_json` — top-level convenience entry points.

Dependency direction (cycle-free):
  komira_proto_codec -> komira_protobuf  (ProtoBinaryWire backend)
  komira_proto_codec -> komira_json      (Proto3JsonWire backend)
  komira_proto_codec -> komira_encoding  (base64 for proto3-JSON `bytes`)
  NOT komira_proto_codec -> the gRPC runtime (which consumes this package)

All three dependencies are small and have no dependencies of their own, so
every generated client can import this package cheaply.

Encapsulation: the public API exposes only typed values, owned
`List`/`String`, `Span` views, and the codec handle structs. No
UnsafePointer crosses the module boundary; no wildcard origins; no
`unsafe_from_address`.
"""

from .wire_format import (
    ProtoEnum,
    ProtoNullValueEnum,
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

from .proto3_json import JsonEncoder, JsonDecoder, UnknownFields
from .proto3_json_float import (
    read_proto3_json_f32,
    read_proto3_json_f64,
    write_proto3_json_f32,
    write_proto3_json_f64,
)
from .float32_parse import parse_decimal_f32
from .float64_parse import parse_decimal_f64

from .codec import (
    encode_proto,
    decode_proto,
    encode_json,
    decode_json,
    decode_json_lenient,
)
