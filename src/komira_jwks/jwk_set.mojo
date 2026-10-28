# =============================================================================
# komira_jwks/jwk_set.mojo: the strict parser for one JWK and for a JWK Set
#   (RFC 7517), on `komira_json`.
# =============================================================================
#
# A JWK Set is fetched from another party, so it is untrusted input. What the
# parser does with it falls in three classes.
#
# REFUSED: the whole document raises `JwksError: ...`, and no key is returned.
#   * larger than `JWKS_MAX_DOCUMENT_BYTES`, or not JSON (`komira_json` with a
#     nesting limit of 16);
#   * any object, at any depth, naming a member twice (RFC 7517 section 4
#     lets a parser reject them; two readers that keep different duplicates
#     would read different keys);
#   * not an object; no `keys` member, or one that is not an array; more than
#     `JWKS_MAX_KEYS` elements; an element that is not an object;
#   * a key carrying a private member (`d`, `p`, `q`, `dp`, `dq`, `qi`,
#     `oth`, or the symmetric `k`): a published set holds public keys only,
#     and a document that leaks one is not used, nor any key beside it;
#   * two accepted keys with the same `kid` (a verifier selects by `kid`).
#
# SKIPPED: the key is left out and `JwkSet.skipped` records why, as
#   `key <index>: <reason>`. This is RFC 7517 section 5: a set may hold keys
#   a reader does not understand, and they must not hide the others.
#   * `kty` other than OKP, EC or RSA; an OKP curve other than Ed25519; an EC
#     curve other than P-256 (so a P-384 key never enters a P-256 set);
#   * a missing or non-string required member (`kty`, `crv`, `x`, `y`, `n`,
#     `e`), or a non-string `kid`, `alg` or `use`;
#   * a `key_ops` that is not an array of strings, or names one value twice
#     (RFC 7517 section 4.3);
#   * a key member that is not base64url without padding, or of the wrong
#     length, or outside the supported RSA range (see jwk.mojo);
#   * an empty `kid`.
#
# IGNORED: members this package does not read (`x5c`, `x5t`, and any
#   other), per RFC 7517 section 4; they are still checked for duplicates.
#
# A single JWK (`parse_jwk`) has no set to skip from: every problem raises.
# =============================================================================

from komira_encoding import base64_url_decode_nopad
from komira_json import (
    JSON_ARRAY,
    JSON_OBJECT,
    JSON_STRING,
    JsonValue,
    parse_json_value,
    refuse_duplicate_keys,
)

from komira_jwks.jwk import (
    JWK_KTY_EC,
    JWK_KTY_OKP,
    JWK_KTY_RSA,
    Jwk,
    _JwkParts,
    _check_ec,
    _check_ec_crv,
    _check_key_ops,
    _check_kid,
    _check_okp,
    _check_okp_crv,
    _check_rsa,
    _q,
    render_jwk_set,
)


# The largest document the parser reads, in bytes.
comptime JWKS_MAX_DOCUMENT_BYTES: Int = 262144
# The most elements a `keys` array may hold.
comptime JWKS_MAX_KEYS: Int = 64
# The nesting limit handed to the JSON parser (a JWK Set nests three deep,
# four with an `x5c` array).
comptime _JWKS_MAX_DEPTH: Int = 16


struct JwkSet(Copyable, Movable):
    """The keys a JWK Set document holds that this package supports, in
    document order, and one reason per key it skipped."""

    var keys: List[Jwk]
    var skipped: List[String]

    def __init__(out self, var keys: List[Jwk], var skipped: List[String]):
        self.keys = keys^
        self.skipped = skipped^

    def index_of_kid(self, kid: String) -> Optional[Int]:
        """The index in `keys` of the key whose `kid` is `kid`, if any (kids
        are unique within a parsed set)."""
        for i in range(len(self.keys)):
            var k = self.keys[i].kid()
            if k and k.value() == kid:
                return Optional[Int](i)
        return Optional[Int]()

    def render(self) -> String:
        """The set's keys as a JWK Set document (`render_jwk_set`). Skipped
        keys are not rendered."""
        return render_jwk_set(self.keys)


