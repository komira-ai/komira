# =============================================================================
# codec.mojo — top-level encode / decode convenience entry points.
# =============================================================================
#
# `Serializable.encode[E]` / `decode[D]` operate on a
# `WireEncoder` / `WireDecoder`. These free functions are the ergonomic
# wrappers a caller (and the generated client) uses — `encode_proto(msg)` ->
# bytes, `decode_proto[T](bytes)` -> T, and the JSON twins.
#
# They are deliberately format-CONCRETE (one fn per backend) rather than a
# single `encode[E]`: a caller that wants protobuf-binary should not have to
# spell the encoder type, and the generated client picks the format at
# comptime anyway. Each still monomorphizes to a zero-cost inlined path.
#
# Encapsulation: owned `List[UInt8]` / `String` in and out; no pointers.
# =============================================================================

from .wire_format import Serializable
from .proto_binary import PbEncoder, PbDecoder
from .proto3_json import JsonEncoder, JsonDecoder, UnknownFields


# =============================================================================
# protobuf-binary entry points.
# =============================================================================


def encode_proto[T: Serializable](msg: T) raises -> List[UInt8]:
    """Encode `msg` to protobuf-binary bytes."""
    var enc = PbEncoder()
    msg.encode[PbEncoder](enc)
    return enc.into_buf()


def decode_proto[T: Serializable](var bytes: List[UInt8]) raises -> T:
    """Decode a `T` from protobuf-binary bytes."""
    var dec = PbDecoder(bytes^)
    return T.decode[PbDecoder](dec)


# =============================================================================
# proto3-canonical-JSON entry points.
# =============================================================================


def encode_json[T: Serializable](msg: T) raises -> String:
    """Encode `msg` to a proto3-canonical-JSON string."""
    var enc = JsonEncoder()
    msg.encode[JsonEncoder](enc)
    enc.finish()
    return enc^.into_string()


def decode_json[T: Serializable](text: String) raises -> T:
    """Decode a `T` from a proto3-canonical-JSON string, STRICTLY.

    REFUSES — naming the offending token, its JSON path and its source line —
    an object key that matches no field of `T` and an enum name that matches
    no declared value. That is the proto3-JSON spec's stated parser default
    and it is what makes a typo in an operator- or LLM-authored document a
    loud error instead of a differently-shaped message.

    Use `decode_json_lenient` — and only it — when the bytes were produced by
    a DIFFERENT BUILD of the schema."""
    var dec = JsonDecoder.from_text(text)
    return T.decode[JsonDecoder](dec)


def decode_json_lenient[T: Serializable](text: String) raises -> T:
    """`decode_json`, IGNORING anything the schema does not declare.

    ⛔ THIS IS THE FORWARD-COMPAT DIRECTION AND NOTHING ELSE: a client
    reading a response from a peer that may be running a NEWER schema, where
    an unrecognised field means the peer added one. Unknown keys are dropped
    and an unknown enum name folds to the zero value — both SILENTLY, which
    is precisely why this is a named entry point rather than a flag with a
    default. On anything a person or a model authored, use `decode_json`."""
    var dec = JsonDecoder.from_text_lenient(text)
    return T.decode[JsonDecoder](dec)
