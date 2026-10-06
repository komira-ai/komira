# =============================================================================
# komira_gcp_firestore/firestore_endpoint.mojo — where the Firestore client
#   dials: the public endpoint, or an emulator.
# =============================================================================
#
# The document client (firestore_client.mojo) is the generated REST client of
# komira_gcp_firestore_v1, which takes its host, port and scheme from
# `set_rest_endpoint`. This module resolves a caller's `host[:port]` override
# and insecure flag into those three (`FirestoreEndpoint`), and builds the TLS
# connector for a TLS endpoint (`build_firestore_tls_connector`). It reads no
# environment: the caller passes the override.
#
# The connector type follows the scheme. The public endpoint (and a TLS
# terminator in front of an emulator) is https over
# `TlsConnector[KernelTcpConnector]`; the Firestore emulator itself serves
# plaintext HTTP/1.1, so a client of it is a
# `FirestoreClient[KernelTcpConnector, ...]` (the HttpClient refuses an http
# URL over a TLS connector, and an https one over a plaintext connector).
# =============================================================================

from komira_http_core.transport.kernel_tcp import KernelTcpConnector
from komira_http_client.pool import VERIFY_SKIP
from komira_http_client.tls_connector import (
    TlsConnector,
    build_public_ca_tls_connector,
)
from komira_http_core.tls.s2n_shim import TlsConfig


# =============================================================================
# §0 — the Firestore REST endpoint facts.
# =============================================================================

comptime FIRESTORE_HOST: String = "firestore.googleapis.com"
comptime FIRESTORE_PORT: UInt16 = 443

# The `gcloud emulators firestore` default REST port — the fallback when an
# insecure endpoint override omits the `:port` (a bare host). The emulator arm normally supplies an explicit `host:port`.
comptime FIRESTORE_EMULATOR_DEFAULT_PORT: UInt16 = 8080

# =============================================================================
# §0b — the endpoint a caller overrides (an emulator, or a TLS terminator).
# =============================================================================
#
# DEFAULT (no override): firestore.googleapis.com:443, https over a public-CA
# TLS connector. With an override, `insecure` says which emulator shape it is:
#
#   * The Firestore emulator (`gcloud emulators firestore`) speaks PLAINTEXT
#     HTTP/1.1: `insecure = True` is an http:// dial over a
#     KernelTcpConnector, and the client is built over that connector type.
#   * A TLS terminator in front of the emulator (self-signed): an https dial
#     over `build_firestore_tls_connector(host, insecure=True)`, which skips
#     peer verification; the connector type stays the production one.
# A bearer token rides every request either way.
# =============================================================================


struct FirestoreEndpoint(Copyable, Movable, Deinitable):
    """The resolved Firestore REST endpoint: host + port + whether to dial
    PLAINTEXT http:// (the local emulator) vs https:// TLS (the cloud). A flat
    POD value (trivially destructible: String + UInt16 + Bool; no pointer / wildcard
    field).

    `insecure=True` => the local Firestore emulator — dial http:// over a plain
    KernelTcpConnector, NO peer verification. `insecure=False` (the default) =>
    the production cloud path — https:// over a public-CA TLS connector."""

    var host: String
    var port: UInt16
    var insecure: Bool

    def __init__(out self, var host: String, port: UInt16, insecure: Bool):
        self.host = host^
        self.port = port
        self.insecure = insecure

    @staticmethod
    def prod() -> FirestoreEndpoint:
        """The production endpoint: https TLS to firestore.googleapis.com:443 —
        the env-unset default."""
        return FirestoreEndpoint(String(FIRESTORE_HOST), FIRESTORE_PORT, False)

    @always_inline
    def is_https(self) -> Bool:
        """True on the cloud path (https:// TLS); False on the plaintext
        emulator path (http://)."""
        return not self.insecure

    @always_inline
    def scheme(self) -> String:
        """The URL scheme this endpoint dials: `http` (insecure emulator) or
        `https` (cloud)."""
        return String("http") if self.insecure else String("https")