def _private_names() -> List[String]:
    var out = List[String]()
    out.append(String("d"))
    out.append(String("p"))
    out.append(String("q"))
    out.append(String("dp"))
    out.append(String("dq"))
    out.append(String("qi"))
    out.append(String("oth"))
    out.append(String("k"))
    return out^


def _private_member(obj: JsonValue) -> Optional[String]:
    var names = _private_names()
    for i in range(len(obj.obj_keys)):
        for j in range(len(names)):
            if obj.obj_keys[i] == names[j]:
                return Optional[String](names[j].copy())
    return Optional[String]()


def _optional_string(obj: JsonValue, name: String) raises -> Optional[String]:
    for i in range(len(obj.obj_keys)):
        if obj.obj_keys[i] == name:
            if obj.children[i].kind != JSON_STRING:
                raise Error(String("member ") + _q(name) + " is not a string")
            return Optional[String](obj.children[i].text.copy())
    return Optional[String]()


def _optional_string_list(
    obj: JsonValue, name: String
) raises -> Optional[List[String]]:
    for i in range(len(obj.obj_keys)):
        if obj.obj_keys[i] == name:
            ref arr = obj.children[i]
            if arr.kind != JSON_ARRAY:
                raise Error(String("member ") + _q(name) + " is not an array")
            var out = List[String]()
            for j in range(len(arr.children)):
                if arr.children[j].kind != JSON_STRING:
                    raise Error(
                        String("member ") + _q(name) + " holds a non-string"
                    )
                out.append(arr.children[j].text.copy())
            return Optional[List[String]](out^)
    return Optional[List[String]]()


def _required_string(obj: JsonValue, name: String) raises -> String:
    var v = _optional_string(obj, name)
    if not v:
        raise Error(String("member ") + _q(name) + " is missing")
    return v.value().copy()


def _key_bytes(obj: JsonValue, name: String) raises -> List[UInt8]:
    var text = _required_string(obj, name)
    try:
        return base64_url_decode_nopad(text)
    except:
        raise Error(
            String("member ") + _q(name) + " is not base64url without padding"
        )


def _jwk_from_object(obj: JsonValue) raises -> Jwk:
    """One key from a parsed JWK object with no duplicate and no private
    member. Raises the bare reason (no prefix) for anything the file header
    lists under SKIPPED."""
    var kty = _required_string(obj, "kty")
    var kid = _optional_string(obj, "kid")
    var alg = _optional_string(obj, "alg")
    var key_use = _optional_string(obj, "use")
    var key_ops = _optional_string_list(obj, "key_ops")
    _check_kid(kid)
    _check_key_ops(key_ops)
    if kty == JWK_KTY_OKP:
        var crv = _required_string(obj, "crv")
        _check_okp_crv(crv)
        var x = _key_bytes(obj, "x")
        _check_okp(crv, x)
        return Jwk(
            _parts=_JwkParts(
                kty=kty.copy(),
                crv=crv.copy(),
                x=x^,
                y=List[UInt8](),
                n=List[UInt8](),
                e=List[UInt8](),
                kid=kid^,
                alg=alg^,
                key_use=key_use^,
                key_ops=key_ops^,
            )
        )
    if kty == JWK_KTY_EC:
        var crv = _required_string(obj, "crv")
        _check_ec_crv(crv)
        var x = _key_bytes(obj, "x")
        var y = _key_bytes(obj, "y")
        _check_ec(crv, x, y)
        return Jwk(
            _parts=_JwkParts(
                kty=kty.copy(),
                crv=crv.copy(),
                x=x^,
                y=y^,
                n=List[UInt8](),
                e=List[UInt8](),
                kid=kid^,
                alg=alg^,
                key_use=key_use^,
                key_ops=key_ops^,
            )
        )
    if kty == JWK_KTY_RSA:
        var n = _key_bytes(obj, "n")
        var e = _key_bytes(obj, "e")
        _check_rsa(n, e)
        return Jwk(
            _parts=_JwkParts(
                kty=kty.copy(),
                crv=String(""),
                x=List[UInt8](),
                y=List[UInt8](),
                n=n^,
                e=e^,
                kid=kid^,
                alg=alg^,
                key_use=key_use^,
                key_ops=key_ops^,
            )
        )
    raise Error(
        String("kty ") + _q(kty) + " is not supported (OKP, EC and RSA are)"
    )


