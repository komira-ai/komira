# =============================================================================
# komira_crypto/rs256_jwks.mojo — verify a THIRD-PARTY RS256 JWS against a
#   fetched RFC 7517 JWK Set. The platform-attestation verifier.
# =============================================================================
#
# ★★ WHY THIS IS A SEPARATE VERIFIER AND NOT A WIDENING OF AN EXISTING ONE.
#
# A service that authenticates workloads can verify a PLATFORM ATTESTATION —
# e.g. a Google metadata-server ID token, which is RS256 by RFC 7518 §3.3 — and
# exchange it for a token of its own. The first half needs RS256 verification;
# RSA-**PSS** (used for X.509 chains) is a different scheme.
#
# The obvious-looking shortcut — add `RS256` to the `alg` allowlist of the
# service's OWN token verifier — is the one thing that must NEVER be done, and
# this file exists so that nobody has to. That allowlist is a SECURITY CONTROL:
# it says *the service's own identity tokens are ES256, full stop*, and it
# rejects `RS256` BY NAME before any crypto runs. Widening it would mean a token
# signed by GOOGLE, presented where a token signed by the SERVICE is required,
# reaches a verifier that is willing to accept it — and Google will sign an ID
# token for anyone with a Google account. Two credentials, two issuers, two
# trust anchors, two questions:
#
#   the service's own verifier  ES256  minted by the service  "who is this caller"
#   THIS FILE                   RS256  minted by GOOGLE       "is this really that VM/SA"
#
# They share a primitive layer (`komira_crypto`) and share NOTHING above it. The
# key set here comes from the ISSUER's own JWKS endpoint, never from the
# service's keyring; the verifier here must never be reachable from the
# service's own identity path.
#
# ⛔ WHAT THIS FILE DELIBERATELY DOES NOT DO: validate claims. It returns the
# AUTHENTIC payload and stops. `iss`, `aud`, `exp`, `iat`, and — for a GCE
# instance token — `google.compute_engine.*` are the CALLER's checks, and they
# are checks about POLICY, not about cryptography. Fusing them in here would
# make one function that can be "passed" for the wrong reason. A signature check
# that returns a payload is not an authorization decision, and the type says so:
# the caller gets a String, not a `VerifiedX`.
#
# ENCAPSULATION: `String` / `Span[UInt8, _]` / `List` in and out. NO
# UnsafePointer crosses any boundary, no wildcard origin. All key material here
# is PUBLIC — nothing needs zeroizing.
# =============================================================================

from komira_crypto.base64 import base64_url_decode
from komira_crypto.rsa import rsa_pkcs1_sha256_verify


# -----------------------------------------------------------------------------
# §0 — the floors. Each is a REFUSAL, not a preference.
# -----------------------------------------------------------------------------

# The ONE `alg` this verifier accepts. It is a GATE, never a dispatch key: the
# code below compares against this constant and then unconditionally runs
# RS256 — it never looks up a verification routine by the header's own claim,
# which is the shape of every algorithm-confusion break there has ever been.
comptime RS256_ALG: String = "RS256"

# `typ` is optional in a JWS (RFC 7515 A.2's own vector omits it) but when
# present it must be this. Google stamps it.
comptime RS256_TYP: String = "JWT"

# Only `kty:"RSA"` JWKs enter the trusted set. This is the control that stops an
# EC key in a mixed JWKS from ever being handed to an RSA verifier: an EC JWK is
# never PARSED into a key here, so a token naming its kid finds no key and is
# refused — the failure happens at selection, before any crypto.
comptime RS256_KTY: String = "RSA"

# 2048-bit floor / 4096-bit ceiling on the modulus, in bytes. The floor is a
# real control (a 1024-bit RSA modulus is within reach of a well-funded
# attacker, and there is no reason for an issuer to publish one); the ceiling
# bounds the work an unauthenticated document can make us do.
comptime RS256_MIN_MODULUS_BYTES: Int = 256
comptime RS256_MAX_MODULUS_BYTES: Int = 512

# The public exponent must be odd and >= 3. e = 1 is the degenerate "signature
# is the message" key; an even e is not a valid RSA exponent at all. In practice
# every issuer publishes 65537.
comptime RS256_MIN_EXPONENT: UInt64 = 3

# A JWKS is fetched over the network from an issuer we do not control, so the
# document itself is untrusted input. These bound the parse.
comptime RS256_MAX_JWKS_BYTES: Int = 262144
comptime RS256_MAX_JWKS_KEYS: Int = 64