def _fs_parse_port_bytes(
    b: Span[UInt8, _], start: Int, end: Int, fallback: UInt16
) -> UInt16:
    """Parse a decimal port from `b[start:end]`; `fallback` on empty /
    non-numeric / overflow. Byte-based (no String slicing) — robust on this Mojo
    pin, and non-raising so the resolver stays thin-fn-ptr-compatible."""
    if start >= end:
        return fallback
    var v: Int = 0
    for i in range(start, end):
        var c = Int(b[i])
        if c < ord("0") or c > ord("9"):
            return fallback
        v = v * 10 + (c - ord("0"))
        if v > 65535:
            return fallback
    return UInt16(v)


def parse_firestore_endpoint(
    endpoint: String, insecure: Bool
) -> FirestoreEndpoint:
    """PURE: resolve a `host[:port]` override string + an insecure flag into a
    `FirestoreEndpoint`.

    Empty `endpoint` => the prod host (firestore.googleapis.com) with the
    fallback port (443 cloud / 8080 emulator), honoring the `insecure` flag. A
    `host:port` with insecure set is the emulator shape (plaintext http://).

    Parsing operates on the raw bytes (no String slicing). Split on the LAST ':'
    so an IPv6-literal host's inner colons aren't mangled (emulator usage is the
    simple `firestore-emulator:8080`). A missing / empty / non-numeric port falls
    back to 443 (TLS) or 8080 (emulator). NON-RAISING — the resolver feeds a
    `thin` connector factory."""
    var fallback_port: UInt16 = (
        FIRESTORE_EMULATOR_DEFAULT_PORT if insecure else FIRESTORE_PORT
    )
    var b = endpoint.as_bytes()
    var n = len(b)
    if n == 0:
        return FirestoreEndpoint(String(FIRESTORE_HOST), fallback_port, insecure)
    var colon = -1
    for i in range(n):
        if Int(b[i]) == ord(":"):
            colon = i
    var host_bytes = List[UInt8]()
    var port: UInt16
    if colon < 0:
        for i in range(n):
            host_bytes.append(b[i])
        port = fallback_port
    else:
        for i in range(colon):
            host_bytes.append(b[i])
        port = _fs_parse_port_bytes(b, colon + 1, n, fallback_port)
    return FirestoreEndpoint(
        String(unsafe_from_utf8=Span(host_bytes)), port, insecure
    )


def build_firestore_tls_connector(
    host: String = String(FIRESTORE_HOST), insecure: Bool = False
) raises -> TlsConnector[KernelTcpConnector]:
    """Build a TLS connector for the Firestore REST endpoint — the faithful
    mirror of `build_gcs_tls_connector` (the GCS storage-emulator seam).

    DEFAULT (production): `build_public_ca_tls_connector(host)` — system CA trust, SNI = host, ALPN
    `http/1.1` (Firestore REST is HTTP/1.1, NOT h2 — the ONE difference from
    build_gcs_tls_connector's `alpn_h2=True`). NO hand-rolled TLS.

    insecure=True => peer X.509 verification DISABLED (`disable_verify()` +
    verify_mode=VERIFY_SKIP), for a local self-signed TLS terminator fronting the
    emulator. NEVER use against a real Firestore endpoint.

    NOTE — the standard Firestore emulator speaks PLAINTEXT http://, not TLS: a
    client of it takes a plain `KernelTcpConnector` (and a plaintext
    `FirestoreEndpoint`), not this factory. This verify-disabled TLS variant is
    only for a TLS-terminator-fronted endpoint. The connector TYPE is ALWAYS
    `TlsConnector[KernelTcpConnector]` (only the TlsConfig varies) — no second
    transport monomorphization is introduced downstream."""
    if not insecure:
        # Production / verify-on path: public-CA TLS, ALPN http/1.1.
        return build_public_ca_tls_connector(host)

    # INSECURE path (local TLS terminator in front of the emulator): mirror
    # build_public_ca_tls_connector's config (TLS 1.3 ciphers + ALPN http/1.1)
    # but DISABLE peer verification and build verify_mode=VERIFY_SKIP. The
    # connector TYPE is unchanged — only the TlsConfig differs.
    var config = TlsConfig()
    config.set_cipher_preferences(String("default_tls13"))
    var alpn = List[String]()
    alpn.append(String("http/1.1"))
    config.set_alpn_protocols(alpn)
    config.disable_verify()

    var connector = TlsConnector[KernelTcpConnector](
        config^, KernelTcpConnector.new(), VERIFY_SKIP,
    )
    connector.set_server_name_for_next_connect(host)
    return connector^
