# =============================================================================
# src/komira_http/codec/h2/alpn.mojo — ALPN protocol identifiers
# =============================================================================
#
#
# Wires `h2` into the ALPN advertise list for HTTPS servers. The TLS
# shim's `TlsConfig.set_alpn_protocols([h2, http/1.1])` does the wire
# work; this module provides the canonical protocol identifier strings +
# a comparison helper for the post-handshake check.
#
# No UnsafePointer; pure constants + helper.
# =============================================================================


def ALPN_PROTOCOL_H2() -> String:
    """The ALPN protocol identifier for HTTP/2 over TLS (RFC 7301 / 9113)."""
    return String("h2")


def ALPN_PROTOCOL_HTTP11() -> String:
    """The ALPN protocol identifier for HTTP/1.1 over TLS (RFC 7301 / 9112)."""
    return String("http/1.1")


def is_h2_negotiated(negotiated: String) -> Bool:
    """True iff the ALPN-negotiated protocol string is `h2`.

    Caller invokes after the TLS handshake completes:
        var proto = tls_stream.negotiated_protocol()
        if is_h2_negotiated(proto):
            # pivot to h2 codec path
        else:
            # h1 plaintext codec
    """
    return negotiated == String("h2")
