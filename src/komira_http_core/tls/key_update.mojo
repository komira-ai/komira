# =============================================================================
# src/komira_http_core/tls/key_update.mojo — TLS 1.3 key update value types
# =============================================================================
#
# The values `TlsConnection.request_key_update` takes and
# `TlsConnection.key_update_counts` returns (s2n_shim.mojo). They hold no
# pointer and no s2n handle; the FFI declarations are in ffi.mojo.
#
# A TLS 1.3 KeyUpdate (RFC 8446 section 4.6.3) replaces the sender's traffic
# key on a live connection. With s2n-tls each side updates only its own
# sending key: s2n 1.5.6 refuses to ask the peer to update its key too
# (`PeerKeyUpdate.REQUESTED` fails with S2N_ERR_INVALID_ARGUMENT), though it
# honours such a request when a peer sends one.
# =============================================================================

from komira_http_core.tls.ffi import (
    S2N_KEY_UPDATE_NOT_REQUESTED,
    S2N_KEY_UPDATE_REQUESTED,
)


struct PeerKeyUpdate(Equatable, ImplicitlyCopyable, Movable):
    """Whether a key update also asks the peer to update its sending key
    (s2n_peer_key_update). s2n 1.5.6 accepts only `NOT_REQUESTED`."""

    var _value: Int32

    comptime NOT_REQUESTED = PeerKeyUpdate(S2N_KEY_UPDATE_NOT_REQUESTED)
    comptime REQUESTED = PeerKeyUpdate(S2N_KEY_UPDATE_REQUESTED)

    def __init__(out self, value: Int32):
        self._value = value

    def __eq__(self, other: Self) -> Bool:
        return self._value == other._value

    def __ne__(self, other: Self) -> Bool:
        return self._value != other._value

    def raw(self) -> Int32:
        """The C enum value handed to s2n_connection_request_key_update."""
        return self._value


struct KeyUpdateCounts(Equatable, ImplicitlyCopyable, Movable):
    """How many times one connection's traffic keys were updated.

    `sent`: this side's sending key (one per KeyUpdate it sent).
    `received`: this side's receiving key (one per KeyUpdate it received
    from the peer). s2n counts to 255 and then stays there.
    """

    var sent: Int
    var received: Int

    def __init__(out self, sent: Int, received: Int):
        self.sent = sent
        self.received = received

    def __eq__(self, other: Self) -> Bool:
        return self.sent == other.sent and self.received == other.received

    def __ne__(self, other: Self) -> Bool:
        return not (self == other)

