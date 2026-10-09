# =============================================================================
# komira_http_auth/claims.mojo: the JWT claim checks and the principal they
#   produce.
# =============================================================================
#
# These run only on a payload whose signature has verified. komira_crypto's
# RS256 verifier deliberately checks no claim ("the return value is a payload,
# not a decision"); this file is where the decision is made:
#
#   iss   a string equal to the anchor's issuer, exactly.
#   aud   a string equal to our audience, or a non-empty array of strings
#         that contains it. Any other shape is refused.
#   sub   a non-empty string.
#   exp   required, an integer number of seconds. Refused at or after
#         exp + leeway.
#   iat   required (the lifetime check needs it), an integer, not later than
#         now + leeway.
#   nbf   optional; when present an integer, not later than now + leeway.
#   exp - iat   positive and at most the anchor's max TTL.
#
# Times are integers in 0..253402300799 (the year 9999); a fraction, an
# exponent, a string or a negative value is refused, which also keeps every
# sum and difference below far from overflow.
#
# THE PRINCIPAL. scheme "jwt", subject = sub, claim "iss" = the issuer, claim
# "aud" = OUR audience (the value that matched, even when the token listed
# several), then each --copy-claim present in the payload (never a name in
# config.mojo's RESERVED_CLAIM_NAMES; refused at startup): a string verbatim,
# any other JSON value as its compact JSON text. A copy-claim absent from the
# payload is not set. The token itself rides along as the principal's
# `presented` credential (redacted; never printable).
#
# THE PAYLOAD IS RE-DECODED HERE from its segment, not taken from
# komira_crypto's returned String: that String is built one byte per
# character, which garbles any non-ASCII text (a `name` claim, say). The
# signature covers the segment's bytes, so decoding them again is as
# authentic as the returned copy.
# =============================================================================

from komira_encoding import base64_url_decode_nopad
from komira_json import JSON_NUMBER, JsonValue, parse_json_bytes

from komira_http_server.middleware import (
    PRINCIPAL_SCHEME_JWT,
    PresentedCredential,
    Principal,
)

from komira_http_auth.config import (
    CLAIM_AUD,
    CLAIM_ISS,
    CLAIM_SUB,
    TrustAnchor,
)
from komira_http_auth.dup_keys import refuse_duplicate_keys
from komira_http_auth.reasons import (
    REASON_AUD,
    REASON_DUPLICATE_KEY,
    REASON_EXP,
    REASON_EXPIRED,
    REASON_IAT,
    REASON_ISS,
    REASON_NBF,
    REASON_OK,
    REASON_PAYLOAD_JSON,
    REASON_SUB,
    REASON_TTL,
)
from komira_http_auth.token import string_member


comptime PAYLOAD_MAX_DEPTH: Int = 32
comptime _MAX_TIME_S: Int64 = 253402300799


def decode_payload(payload_seg: String) raises -> JsonValue:
    """The payload segment as a JSON object with no repeated key. Raises with
    the reason code (REASON_PAYLOAD_JSON or REASON_DUPLICATE_KEY) as the
    error text."""
    var raw: List[UInt8]
    try:
        raw = base64_url_decode_nopad(payload_seg)
    except:
        raise Error(REASON_PAYLOAD_JSON)
    var v: JsonValue
    try:
        v = parse_json_bytes(raw, PAYLOAD_MAX_DEPTH)
    except:
        raise Error(REASON_PAYLOAD_JSON)
    if not v.is_object():
        raise Error(REASON_PAYLOAD_JSON)
    try:
        refuse_duplicate_keys(v)
    except:
        raise Error(REASON_DUPLICATE_KEY)
    return v^


def _time_claim(p: JsonValue, name: String) -> Optional[Int64]:
    """Member `name` as whole seconds, or None when absent or not an integer
    number in 0.._MAX_TIME_S."""
    if not p.has(name):
        return Optional[Int64]()
    try:
        var m = p.get(name)
        if m.kind != JSON_NUMBER or not m.is_integral_number():
            return Optional[Int64]()
        var n = m.as_int64()
        if n < Int64(0) or n > _MAX_TIME_S:
            return Optional[Int64]()
        return Optional[Int64](n)
    except:
        return Optional[Int64]()


def _audience_matches(p: JsonValue, audience: String) -> Bool:
    if not p.has(String("aud")):
        return False
    try:
        var a = p.get(String("aud"))
        if a.is_string():
            return a.as_string() == audience
        if not a.is_array() or a.array_len() == 0:
            return False
        var found = False
        for i in range(a.array_len()):
            var e = a.element_at(i)
            if not e.is_string():
                return False
            if e.as_string() == audience:
                found = True
        return found
    except:
        return False


def check_claims(
    p: JsonValue, anchor: TrustAnchor, leeway_s: Int64, now_s: Int64
) -> String:
    """REASON_OK when `p` passes every claim check for `anchor` at `now_s`,
    else the reason code of the first that fails (module header)."""
    var iss = string_member(p, String("iss"))
    if not iss or iss.value() != anchor.issuer:
        return REASON_ISS
    if not _audience_matches(p, anchor.audience):
        return REASON_AUD
    var sub = string_member(p, String("sub"))
    if not sub or sub.value().byte_length() == 0:
        return REASON_SUB
    var exp = _time_claim(p, String("exp"))
    if not exp:
        return REASON_EXP
    var iat = _time_claim(p, String("iat"))
    if not iat:
        return REASON_IAT
    if now_s - leeway_s >= exp.value():
        return REASON_EXPIRED
    if iat.value() > now_s + leeway_s:
        return REASON_IAT
    if p.has(String("nbf")):
        var nbf = _time_claim(p, String("nbf"))
        if not nbf or nbf.value() > now_s + leeway_s:
            return REASON_NBF
    var lifetime = exp.value() - iat.value()
    if lifetime <= Int64(0) or lifetime > anchor.max_ttl_s:
        return REASON_TTL
    return REASON_OK


def principal_from_claims(
    p: JsonValue,
    anchor: TrustAnchor,
    copy_claims: List[String],
    token: String,
) raises -> Principal:
    """The principal for a payload that passed `check_claims` (module
    header)."""
    var sub = string_member(p, String(CLAIM_SUB))
    if not sub:
        raise Error(REASON_SUB)
    var pr = Principal(
        scheme=String(PRINCIPAL_SCHEME_JWT), subject=sub.value()
    )
    # Every claim written here is named by a constant in RESERVED_CLAIM_NAMES
    # (config.mojo), so no --copy-claim can name it.
    pr = pr^.with_claim(String(CLAIM_ISS), anchor.issuer)
    pr = pr^.with_claim(String(CLAIM_AUD), anchor.audience)
    for i in range(len(copy_claims)):
        ref name = copy_claims[i]
        if not p.has(name):
            continue
        var v = p.get(name)
        if v.is_string():
            pr = pr^.with_claim(name, v.as_string())
        else:
            pr = pr^.with_claim(name, v.serialize())
    pr = pr^.with_presented(PresentedCredential(token))
    return pr^
