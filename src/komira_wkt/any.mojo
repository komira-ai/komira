# =============================================================================
# any.mojo — google.protobuf.Any, OPAQUE (no type registry).
# =============================================================================
#
#   message Any { string type_url = 1; bytes value = 2; }
#
# An `Any` carries a message of a type named only at run time. The two wire
# forms carry that message differently:
#
#   - protobuf-binary: `type_url` + the message's serialized BYTES (`value`);
#   - proto3-JSON:     ONE object — `"@type": <type_url>` plus the message's
#                      own JSON members inline (`{"@type": "...", "a": 1}`).
#
# Converting one form into the other means decoding the payload as its
# concrete type, which needs a TYPE REGISTRY. `komira_wkt` has none, so this
# `Any` is opaque: it keeps whichever form it was given and round-trips it
# unchanged —
#
#   - read from binary -> `type_url` + `value` bytes, re-encoded verbatim;
#   - read from JSON   -> `type_url` + every OTHER member, kept as an opaque
#                         `JsonValue` object and re-encoded verbatim (member
#                         order and unknown content preserved).
#
# A transcode across forms is REFUSED, naming the type, never guessed: an
# `Any` that came from JSON with a payload cannot be written as binary, and
# one with payload bytes cannot be written as JSON. An `Any` with a type and
# no payload is representable in both. (The WKT-valued special case,
# `{"@type": ".../google.protobuf.Duration", "value": "1s"}`, is just another
# opaque member set here.)
# =============================================================================

from komira_serde import (
    Serializable,
    Proto3JsonWkt,
    WireEncoder,
    WireDecoder,
    JsonValue,
    JSON_STRING,
    write_json_string,
)


struct Any(Proto3JsonWkt, Copyable, Movable):
    """`google.protobuf.Any` — a type URL plus an opaque payload."""

    var type_url: String
    """`type.googleapis.com/<full.message.Name>` (any host is allowed)."""
    var value: List[UInt8]
    """The payload's protobuf-binary bytes (when it came from binary)."""
    var json_members: JsonValue
    """The payload's JSON members other than `@type` (when it came from
    JSON): always an object, empty when there are none."""

    def __init__(out self, type_url: String, var value: List[UInt8]):
        """An `Any` in its binary form: a type and the payload bytes."""
        self.type_url = type_url
        self.value = value^
        self.json_members = JsonValue.empty_object()

    def __init__(
        out self,
        type_url: String,
        var value: List[UInt8],
        var json_members: JsonValue,
    ):
        """An `Any` with every field given (`json_members` must be an
        object)."""
        self.type_url = type_url
        self.value = value^
        self.json_members = json_members^

    @staticmethod
    def new() -> Self:
        """The empty `Any` (no type, no payload)."""
        return Self(String(""), List[UInt8]())

    def has_json_payload(self) -> Bool:
        """True iff the payload is held in its JSON form."""
        return len(self.json_members.obj_keys) > 0

    # -- the `Serializable` protobuf-binary surface -----------------------

    def encode[E: WireEncoder](self, mut enc: E) raises:
        """The two-field binary form. REFUSES a JSON-form payload."""
        if self.has_json_payload():
            raise Error(
                "WktError: Any of type '" + self.type_url
                + "' holds a JSON payload; writing it as protobuf-binary"
                + " needs a type registry, which komira_wkt does not have"
            )
        if self.type_url != "":
            enc.write_string_field(1, "typeUrl", self.type_url)
        if len(self.value) > 0:
            enc.write_bytes_field(2, "value", self.value)

    @staticmethod
    def decode[D: WireDecoder](mut dec: D) raises -> Self:
        var type_url = String("")
        var value = List[UInt8]()
        while True:
            var key = dec.next_field()
            if key.end:
                break
            if key.field_no == 1 or key.json_name == "typeUrl":
                type_url = dec.read_string()
            elif key.field_no == 2 or key.json_name == "value":
                value = dec.read_bytes()
            else:
                dec.skip()
        return Self(type_url, value^)

    # -- `Proto3JsonWkt`: the codec arms call these ----------------------

    def write_proto3_json(self, mut buf: List[UInt8]) raises:
        """`{"@type": <type_url>, <the opaque members>}`. REFUSES binary
        payload bytes (rendering them needs the concrete type)."""
        if len(self.value) > 0:
            raise Error(
                "WktError: Any of type '" + self.type_url
                + "' holds protobuf-binary payload bytes; writing it as JSON"
                + " needs a type registry, which komira_wkt does not have"
            )
        buf.append(0x7B)  # '{'
        var first = True
        if self.type_url != "":
            write_json_string(buf, String("@type"))
            buf.append(0x3A)  # ':'
            write_json_string(buf, self.type_url)
            first = False
        ref m = self.json_members
        for i in range(len(m.obj_keys)):
            if not first:
                buf.append(0x2C)  # ','
            first = False
            write_json_string(buf, m.obj_keys[i])
            buf.append(0x3A)  # ':'
            var text = m.children[i].serialize()
            var b = text.as_bytes()
            for j in range(len(b)):
                buf.append(b[j])
        buf.append(0x7D)  # '}'

    @staticmethod
    def read_proto3_json(v: JsonValue) raises -> Self:
        """An object with a string `@type` and any other members, which are
        kept opaque. `{}` is the empty `Any`; members without an `@type` are
        refused (there is no type to carry them under)."""
        if not v.is_object():
            raise Error("WktError: Any JSON must be an object")
        var type_url = String("")
        var seen_type = False
        var members = JsonValue.empty_object()
        for i in range(len(v.obj_keys)):
            if v.obj_keys[i] == "@type":
                if seen_type:
                    raise Error("WktError: Any JSON has '@type' twice")
                if v.children[i].kind != JSON_STRING:
                    raise Error("WktError: Any '@type' must be a string")
                type_url = v.children[i].text
                seen_type = True
            else:
                members.set_member(v.obj_keys[i], v.children[i].copy())
        if not seen_type and len(members.obj_keys) > 0:
            raise Error(
                "WktError: Any JSON has members but no '@type' to name them"
            )
        return Self(type_url, List[UInt8](), members^)