# -----------------------------------------------------------------------------
# §1 — the parsed key.
# -----------------------------------------------------------------------------


struct RsaJwk(Copyable, Movable, Deinitable):
    """One RSA verification key lifted out of a JWK Set: its `kid`, its modulus
    as big-endian bytes, and its public exponent.

    Every instance has already passed the §0 floors — a value of this type
    cannot hold a 512-bit modulus or an even exponent, because `parse_rsa_jwks`
    is the only thing that builds one and it drops anything that fails. The type
    makes no security decision itself; it records that the decisions were made.
    """

    var kid: String
    var n_be: List[UInt8]
    var e: UInt64

    def __init__(out self, kid: String, n_be: List[UInt8], e: UInt64):
        self.kid = kid.copy()
        self.n_be = n_be.copy()
        self.e = e


# -----------------------------------------------------------------------------
# §2 — a small, strict JSON reader.
#
# WHY HAND-ROLLED. `komira_crypto` is the foundational LEAF for crypto and
# depends on no other package; taking a JSON library would invert that. The
# reader below is deliberately narrow: it reads ONE flat object's string members
# and refuses everything it does not fully understand, rather than guessing.
#
# ⚠ IT IS OBJECT-SCOPED, AND THAT IS THE POINT. A POSITIONAL JWKS reader —
# one that finds a `"kid"` and then takes "the FOLLOWING `x`" — is safe only
# for a document rendered in a fixed member order by the reader's own side.
# It is not safe for a document a third party renders: Google's JWK Set at
# `https://www.googleapis.com/oauth2/v3/certs` has been observed to emit its
# members in a DIFFERENT ORDER IN EVERY ENTRY —
#   {"kid",  "use", "kty", "n", "e", "alg"}
#   {"e", "kid", "n", "use", "kty", "alg"}
#   {"e", "alg", "n", "kty", "use", "kid"}
# — so a positional reader would pair a kid with the NEXT object's modulus.
# `test_rs256_jwks_verify.mojo` pins exactly this against the real document.
# -----------------------------------------------------------------------------


def _is_ws(c: UInt8) -> Bool:
    return (
        c == UInt8(0x20)
        or c == UInt8(0x09)
        or c == UInt8(0x0A)
        or c == UInt8(0x0D)
    )


def _skip_ws(b: Span[UInt8, _], start: Int) -> Int:
    var i = start
    while i < len(b) and _is_ws(b[i]):
        i += 1
    return i


def _read_json_string(b: Span[UInt8, _], start: Int) -> Tuple[Int, String]:
    """Read a JSON string starting AT its opening quote.

    Returns `(next_index, value)`, or `(-1, "")` on anything this reader does
    not fully understand — including ANY backslash escape. Refusing escapes is
    not laziness: a JWKS member is `kid` (an issuer-chosen id, hex in practice)
    or base64url, and neither can contain one. A half-implemented unescaper is a
    parser differential, which is precisely how one reader is made to see a
    different `kid` than another.
    """
    if start >= len(b) or b[start] != UInt8(ord('"')):
        return (-1, String(""))
    var out = String("")
    var i = start + 1
    while i < len(b):
        var c = b[i]
        if c == UInt8(ord('"')):
            return (i + 1, out^)
        if c == UInt8(0x5C):  # backslash
            return (-1, String(""))
        if c < UInt8(0x20):  # a raw control character is invalid JSON
            return (-1, String(""))
        out += chr(Int(c))
        i += 1
    return (-1, String(""))


def _skip_json_value(b: Span[UInt8, _], start: Int) -> Int:
    """Skip one JSON value (any type). Returns the index after it, or -1."""
    var i = _skip_ws(b, start)
    if i >= len(b):
        return -1
    var c = b[i]
    if c == UInt8(ord('"')):
        var r = _read_json_string(b, i)
        return r[0]
    if c == UInt8(ord("{")) or c == UInt8(ord("[")):
        # Balanced skip, string-aware so a brace inside a string cannot fool it.
        var depth = 0
        var in_str = False
        while i < len(b):
            var ch = b[i]
            if in_str:
                if ch == UInt8(0x5C):
                    i += 2
                    continue
                if ch == UInt8(ord('"')):
                    in_str = False
            else:
                if ch == UInt8(ord('"')):
                    in_str = True
                elif ch == UInt8(ord("{")) or ch == UInt8(ord("[")):
                    depth += 1
                elif ch == UInt8(ord("}")) or ch == UInt8(ord("]")):
                    depth -= 1
                    if depth == 0:
                        return i + 1
            i += 1
        return -1
    # A literal (number / true / false / null): run to the next , } ] or ws.
    var j = i
    while j < len(b):
        var ch = b[j]
        if (
            ch == UInt8(ord(","))
            or ch == UInt8(ord("}"))
            or ch == UInt8(ord("]"))
            or _is_ws(ch)
        ):
            break
        j += 1
    if j == i:
        return -1
    return j


