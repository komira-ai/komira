# =============================================================================
# empty.mojo — google.protobuf.Empty.
# =============================================================================
#
#   message Empty {}
#
# The canonical empty message — a service RPC with no request or no response
# payload uses it. It has no fields:
#   - protobuf-binary: zero bytes.
#   - canonical JSON (proto3 JSON mapping): the empty object `{}`.
# =============================================================================

from komira_serde import (
    Serializable,
    Proto3JsonWkt,
    WireEncoder,
    WireDecoder,
    JsonValue,
)


@fieldwise_init
struct Empty(Proto3JsonWkt, Copyable, Movable, ImplicitlyCopyable):
    """`google.protobuf.Empty` — a message with no fields."""

    @staticmethod
    def new() -> Self:
        """The (only) `Empty` value."""
        return Self()

    # -- the `Serializable` protobuf-binary surface -----------------------

    def encode[E: WireEncoder](self, mut enc: E) raises:
        """An empty message writes no fields."""
        pass

    @staticmethod
    def decode[D: WireDecoder](mut dec: D) raises -> Self:
        """Drain any (unknown) fields and return the singleton value."""
        while True:
            var key = dec.next_field()
            if key.end:
                break
            dec.skip()
        return Self()

    # -- the canonical-JSON surface ---------------------------------------

    def to_proto3_json(self) -> String:
        """The canonical JSON form of `Empty` — the empty object `{}`."""
        return String("{}")

    @staticmethod
    def from_proto3_json(text: String) -> Self:
        """Parse `{}` — `Empty` carries no state, so any input yields the
        singleton value."""
        return Self()

    # -- `Proto3JsonWkt`: the codec arms call these ----------------------

    def write_proto3_json(self, mut buf: List[UInt8]) raises:
        buf.append(0x7B)  # '{'
        buf.append(0x7D)  # '}'

    @staticmethod
    def read_proto3_json(v: JsonValue) raises -> Self:
        """`{}` and nothing else: a member in an `Empty` is a field no
        `Empty` has, which the strict decoder refuses everywhere else."""
        if not v.is_object() or len(v.obj_keys) != 0:
            raise Error("WktError: Empty JSON must be the empty object {}")
        return Self()
