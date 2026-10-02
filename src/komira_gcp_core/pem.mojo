# =============================================================================
# komira_gcp_core/pem.mojo -- PEM armor to DER (RFC 7468).
# =============================================================================
#
# A Google service-account key file carries its private key as a PEM
# `-----BEGIN PRIVATE KEY-----` block: an RFC 5208 PKCS#8 PrivateKeyInfo,
# which is what `komira_crypto.rsa_sha256_sign` takes as DER. This module
# strips the armor and base64-decodes the body; it parses nothing inside the
# DER, so the key reaches no parser before the one that must read it.
#
# Strict where it matters, lenient where key files differ:
#   - the BEGIN and END lines must carry the SAME label, and the label must be
#     the one asked for. A PKCS#1 `RSA PRIVATE KEY` or an `ENCRYPTED PRIVATE
#     KEY` is refused by name rather than handed on as the wrong structure;
#   - a body line may end in CR (a CRLF file) and may carry spaces or tabs
#     around it; RFC 7468 section 3 allows both;
#   - text before BEGIN and after END is ignored (RFC 7468 section 2);
#   - the body is strict base64 (komira_encoding), so a header line inside
#     the block (the legacy `Proc-Type:` form) fails to decode.
#
# No error message carries a byte of the key: the decode errors of
# komira_encoding name only a position, and this module adds only the label.
# =============================================================================

from komira_encoding import base64_decode

from komira_gcp_core._text import _from_utf8_bytes


comptime PEM_PKCS8_PRIVATE_KEY_LABEL: StaticString = "PRIVATE KEY"
"""The RFC 7468 section 10 label of an unencrypted PKCS#8 PrivateKeyInfo."""

comptime _PKCS1_RSA_LABEL: StaticString = "RSA PRIVATE KEY"
comptime _ENCRYPTED_PKCS8_LABEL: StaticString = "ENCRYPTED PRIVATE KEY"

comptime _BEGIN: StaticString = "-----BEGIN "
comptime _END: StaticString = "-----END "
comptime _DASHES: StaticString = "-----"


def _trim_line(line: Span[UInt8, _]) -> List[UInt8]:
    """`line` without leading and trailing space, tab and CR."""
    var i = 0
    var j = len(line)
    while i < j and (
        line[i] == UInt8(0x20) or line[i] == UInt8(0x09) or line[i] == UInt8(0x0D)
    ):
        i += 1
    while j > i and (
        line[j - 1] == UInt8(0x20)
        or line[j - 1] == UInt8(0x09)
        or line[j - 1] == UInt8(0x0D)
    ):
        j -= 1
    var out = List[UInt8](capacity=j - i)
    for k in range(i, j):
        out.append(line[k])
    return out^


def _lines(text: String) -> List[List[UInt8]]:
    """The LF-separated lines of `text`, each trimmed."""
    var b = text.as_bytes()
    var out = List[List[UInt8]]()
    var start = 0
    for i in range(len(b) + 1):
        if i == len(b) or b[i] == UInt8(0x0A):
            out.append(_trim_line(b[start:i]))
            start = i + 1
    return out^


def _starts_with(b: List[UInt8], prefix: StaticString) -> Bool:
    var p = prefix.as_bytes()
    if len(b) < len(p):
        return False
    for i in range(len(p)):
        if b[i] != p[i]:
            return False
    return True


def _ends_with(b: List[UInt8], suffix: StaticString) -> Bool:
    var s = suffix.as_bytes()
    if len(b) < len(s):
        return False
    var off = len(b) - len(s)
    for i in range(len(s)):
        if b[off + i] != s[i]:
            return False
    return True


def _label(line: List[UInt8], prefix: StaticString) raises -> String:
    """The label of an encapsulation boundary `<prefix><label>-----`."""
    var p = len(prefix.as_bytes())
    var d = len(_DASHES.as_bytes())
    if len(line) < p + d or not _ends_with(line, _DASHES):
        raise Error("pem: malformed encapsulation boundary")
    var out = List[UInt8](capacity=len(line) - p - d)
    for i in range(p, len(line) - d):
        out.append(line[i])
    return _from_utf8_bytes(out)


def pem_decode(pem: String, label: String) raises -> List[UInt8]:
    """The DER bytes of the first PEM block in `pem`, which must be labelled
    `label`. A block of another label is not skipped: a file whose first
    block is a CERTIFICATE is refused when a PRIVATE KEY is asked for.

    Raises if there is no BEGIN line, if the first BEGIN line carries another
    label, if the block has no END line or the END line's label differs, or if
    the body is empty or not strict base64. No message carries a key byte."""
    var lines = _lines(pem)
    var i = 0
    while i < len(lines) and not _starts_with(lines[i], _BEGIN):
        i += 1
    if i == len(lines):
        raise Error("pem: no '-----BEGIN " + label + "-----' line")
    var found = _label(lines[i], _BEGIN)
    if found != label:
        raise Error(
            "pem: expected a '" + label + "' block, found '" + found + "'"
        )
    var body = List[UInt8]()
    i += 1
    while i < len(lines) and not _starts_with(lines[i], _END):
        if _starts_with(lines[i], _BEGIN):
            raise Error("pem: '" + label + "' block has no END line")
        body.extend(Span(lines[i]))
        i += 1
    if i == len(lines):
        raise Error("pem: '" + label + "' block has no END line")
    var end_label = _label(lines[i], _END)
    if end_label != label:
        raise Error(
            "pem: BEGIN '" + label + "' closed by END '" + end_label + "'"
        )
    if len(body) == 0:
        raise Error("pem: '" + label + "' block has an empty body")
    var der = base64_decode(Span(body))
    if len(der) == 0:
        raise Error("pem: '" + label + "' block decoded to zero bytes")
    return der^


def pkcs8_private_key_der_from_pem(pem: String) raises -> List[UInt8]:
    """The PKCS#8 PrivateKeyInfo DER of a `-----BEGIN PRIVATE KEY-----` PEM,
    the form a Google service-account key file's `private_key` holds.

    A PKCS#1 `RSA PRIVATE KEY` and an `ENCRYPTED PRIVATE KEY` are refused by
    name: each is a different structure from what an RSA signer given PKCS#8
    DER expects. The DER must open with an ASN.1 SEQUENCE (0x30); nothing else
    of it is parsed here."""
    var lines = _lines(pem)
    for i in range(len(lines)):
        if _starts_with(lines[i], _BEGIN):
            var found = _label(lines[i], _BEGIN)
            if found == String(_PKCS1_RSA_LABEL):
                raise Error(
                    "pem: an 'RSA PRIVATE KEY' block is PKCS#1, not PKCS#8;"
                    " convert it to a 'PRIVATE KEY' block"
                )
            if found == String(_ENCRYPTED_PKCS8_LABEL):
                raise Error(
                    "pem: an 'ENCRYPTED PRIVATE KEY' block is refused; this"
                    " decoder takes an unencrypted PKCS#8 key"
                )
            break
    var der = pem_decode(pem, String(PEM_PKCS8_PRIVATE_KEY_LABEL))
    if der[0] != UInt8(0x30):
        raise Error("pem: 'PRIVATE KEY' body is not a DER SEQUENCE")
    return der^