def _object_string_members(
    b: Span[UInt8, _], start: Int
) -> Tuple[Int, List[Tuple[String, String]]]:
    """Read the STRING-valued members of the JSON object beginning at `start`
    (which must be its `{`), in document order. Non-string values are skipped
    over, not recorded.

    Returns `(index_after_the_object, members)`, or `(-1, [])` on malformed
    input.

    ⚠ A DUPLICATE MEMBER NAME IS RECORDED TWICE AND THE CALLER REFUSES THE
    OBJECT. `{"kid":"a","kid":"b"}` is legal JSON with no defined winner, and
    two readers that pick differently are an authentication bypass waiting for a
    proxy to sit in front of us. There is no correct answer, so there is no
    answer.
    """
    var out = List[Tuple[String, String]]()
    var i = _skip_ws(b, start)
    if i >= len(b) or b[i] != UInt8(ord("{")):
        return (-1, out^)
    i += 1
    i = _skip_ws(b, i)
    if i < len(b) and b[i] == UInt8(ord("}")):
        return (i + 1, out^)
    while i < len(b):
        i = _skip_ws(b, i)
        var kr = _read_json_string(b, i)
        if kr[0] < 0:
            return (-1, List[Tuple[String, String]]())
        var key = kr[1]
        i = _skip_ws(b, kr[0])
        if i >= len(b) or b[i] != UInt8(ord(":")):
            return (-1, List[Tuple[String, String]]())
        i = _skip_ws(b, i + 1)
        if i >= len(b):
            return (-1, List[Tuple[String, String]]())
        if b[i] == UInt8(ord('"')):
            var vr = _read_json_string(b, i)
            if vr[0] < 0:
                return (-1, List[Tuple[String, String]]())
            out.append((key^, vr[1]))
            i = vr[0]
        else:
            var nxt = _skip_json_value(b, i)
            if nxt < 0:
                return (-1, List[Tuple[String, String]]())
            i = nxt
        i = _skip_ws(b, i)
        if i >= len(b):
            return (-1, List[Tuple[String, String]]())
        if b[i] == UInt8(ord(",")):
            i += 1
            continue
        if b[i] == UInt8(ord("}")):
            return (i + 1, out^)
        return (-1, List[Tuple[String, String]]())
    return (-1, List[Tuple[String, String]]())


def _member(
    members: List[Tuple[String, String]], name: String
) -> Optional[String]:
    """The one member named `name`, or None if it is absent OR DUPLICATED."""
    var found = Optional[String]()
    for i in range(len(members)):
        if members[i][0] == name:
            if found:
                return Optional[String]()  # duplicate -> refuse
            found = Optional[String](members[i][1].copy())
    return found^


def _object_has_member(b: Span[UInt8, _], start: Int, name: String) -> Bool:
    """Is `name` a member of the JSON object at `start`, WHATEVER its value
    type?

    ⚠ THIS EXISTS BECAUSE `_object_string_members` CANNOT ANSWER IT, AND THE
    DIFFERENCE IS A SECURITY CONTROL. That reader records only STRING-valued
    members — a non-string value is skipped and its NAME is never recorded. So
    asking it about `crit` answers "is there a crit whose value is a string",
    and RFC 7515 §4.1.11 says `crit` is an **array of strings**. The RFC-shaped
    header `{"alg":"RS256","crit":["b64"],"kid":"…"}` leaves no trace in that
    reader's member list at all, so a `crit` refusal built on it — the headline
    reason this verifier will not silently ignore an extension the signer marked
    essential — would pass it through and refuse only the malformed
    string-valued spelling.

    Returns True on a MALFORMED object too. A `crit` we cannot rule out is a
    `crit` we must assume is there; the caller's answer to True is a refusal, so
    erring toward True cannot admit anything.
    """
    var i = _skip_ws(b, start)
    if i >= len(b) or b[i] != UInt8(ord("{")):
        return True
    i += 1
    i = _skip_ws(b, i)
    if i < len(b) and b[i] == UInt8(ord("}")):
        return False
    while i < len(b):
        i = _skip_ws(b, i)
        var kr = _read_json_string(b, i)
        if kr[0] < 0:
            return True
        if kr[1] == name:
            return True
        i = _skip_ws(b, kr[0])
        if i >= len(b) or b[i] != UInt8(ord(":")):
            return True
        var nxt = _skip_json_value(b, i + 1)
        if nxt < 0:
            return True
        i = _skip_ws(b, nxt)
        if i >= len(b):
            return True
        if b[i] == UInt8(ord(",")):
            i += 1
            continue
        if b[i] == UInt8(ord("}")):
            return False
        return True
    return True


