# =============================================================================
# field_mask.mojo — google.protobuf.FieldMask.
# =============================================================================
#
#   message FieldMask { repeated string paths = 1; }
#
# A set of field-path selectors — used by partial-update / read-mask APIs.
#
# Wire form (protobuf-binary): the `repeated string paths` field.
# Canonical JSON form (proto3 JSON mapping): a SINGLE STRING — the paths
# joined by `,`, each path converted to lowerCamelCase (`"foo_bar,baz"` <->
# the wire paths `["foo_bar", "baz"]` rendered JSON-side as `"fooBar,baz"`).
#
# NOTE on the snake_case<->lowerCamelCase conversion: the proto3-JSON spec
# mandates it for the canonical form. `from_proto3_json` converts back to
# snake_case so a JSON round-trip preserves the wire `paths`. A path segment
# that has no underscore is unchanged by either direction.
# =============================================================================

from komira_proto_codec import (
    Serializable,
    Proto3JsonWkt,
    WireEncoder,
    WireDecoder,
)
from komira_json import JsonValue, JSON_STRING, write_json_string


@fieldwise_init
struct FieldMask(Proto3JsonWkt, Copyable, Movable):
    """`google.protobuf.FieldMask` — a set of field-path selectors."""

    var paths: List[String]

    def __init__(out self, *, copy: Self):
        """Deep copy: each field via its own `.copy()` (see `structpb.mojo`)."""
        self.paths = copy.paths.copy()

    @staticmethod
    def new() -> Self:
        """An empty mask."""
        return Self(List[String]())

    # -- the `Serializable` protobuf-binary surface -----------------------

    def encode[E: WireEncoder](self, mut enc: E) raises:
        """Encode the `repeated string paths` field."""
        for i in range(len(self.paths)):
            enc.write_string_field(1, "paths", self.paths[i])

    @staticmethod
    def decode[D: WireDecoder](mut dec: D) raises -> Self:
        """Decode the `repeated string paths` field: one element per
        occurrence on the binary wire, the whole JSON array under the one
        `paths` key in the proto3-JSON message form."""
        var paths = List[String]()
        while True:
            var key = dec.next_field()
            if key.end:
                break
            if key.field_no == 1 or key.json_name == "paths":
                dec.read_into_repeated_string(paths)
            else:
                dec.skip()
        return Self(paths^)

    # -- the canonical-JSON surface ---------------------------------------

    def to_proto3_json(self) raises -> String:
        """The comma-joined lowerCamelCase path string (raw, unquoted).

        REFUSES a path whose camelCase form would not convert back to the
        same path (an uppercase letter, `__`, or `_` before a non-letter):
        the JSON form would silently name a DIFFERENT field."""
        var out = String("")
        for i in range(len(self.paths)):
            if i > 0:
                out += ","
            var camel = _snake_to_camel(self.paths[i])
            if _camel_to_snake_bytes(_bytes_of(camel)) != self.paths[i]:
                raise Error(
                    "WktError: FieldMask path does not round-trip through"
                    + " lowerCamelCase: " + self.paths[i]
                )
            out += camel
        return out

    @staticmethod
    def from_proto3_json(text: String) raises -> Self:
        """Parse a comma-joined lowerCamelCase path string back to the wire
        `paths` (each segment converted to snake_case).

        REFUSES an underscore in the input: the JSON form is camelCase, and
        `log_name` would otherwise become a different path than the sender
        meant (the spec rejects it for that reason)."""
        var paths = List[String]()
        if text.byte_length() == 0:
            return Self(paths^)
        var cur = List[UInt8]()
        var bytes = text.as_bytes()
        for i in range(len(bytes)):
            var b = bytes[i]
            if b == 0x5F:  # '_'
                raise Error(
                    "WktError: FieldMask JSON path contains '_': " + text
                )
            if b == 0x2C:  # ','
                paths.append(_camel_to_snake_bytes(cur))
                cur = List[UInt8]()
            else:
                cur.append(b)
        paths.append(_camel_to_snake_bytes(cur))
        return Self(paths^)

    # -- `Proto3JsonWkt`: the codec arms call these ----------------------

    def write_proto3_json(self, mut buf: List[UInt8]) raises:
        write_json_string(buf, self.to_proto3_json())

    @staticmethod
    def read_proto3_json(v: JsonValue) raises -> Self:
        if v.kind != JSON_STRING:
            raise Error("WktError: FieldMask JSON must be a string")
        return Self.from_proto3_json(v.text)


# =============================================================================
# lowerCamelCase <-> snake_case helpers (ASCII).
#
# These iterate raw UTF-8 bytes and accumulate into a `List[UInt8]`, then
# materialize the `String` once — UTF-8-safe (a non-ASCII continuation byte
# is not `_` / `A`..`Z` / `a`..`z`, so it always passes through verbatim).
# =============================================================================


def _snake_to_camel(s: String) -> String:
    """`foo_bar` -> `fooBar`. A leading underscore and non-ASCII bytes pass
    through unchanged."""
    var out = List[UInt8]()
    var bytes = s.as_bytes()
    var upper_next = False
    for i in range(len(bytes)):
        var b = bytes[i]
        if b == 0x5F:  # '_'
            upper_next = True
            continue
        if upper_next and b >= 0x61 and b <= 0x7A:  # 'a'..'z'
            out.append(b - 0x20)
        else:
            out.append(b)
        upper_next = False
    return String(unsafe_from_utf8=Span(out))


def _camel_to_snake_bytes(bytes: List[UInt8]) -> String:
    """`fooBar` -> `foo_bar`. An ASCII uppercase byte becomes `_` + lowercase;
    non-ASCII bytes pass through unchanged."""
    var out = List[UInt8]()
    for i in range(len(bytes)):
        var b = bytes[i]
        if b >= 0x41 and b <= 0x5A:  # 'A'..'Z'
            out.append(0x5F)  # '_'
            out.append(b + 0x20)
        else:
            out.append(b)
    return String(unsafe_from_utf8=Span(out))


def _bytes_of(s: String) -> List[UInt8]:
    """A `String`'s UTF-8 bytes as an owned `List[UInt8]`."""
    var out = List[UInt8]()
    var src = s.as_bytes()
    for i in range(len(src)):
        out.append(src[i])
    return out^