def _parse_document(doc: String) raises -> JsonValue:
    """Size cap, JSON parse and the duplicate check, each raising
    `JwksError: ...`."""
    if doc.byte_length() > JWKS_MAX_DOCUMENT_BYTES:
        raise Error(
            String("JwksError: document is ")
            + String(doc.byte_length())
            + " bytes; the limit is "
            + String(JWKS_MAX_DOCUMENT_BYTES)
        )
    try:
        return _parse_json_strict(doc)
    except e:
        raise Error(String("JwksError: ") + String(e))


def _parse_json_strict(doc: String) raises -> JsonValue:
    var v = parse_json_value(doc, _JWKS_MAX_DEPTH)
    refuse_duplicate_keys(v)
    return v^


def _refuse_private(obj: JsonValue, what: String) raises:
    var private = _private_member(obj)
    if private:
        raise Error(
            String("JwksError: ")
            + what
            + " carries the private member "
            + _q(private.value())
            + "; a published key holds public members only"
        )


def parse_jwk(doc: String) raises -> Jwk:
    """Parse one JWK (a JSON object, not a set). Raises `JwksError: ...` for
    anything the file header lists under REFUSED or SKIPPED."""
    var v = _parse_document(doc)
    if v.kind != JSON_OBJECT:
        raise Error("JwksError: a JWK is a JSON object")
    _refuse_private(v, "the key")
    try:
        return _jwk_from_object(v)
    except e:
        raise Error(String("JwksError: ") + String(e))


def parse_jwk_set(doc: String) raises -> JwkSet:
    """Parse a JWK Set document. Raises `JwksError: ...` for anything the
    file header lists under REFUSED; returns the supported keys in document
    order, and in `skipped` one `key <index>: <reason>` per key left out."""
    var v = _parse_document(doc)
    if v.kind != JSON_OBJECT:
        raise Error("JwksError: a JWK Set is a JSON object")
    var at = -1
    for i in range(len(v.obj_keys)):
        if v.obj_keys[i] == "keys":
            at = i
    if at < 0:
        raise Error("JwksError: member \"keys\" is missing")
    ref arr = v.children[at]
    if arr.kind != JSON_ARRAY:
        raise Error("JwksError: member \"keys\" is not an array")
    if len(arr.children) > JWKS_MAX_KEYS:
        raise Error(
            String("JwksError: the set holds ")
            + String(len(arr.children))
            + " keys; the limit is "
            + String(JWKS_MAX_KEYS)
        )
    var keys = List[Jwk]()
    var skipped = List[String]()
    for i in range(len(arr.children)):
        ref obj = arr.children[i]
        var what = String("key ") + String(i)
        if obj.kind != JSON_OBJECT:
            raise Error(String("JwksError: ") + what + " is not a JSON object")
        _refuse_private(obj, what)
        try:
            keys.append(_jwk_from_object(obj))
        except e:
            skipped.append(what + ": " + String(e))
    for i in range(len(keys)):
        var a = keys[i].kid()
        if not a:
            continue
        for j in range(i + 1, len(keys)):
            var b = keys[j].kid()
            if b and b.value() == a.value():
                raise Error(
                    String("JwksError: kid ")
                    + _q(a.value())
                    + " names two keys"
                )
    return JwkSet(keys^, skipped^)