# -----------------------------------------------------------------------------
# §3 — parse a JWK Set into the RSA keys it publishes.
# -----------------------------------------------------------------------------


def _be_bytes_to_u64(raw: List[UInt8]) -> Optional[UInt64]:
    """A JWK exponent: unsigned big-endian, minimal (no leading zero byte),
    at most 8 bytes. None if it does not fit that shape."""
    if len(raw) == 0 or len(raw) > 8:
        return Optional[UInt64]()
    if raw[0] == UInt8(0):
        # RFC 7518 §6.3.1.2: the octet sequence is the minimal representation.
        # A leading zero is a second spelling of the same number, and two
        # spellings of one key are two kids for one key.
        return Optional[UInt64]()
    var v = UInt64(0)
    for i in range(len(raw)):
        v = (v << UInt64(8)) | UInt64(Int(raw[i]))
    return Optional[UInt64](v)


def parse_rsa_jwks(doc: String) -> List[RsaJwk]:
    """Parse an RFC 7517 JWK Set and return the RSA-SHA-256 verification keys it
    publishes, in document order.

    Does NOT raise. A JWK that is not usable for this purpose is SKIPPED, never
    fatal — a real issuer's document legitimately mixes key types and rotations,
    and one unreadable entry must not blind us to the other three. What "usable"
    means is fixed by §0 and is deliberately narrow:

      * `kty` == "RSA"                (an EC key never becomes an RSA key here)
      * `alg`, IF present, == "RS256"  (an issuer that labels a key must be obeyed)
      * `use`, IF present, == "sig"    (an encryption key must not verify)
      * `kid` present and non-empty    (selection must be explicit — see below)
      * `n` decodes to 256..512 bytes with no leading zero
      * `e` decodes to an odd value >= 3
      * no member name appears twice

    A document larger than `RS256_MAX_JWKS_BYTES`, or holding more than
    `RS256_MAX_JWKS_KEYS` entries, is truncated at the limit rather than parsed
    — it is unauthenticated input fetched over the network.
    """
    var out = List[RsaJwk]()
    if doc.byte_length() == 0 or doc.byte_length() > RS256_MAX_JWKS_BYTES:
        return out^
    var b = doc.as_bytes()

    # Locate the `keys` array. Read the top-level object's members by walking
    # it, so a `"keys"` appearing inside some other member's string value cannot
    # be mistaken for the array.
    var i = _skip_ws(b, 0)
    if i >= len(b) or b[i] != UInt8(ord("{")):
        return out^
    i += 1
    var keys_at = -1
    while i < len(b):
        i = _skip_ws(b, i)
        if i < len(b) and b[i] == UInt8(ord("}")):
            break
        var kr = _read_json_string(b, i)
        if kr[0] < 0:
            return out^
        var key = kr[1]
        i = _skip_ws(b, kr[0])
        if i >= len(b) or b[i] != UInt8(ord(":")):
            return out^
        i = _skip_ws(b, i + 1)
        if key == String("keys") and i < len(b) and b[i] == UInt8(ord("[")):
            keys_at = i
            break
        var nxt = _skip_json_value(b, i)
        if nxt < 0:
            return out^
        i = _skip_ws(b, nxt)
        if i < len(b) and b[i] == UInt8(ord(",")):
            i += 1
            continue
        if i < len(b) and b[i] == UInt8(ord("}")):
            break
        return out^
    if keys_at < 0:
        return out^

    # Walk the array's objects.
    var j = _skip_ws(b, keys_at + 1)
    while j < len(b) and b[j] != UInt8(ord("]")):
        if len(out) >= RS256_MAX_JWKS_KEYS:
            break
        if b[j] != UInt8(ord("{")):
            return out^
        var om = _object_string_members(b, j)
        if om[0] < 0:
            return out^
        var jwk = _parse_one_rsa_jwk(om[1])
        if jwk:
            out.append(jwk.value().copy())
        j = _skip_ws(b, om[0])
        if j < len(b) and b[j] == UInt8(ord(",")):
            j = _skip_ws(b, j + 1)
            continue
        break
    return out^


