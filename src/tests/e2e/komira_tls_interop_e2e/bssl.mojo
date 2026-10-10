# =============================================================================
# komira_tls_interop_e2e/bssl.mojo -- what bssl reports about a connection,
# and the names komira and bssl give the same cipher suite
# =============================================================================
#
# `bssl s_client` and `bssl s_server` (aws-lc 1.39.0, tool/transport_common.cc,
# PrintConnectionInfo) print, after a handshake, one indented line per fact:
#
#     Connected.
#       Version: TLSv1.3
#       Resumed session: no
#       Cipher: TLS_AES_128_GCM_SHA256
#       ...
#       ALPN protocol: h2
#
# on stderr, and `s_server -www` sends the same lines to its client, after an
# HTTP/1.0 status line, in answer to a request starting `GET `.
# `parse_report` reads the three facts the tests compare. The ALPN line is
# printed whether or not a protocol was negotiated (`ALPN protocol: ` then
# nothing); `alpn` is then the empty string.
#
# bssl names a cipher suite by its RFC name (SSL_CIPHER_standard_name); s2n,
# under komira's TLS, by the OpenSSL-style name. The TLS 1.3 suites have one
# name; `standard_cipher_name` maps the TLS 1.2 ECDHE suites a default policy
# negotiates, and raises on any other name, so a suite outside the table
# fails a test with both names rather than passing unnoticed.
# =============================================================================


struct BsslReport(Copyable, Movable):
    """The version, cipher suite and ALPN protocol bssl printed."""

    var version: String
    var cipher: String
    var alpn: String

    def __init__(out self, var version: String, var cipher: String, var alpn: String):
        self.version = version^
        self.cipher = cipher^
        self.alpn = alpn^


def _value(text: String, key: String) raises -> String:
    """The rest of the one line of `text` that, without its leading spaces,
    starts with `key`; raises unless exactly one line does."""
    var found = List[String]()
    for raw in text.split("\n"):
        # strip() also takes the "\r" of a CRLF line.
        var line = String(String(raw).strip())
        if line.startswith(key):
            found.append(String(String(line[byte = key.byte_length() :]).strip()))
    if len(found) != 1:
        raise Error(
            "bssl report: expected one '" + key + "' line, found " + String(len(found)) + " in:\n" + text
        )
    return found[0]


def parse_report(text: String) raises -> BsslReport:
    """The `Version:`, `Cipher:` and `ALPN protocol:` values in `text`."""
    return BsslReport(_value(text, "Version:"), _value(text, "Cipher:"), _value(text, "ALPN protocol:"))


def tls_version_name(s2n_version: Int) raises -> String:
    """bssl's name (SSL_get_version) for the version komira's
    `negotiated_tls_version()` reports: 34 is TLS 1.3, 33 is TLS 1.2."""
    if s2n_version == 34:
        return String("TLSv1.3")
    if s2n_version == 33:
        return String("TLSv1.2")
    raise Error("komira negotiated TLS version " + String(s2n_version) + ", neither 1.2 (33) nor 1.3 (34)")


def standard_cipher_name(s2n_name: String) raises -> String:
    """The RFC name bssl prints for the suite s2n calls `s2n_name`."""
    if (
        s2n_name == "TLS_AES_128_GCM_SHA256"
        or s2n_name == "TLS_AES_256_GCM_SHA384"
        or s2n_name == "TLS_CHACHA20_POLY1305_SHA256"
    ):
        return s2n_name.copy()
    if s2n_name == "ECDHE-RSA-AES128-GCM-SHA256":
        return String("TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256")
    if s2n_name == "ECDHE-RSA-AES256-GCM-SHA384":
        return String("TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384")
    if s2n_name == "ECDHE-RSA-CHACHA20-POLY1305":
        return String("TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256")
    if s2n_name == "ECDHE-ECDSA-AES128-GCM-SHA256":
        return String("TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256")
    if s2n_name == "ECDHE-ECDSA-AES256-GCM-SHA384":
        return String("TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384")
    if s2n_name == "ECDHE-ECDSA-CHACHA20-POLY1305":
        return String("TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256")
    raise Error("no RFC name known for the s2n cipher suite '" + s2n_name + "' (bssl.mojo, standard_cipher_name)")


def is_tls13_suite(standard_name: String) -> Bool:
    """Whether `standard_name` is one of the three TLS 1.3 suites (their
    names carry no key exchange)."""
    return standard_name.startswith("TLS_") and "_WITH_" not in standard_name
