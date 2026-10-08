# =============================================================================
# komira_http_auth/token.mojo: the compact JWS shape and the JOSE header gate.
# =============================================================================
#
# Everything here runs BEFORE any key is looked up or fetched and before any
# signature work, on bytes the caller controls. The gate is stricter than
# komira_crypto's RS256 verifier (which still runs afterwards and repeats its
# own `alg` / `typ` / `crit` / `kid` checks over its own reader):
#
#   * three non-empty segments of the base64url alphabet, no padding
#     (RFC 7515 section 2), the header at most 2 KiB of text;
#   * the header is one JSON object with no repeated key (dup_keys.mojo);
#   * `alg` is a string equal to the anchor's one alg. `none`, HS*, ES*, PS*
#     and a missing `alg` are all refused here, by comparison with the
#     anchor, never by a list of bad values;
#   * `jwk`, `jku`, `x5u`, `x5c` are refused. Each names a key or a place to
#     get one; keys come only from the anchor's JWKS URL, so a token that
#     offers its own is refused rather than ignored;
#   * `crit` is refused whatever it holds: this verifier understands no JOSE
#     extension (RFC 7515 section 4.1.11);
#   * `typ` must be present and equal to the anchor's typ (exact match);
#   * `kid` must be a non-empty string of printable ASCII (it selects the
#     key; see komira_crypto's rs256_jwks.mojo for why it is required).
#     ASCII because komira_crypto reads a JWK's kid one byte per character,
#     so a non-ASCII kid could never match a published key: it is refused
#     here as a bad kid, before it can cost a JWKS refetch. The JWKS side
#     refuses a non-ASCII kid too (jwks_cache.mojo). Real issuers' kids are
#     hex.
#
# Results are reason codes (reasons.mojo); nothing here echoes the token.
# =============================================================================

from komira_encoding import base64_url_decode_nopad
from komira_json import JsonValue, parse_json_bytes

from komira_http_auth.config import TrustAnchor
from komira_http_auth.dup_keys import refuse_duplicate_keys
from komira_http_auth.reasons import (
    REASON_ALG,
    REASON_CRIT,
    REASON_DUPLICATE_KEY,
    REASON_HEADER_JSON,
    REASON_KEY_IN_HEADER,
    REASON_KID,
    REASON_MALFORMED_TOKEN,
    REASON_OK,
    REASON_TYP,
)


# The longest token accepted, and the longest header segment.
comptime MAX_TOKEN_BYTES: Int = 8192
comptime MAX_HEADER_SEGMENT_BYTES: Int = 2048
# JOSE headers are flat; a deeper one is refused as malformed.
comptime HEADER_MAX_DEPTH: Int = 4


@fieldwise_init
struct CompactJws(Copyable, Movable, Deinitable):
    """The three segments of a compact JWS, still base64url text."""

    var header_seg: String
    var payload_seg: String
    var signature_seg: String


def _is_b64url_byte(c: UInt8) -> Bool:
    return (
        (c >= UInt8(ord("A")) and c <= UInt8(ord("Z")))
        or (c >= UInt8(ord("a")) and c <= UInt8(ord("z")))
        or (c >= UInt8(ord("0")) and c <= UInt8(ord("9")))
        or c == UInt8(ord("-"))
        or c == UInt8(ord("_"))
    )


def split_compact_jws(token: String) -> Optional[CompactJws]:
    """The three segments of `token`, or None unless it is exactly three
    non-empty runs of the unpadded base64url alphabet joined by two dots."""
    var b = token.as_bytes()
    if len(b) == 0 or len(b) > MAX_TOKEN_BYTES:
        return Optional[CompactJws]()
    var d1 = -1
    var d2 = -1
    for i in range(len(b)):
        var c = b[i]
        if c == UInt8(ord(".")):
            if d1 < 0:
                d1 = i
            elif d2 < 0:
                d2 = i
            else:
                return Optional[CompactJws]()
        elif not _is_b64url_byte(c):
            return Optional[CompactJws]()
    if d1 <= 0 or d2 <= d1 + 1 or d2 >= len(b) - 1:
        return Optional[CompactJws]()
    return Optional[CompactJws](
        CompactJws(
            header_seg=String(token[byte=0:d1]),
            payload_seg=String(token[byte = d1 + 1 : d2]),
            signature_seg=String(token[byte = d2 + 1 : len(b)]),
        )
    )


def is_printable_ascii(s: String) -> Bool:
    """True when `s` is non-empty and every byte is in 0x20..0x7E."""
    var b = s.as_bytes()
    if len(b) == 0:
        return False
    for i in range(len(b)):
        if b[i] < UInt8(0x20) or b[i] > UInt8(0x7E):
            return False
    return True


def string_member(v: JsonValue, name: String) -> Optional[String]:
    """The value of member `name` when it is present and a string."""
    if not v.has(name):
        return Optional[String]()
    try:
        var m = v.get(name)
        if not m.is_string():
            return Optional[String]()
        return Optional[String](m.as_string())
    except:
        return Optional[String]()


@fieldwise_init
struct HeaderVerdict(Copyable, Movable, Deinitable):
    """`reason` is REASON_OK when the header passed, and then `kid` is set."""

    var reason: String
    var kid: String


def _refuse(reason: String) -> HeaderVerdict:
    return HeaderVerdict(reason=reason, kid=String(""))


def check_jose_header(header_seg: String, anchor: TrustAnchor) -> HeaderVerdict:
    """Apply the header gate (module header) for `anchor`."""
    if header_seg.byte_length() > MAX_HEADER_SEGMENT_BYTES:
        return _refuse(REASON_MALFORMED_TOKEN)
    var raw: List[UInt8]
    try:
        raw = base64_url_decode_nopad(header_seg)
    except:
        return _refuse(REASON_MALFORMED_TOKEN)
    var h: JsonValue
    try:
        h = parse_json_bytes(raw, HEADER_MAX_DEPTH)
    except:
        return _refuse(REASON_HEADER_JSON)
    if not h.is_object():
        return _refuse(REASON_HEADER_JSON)
    try:
        refuse_duplicate_keys(h)
    except:
        return _refuse(REASON_DUPLICATE_KEY)

    # alg: the anchor's one value, compared; never looked up.
    var alg = string_member(h, String("alg"))
    if not alg or alg.value() != anchor.alg:
        return _refuse(REASON_ALG)

    # A key, or a place to fetch one, offered by the token itself.
    if (
        h.has(String("jwk"))
        or h.has(String("jku"))
        or h.has(String("x5u"))
        or h.has(String("x5c"))
    ):
        return _refuse(REASON_KEY_IN_HEADER)

    # No JOSE extension is understood, so any crit is unknown.
    if h.has(String("crit")):
        return _refuse(REASON_CRIT)

    var typ = string_member(h, String("typ"))
    if not typ or typ.value() != anchor.typ:
        return _refuse(REASON_TYP)

    var kid = string_member(h, String("kid"))
    if not kid or not is_printable_ascii(kid.value()):
        return _refuse(REASON_KID)
    return HeaderVerdict(reason=REASON_OK, kid=kid.value())