def _parse_one_rsa_jwk(
    members: List[Tuple[String, String]]
) -> Optional[RsaJwk]:
    """Apply the §0 floors to one JWK object's string members."""
    var kty = _member(members, String("kty"))
    if not kty or kty.value() != RS256_KTY:
        return Optional[RsaJwk]()
    var alg = _member(members, String("alg"))
    if alg and alg.value() != RS256_ALG:
        return Optional[RsaJwk]()
    var use = _member(members, String("use"))
    if use and use.value() != String("sig"):
        return Optional[RsaJwk]()
    var kid = _member(members, String("kid"))
    if not kid or kid.value().byte_length() == 0:
        return Optional[RsaJwk]()
    var n_b64 = _member(members, String("n"))
    if not n_b64:
        return Optional[RsaJwk]()
    var e_b64 = _member(members, String("e"))
    if not e_b64:
        return Optional[RsaJwk]()

    var n_raw: List[UInt8]
    var e_raw: List[UInt8]
    try:
        n_raw = base64_url_decode(n_b64.value())
        e_raw = base64_url_decode(e_b64.value())
    except:
        return Optional[RsaJwk]()
    if (
        len(n_raw) < RS256_MIN_MODULUS_BYTES
        or len(n_raw) > RS256_MAX_MODULUS_BYTES
    ):
        return Optional[RsaJwk]()
    if n_raw[0] == UInt8(0):
        # Minimal big-endian per RFC 7518 §6.3.1.1 — same reasoning as `e`.
        return Optional[RsaJwk]()
    var e_o = _be_bytes_to_u64(e_raw)
    if not e_o:
        return Optional[RsaJwk]()
    var e_v = e_o.value()
    if e_v < RS256_MIN_EXPONENT or (e_v & UInt64(1)) == UInt64(0):
        return Optional[RsaJwk]()
    return Optional[RsaJwk](RsaJwk(kid.value(), n_raw^, e_v))


# -----------------------------------------------------------------------------
# §4 — verify a compact RS256 JWS against a parsed key set.
# -----------------------------------------------------------------------------


