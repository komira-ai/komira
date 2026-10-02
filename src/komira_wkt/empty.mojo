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

from komira_proto_codec import Serializable, WireEncoder, WireDecoder


@fieldwise_init
struct Empty(Serializable, Copyable, Movable, ImplicitlyCopyable):
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