def verify_rs256_jws(token: String, keys: List[RsaJwk]) -> Optional[String]:
    """Verify a compact RS256 JWS and return its AUTHENTIC payload as a String,
    or None if it does not verify for ANY reason.

    ⛔ THE RETURN VALUE IS A PAYLOAD, NOT A DECISION. See this file's header:
    `iss` / `aud` / `exp` are the caller's checks and are deliberately absent
    here. A caller that skips them has authenticated the SIGNER and nothing
    else — for a Google ID token that means "some Google principal", which is
    everybody.

    The order of the steps is load-bearing and mirrors an ES256 identity-token
    verifier on purpose:

      1. Exactly three segments. A fourth `.` means this is not a compact JWS
         (it could be a JWE) and is refused rather than reinterpreted.
      2. HEADER + `alg` ALLOWLIST, **before any signature work**. `none`,
         `HS256`, `ES256`, `PS256`, a missing `alg` — all rejected here. This
         is a GATE, not a lookup: step 5 runs RS256 unconditionally and never
         consults the header again.
      3. `kid` selection against the key set. Required, and required to match.
      4. The signature length must equal the modulus length.
      5. RS256 over the signing input, taken from the ORIGINAL token bytes.
      6. Only now is the payload decoded — no attacker-controlled bytes are
         parsed into a claim before the signature has been checked.

    ★ WHY `kid` IS REQUIRED even though RFC 7515 permits its absence. Without
    it the only way to verify is to try every key, which turns one verification
    into an oracle over the whole set and makes a key rotation silently
    ambiguous. Every issuer this is built for (Google) stamps `kid`. The
    published RFC 7515 A.2 vector omits it and is therefore exercised against
    the PRIMITIVE, `rsa_pkcs1_sha256_verify`, which is where a signature KAT
    belongs.
    """
    # 1 — exactly three segments.
    var d1 = token.find(String("."))
    if d1 <= 0:
        return Optional[String]()
    var d2 = token.find(String("."), d1 + 1)
    if d2 <= d1 + 1:
        return Optional[String]()
    if token.find(String("."), d2 + 1) >= 0:
        return Optional[String]()
    # BYTE positions: a compact JWS is ASCII base64url by construction and the
    # `.` offsets above are byte offsets, so a codepoint basis would disagree
    # with them the moment a token carried a multi-byte sequence — a case that,
    # for attacker-controlled input, must cut cleanly rather than shift.
    var seg_header = String(token[byte=0:d1])
    var seg_payload = String(token[byte = d1 + 1 : d2])
    var seg_sig = String(token[byte = d2 + 1 : token.byte_length()])
    if seg_sig.byte_length() == 0:
        return Optional[String]()

    # 2 — header + alg allowlist, BEFORE any signature work.
    var hdr_raw: List[UInt8]
    try:
        hdr_raw = base64_url_decode(seg_header)
    except:
        return Optional[String]()
    var hm = _object_string_members(Span[UInt8, origin_of(hdr_raw)](hdr_raw), 0)
    if hm[0] < 0:
        return Optional[String]()
    var hdr = hm[1].copy()
    var alg = _member(hdr, String("alg"))
    if not alg or alg.value() != RS256_ALG:
        return Optional[String]()
    var typ = _member(hdr, String("typ"))
    if typ and typ.value() != RS256_TYP:
        return Optional[String]()
    # RFC 7515 §4.1.11: a `crit` header names extensions the verifier MUST
    # understand. We understand none, so its presence is a refusal — the
    # alternative is silently ignoring an extension the signer said was
    # essential.
    #
    # ⚠ ASKED OF THE RAW BYTES, NOT OF `hdr`. `crit` is an ARRAY, and `hdr`
    # holds only string-valued members — see `_object_has_member`.
    if _object_has_member(
        Span[UInt8, origin_of(hdr_raw)](hdr_raw), 0, String("crit")
    ):
        return Optional[String]()
    var kid_o = _member(hdr, String("kid"))
    if not kid_o or kid_o.value().byte_length() == 0:
        return Optional[String]()
    var kid = kid_o.value()

    # 3 — key selection by kid. A kid naming no key is refused; it is never a
    # licence to try the others.
    var chosen = -1
    for i in range(len(keys)):
        if keys[i].kid == kid:
            if chosen >= 0:
                # Two keys under one kid: the set is ambiguous, so there is no
                # single answer to "which key signed this". Refuse.
                return Optional[String]()
            chosen = i
    if chosen < 0:
        return Optional[String]()

    # 4 — signature length must equal modulus length (RFC 8017 §8.2.2 step 1).
    var sig_bytes: List[UInt8]
    try:
        sig_bytes = base64_url_decode(seg_sig)
    except:
        return Optional[String]()
    if len(sig_bytes) != len(keys[chosen].n_be):
        return Optional[String]()

    # 5 — RS256 over the signing input, cut from the ORIGINAL token bytes (never
    #     re-encoded from the parsed header, which would verify a document we
    #     invented rather than the one we were given).
    var signing_input = seg_header + String(".") + seg_payload
    var n_be = keys[chosen].n_be.copy()
    if not rsa_pkcs1_sha256_verify(
        Span[UInt8, origin_of(n_be)](n_be),
        keys[chosen].e,
        signing_input.as_bytes(),
        Span[UInt8, origin_of(sig_bytes)](sig_bytes),
    ):
        return Optional[String]()

    # 6 — the payload, now AUTHENTIC.
    var payload_raw: List[UInt8]
    try:
        payload_raw = base64_url_decode(seg_payload)
    except:
        return Optional[String]()
    var payload_json = String("")
    for i in range(len(payload_raw)):
        payload_json += chr(Int(payload_raw[i]))
    return Optional[String](payload_json^)


def verify_rs256_jws_against_jwks(
    token: String, jwks_doc: String
) -> Optional[String]:
    """`parse_rsa_jwks` + `verify_rs256_jws` in one call — the shape a caller
    holding a freshly-fetched JWKS document wants.

    An empty key set is a REFUSAL, not a pass: a document that parsed to zero
    usable keys and a document that verified the token must never take the same
    branch.
    """
    var keys = parse_rsa_jwks(jwks_doc)
    if len(keys) == 0:
        return Optional[String]()
    return verify_rs256_jws(token, keys)
