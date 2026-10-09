# =============================================================================
# komira_http_auth/flags.mojo: the command-line flags that configure the
#   bearer-JWT middleware.
# =============================================================================
#
# One spelling: `--name=value`. A bare word, a `--name` without `=`, an empty
# value, an unknown name, and a single-valued flag given twice are refused.
# Configuration comes from flags only; nothing here reads the environment.
#
#   --issuer=URL          the exact `iss` accepted
#   --audience=STRING     our audience: `aud` must be it or contain it
#   --jwks-url=URL        the issuer's JWK Set (https only)
#   --jwks-alg=RS256      the one `alg` accepted (RS256 only; required)
#   --accept-typ=JWT      the one header `typ` accepted (JWT only; required)
#   --max-ttl=SECONDS     the longest `exp - iat` accepted (required)
#   --copy-claim=NAME     a payload claim copied into the principal (repeated)
#   --trust-anchor='name=N,issuer=I,audience=A,jwks_url=U,alg=RS256,typ=JWT,max_ttl=S'
#   --leeway-s=SECONDS    clock skew forgiven on exp/iat/nbf, 0..60 (default 30)
#   --jwks-max-stale=DURATION
#                         how long past its freshness the last good key set
#                         stays in use while every refresh fails: digits and
#                         one unit, `s`, `m` or `h` (`90s`, `30m`, `1h`);
#                         0s..24h (default 1h). Past it, every token is
#                         refused with 503 until a refresh succeeds.
#
# The single flags (--issuer, --audience, --jwks-url, --jwks-alg,
# --accept-typ, --max-ttl) are shorthand for one trust anchor named
# "default". Every one of them is required, as is every member of a
# `--trust-anchor` value: an anchor has no defaults, because a later release
# that brought in different ones (another `alg`, `typ` or lifetime) would
# silently change what a running deployment accepts. `TrustAnchor.rs256` is
# the code-level shorthand and keeps its values. `--trust-anchor` is the general form and cannot be mixed with
# them. In this release exactly one anchor is accepted: a second
# `--trust-anchor` is refused. Choosing an anchor per token (by its `iss`)
# needs one key cache per anchor and a dispatch step, which is a later change;
# until then one process verifies one issuer. When that change lands, parsing
# returns several anchors: `BearerJwtConfig`'s single `anchor` field becomes a
# list, which is a public API change. Dispatch by `iss` also requires the
# anchors to have distinct issuers, so a repeated issuer will be refused at
# startup. `--copy-claim`, `--leeway-s` and `--jwks-max-stale` go with
# either form.
#
# The other JWKS settings (refetch window, default max-age, fetch timeout)
# have no flags; an embedder sets them with `BearerJwtConfig`'s `with_*`
# setters.
#
# A `--trust-anchor` value is comma-separated `key=value` pairs; a value is
# everything after the first `=`, so it cannot hold a comma. An unknown key, a
# repeated key, an empty value or a missing key (all seven are required) is
# refused.
#
# Two spellings of a time exist, each on purpose: `--leeway-s` and
# `--max-ttl` take bare seconds (the unit is in the name or the meaning),
# while `--jwks-max-stale` takes digits and a unit (`90s`, `30m`, `1h`). A new
# flag picks one of these two forms deliberately; it never invents a third.
#
# The embedding binary splits its own argv: `bearer_jwt_flag_names()` lists
# the names this file owns, and `parse_bearer_jwt_flags` takes only those.
# =============================================================================

from komira_http_auth.config import BearerJwtConfig, TrustAnchor


comptime FLAG_ISSUER: String = "--issuer"
comptime FLAG_AUDIENCE: String = "--audience"
comptime FLAG_JWKS_URL: String = "--jwks-url"
comptime FLAG_JWKS_ALG: String = "--jwks-alg"
comptime FLAG_ACCEPT_TYP: String = "--accept-typ"
comptime FLAG_MAX_TTL: String = "--max-ttl"
comptime FLAG_COPY_CLAIM: String = "--copy-claim"
comptime FLAG_TRUST_ANCHOR: String = "--trust-anchor"
comptime FLAG_LEEWAY_S: String = "--leeway-s"
comptime FLAG_JWKS_MAX_STALE: String = "--jwks-max-stale"


def bearer_jwt_flag_names() -> List[String]:
    """Every flag name `parse_bearer_jwt_flags` accepts."""
    var out = List[String]()
    out.append(FLAG_ISSUER)
    out.append(FLAG_AUDIENCE)
    out.append(FLAG_JWKS_URL)
    out.append(FLAG_JWKS_ALG)
    out.append(FLAG_ACCEPT_TYP)
    out.append(FLAG_MAX_TTL)
    out.append(FLAG_COPY_CLAIM)
    out.append(FLAG_TRUST_ANCHOR)
    out.append(FLAG_LEEWAY_S)
    out.append(FLAG_JWKS_MAX_STALE)
    return out^


struct _Flags(Movable):
    var names: List[String]
    var values: List[String]

    def __init__(out self):
        self.names = List[String]()
        self.values = List[String]()

    def count(self, name: String) -> Int:
        var n = 0
        for i in range(len(self.names)):
            if self.names[i] == name:
                n += 1
        return n

    def single(self, name: String) raises -> Optional[String]:
        if self.count(name) > 1:
            raise Error(
                String("komira_http_auth: ") + name + String(" is given more than once")
            )
        for i in range(len(self.names)):
            if self.names[i] == name:
                return Optional[String](self.values[i])
        return Optional[String]()

    def all(self, name: String) -> List[String]:
        var out = List[String]()
        for i in range(len(self.names)):
            if self.names[i] == name:
                out.append(self.values[i])
        return out^


def _scan(args: List[String]) raises -> _Flags:
    var known = bearer_jwt_flag_names()
    var out = _Flags()
    for i in range(len(args)):
        ref a = args[i]
        if not a.startswith(String("--")):
            raise Error(
                String("komira_http_auth: unexpected argument '")
                + a
                + String("' (flags are --name=value)")
            )
        var eq = a.find(String("="))
        if eq < 0:
            raise Error(
                String("komira_http_auth: flag ")
                + a
                + String(" has no value (write ")
                + a
                + String("=VALUE)")
            )
        var name = String(a[byte=0:eq])
        var value = String(a[byte = eq + 1 : a.byte_length()])
        var is_known = False
        for k in range(len(known)):
            if known[k] == name:
                is_known = True
                break
        if not is_known:
            raise Error(String("komira_http_auth: unknown flag ") + name)
        if value.byte_length() == 0:
            raise Error(String("komira_http_auth: flag ") + name + String(" is empty"))
        out.names.append(name^)
        out.values.append(value^)
    return out^


def _parse_seconds(what: String, text: String) raises -> Int64:
    """A positive decimal integer of at most 9 digits."""
    var b = text.as_bytes()
    if len(b) == 0 or len(b) > 9:
        raise Error(
            String("komira_http_auth: ") + what + String(" is not a positive integer")
        )
    var n = Int64(0)
    for i in range(len(b)):
        var c = Int(b[i])
        if c < 0x30 or c > 0x39:
            raise Error(
                String("komira_http_auth: ")
                + what
                + String(" is not a positive integer")
            )
        n = n * Int64(10) + Int64(c - 0x30)
    if n <= Int64(0):
        raise Error(String("komira_http_auth: ") + what + String(" must be at least 1"))
    return n


def _parse_count(what: String, text: String) raises -> Int64:
    """A non-negative decimal integer of 1..9 digits."""
    var b = text.as_bytes()
    if len(b) == 0 or len(b) > 9:
        raise Error(
            String("komira_http_auth: ")
            + what
            + String(" is not a non-negative integer")
        )
    var n = Int64(0)
    for i in range(len(b)):
        var c = Int(b[i])
        if c < 0x30 or c > 0x39:
            raise Error(
                String("komira_http_auth: ")
                + what
                + String(" is not a non-negative integer")
            )
        n = n * Int64(10) + Int64(c - 0x30)
    return n


def _parse_duration_s(what: String, text: String) raises -> Int64:
    """`<digits><unit>`, the unit one of `s`, `m`, `h`, in seconds. The range
    is `BearerJwtConfig.validate`'s."""
    var b = text.as_bytes()
    var bad = (
        String("komira_http_auth: ")
        + what
        + String(" is not a duration (digits and one unit: s, m or h; 90s, 30m, 1h)")
    )
    if len(b) < 2:
        raise Error(bad)
    var unit = b[len(b) - 1]
    var scale = Int64(0)
    if unit == UInt8(ord("s")):
        scale = Int64(1)
    elif unit == UInt8(ord("m")):
        scale = Int64(60)
    elif unit == UInt8(ord("h")):
        scale = Int64(3600)
    else:
        raise Error(bad)
    if len(b) - 1 > 9:
        raise Error(bad)
    for i in range(len(b) - 1):
        if b[i] < UInt8(0x30) or b[i] > UInt8(0x39):
            raise Error(bad)
    return _parse_count(what, String(text[byte=0 : len(b) - 1])) * scale


def parse_trust_anchor(spec: String) raises -> TrustAnchor:
    """Parse one `--trust-anchor` value (see the module header). The result is
    not yet validated; `BearerJwtConfig.validate` does that."""
    var name = Optional[String]()
    var issuer = Optional[String]()
    var audience = Optional[String]()
    var jwks_url = Optional[String]()
    var alg = Optional[String]()
    var typ = Optional[String]()
    var max_ttl = Optional[String]()
    var parts = spec.split(",")
    for i in range(len(parts)):
        var part = String(parts[i])
        var eq = part.find(String("="))
        if eq <= 0:
            raise Error(
                String("komira_http_auth: --trust-anchor part '")
                + part
                + String("' is not key=value")
            )
        var key = String(part[byte=0:eq])
        var value = String(part[byte = eq + 1 : part.byte_length()])
        if value.byte_length() == 0:
            raise Error(
                String("komira_http_auth: --trust-anchor key ")
                + key
                + String(" has an empty value")
            )
        var dup = False
        if key == String("name"):
            dup = Bool(name)
            name = Optional[String](value)
        elif key == String("issuer"):
            dup = Bool(issuer)
            issuer = Optional[String](value)
        elif key == String("audience"):
            dup = Bool(audience)
            audience = Optional[String](value)
        elif key == String("jwks_url"):
            dup = Bool(jwks_url)
            jwks_url = Optional[String](value)
        elif key == String("alg"):
            dup = Bool(alg)
            alg = Optional[String](value)
        elif key == String("typ"):
            dup = Bool(typ)
            typ = Optional[String](value)
        elif key == String("max_ttl"):
            dup = Bool(max_ttl)
            max_ttl = Optional[String](value)
        else:
            raise Error(
                String("komira_http_auth: --trust-anchor has an unknown key ")
                + key
                + String(
                    " (keys: name, issuer, audience, jwks_url, alg, typ,"
                    " max_ttl)"
                )
            )
        if dup:
            raise Error(
                String("komira_http_auth: --trust-anchor key ")
                + key
                + String(" is given more than once")
            )
    if not name:
        raise Error(String("komira_http_auth: --trust-anchor needs name="))
    if not issuer:
        raise Error(String("komira_http_auth: --trust-anchor needs issuer="))
    if not audience:
        raise Error(String("komira_http_auth: --trust-anchor needs audience="))
    if not jwks_url:
        raise Error(String("komira_http_auth: --trust-anchor needs jwks_url="))
    if not alg:
        raise Error(String("komira_http_auth: --trust-anchor needs alg="))
    if not typ:
        raise Error(String("komira_http_auth: --trust-anchor needs typ="))
    if not max_ttl:
        raise Error(String("komira_http_auth: --trust-anchor needs max_ttl="))
    return TrustAnchor(
        name=name.value(),
        issuer=issuer.value(),
        audience=audience.value(),
        jwks_url=jwks_url.value(),
        alg=alg.value(),
        typ=typ.value(),
        max_ttl_s=_parse_seconds(
            String("--trust-anchor max_ttl"), max_ttl.value()
        ),
    )


def parse_bearer_jwt_flags(args: List[String]) raises -> BearerJwtConfig:
    """Build and validate a `BearerJwtConfig` from `args`, every one of which
    must be one of `bearer_jwt_flag_names()` in `--name=value` form. Raises
    with a message naming the flag at fault."""
    var f = _scan(args)
    var anchors = f.all(FLAG_TRUST_ANCHOR)
    var single_names = List[String]()
    single_names.append(FLAG_ISSUER)
    single_names.append(FLAG_AUDIENCE)
    single_names.append(FLAG_JWKS_URL)
    single_names.append(FLAG_JWKS_ALG)
    single_names.append(FLAG_ACCEPT_TYP)
    single_names.append(FLAG_MAX_TTL)

    var anchor: TrustAnchor
    if len(anchors) > 0:
        for i in range(len(single_names)):
            if f.count(single_names[i]) > 0:
                raise Error(
                    String("komira_http_auth: ")
                    + single_names[i]
                    + String(
                        " cannot be combined with --trust-anchor (put it in"
                        " the anchor instead)"
                    )
                )
        if len(anchors) > 1:
            raise Error(
                String(
                    "komira_http_auth: more than one --trust-anchor is given;"
                    " this release verifies one issuer per process (choosing an"
                    " anchor per token by its iss comes in a later release)"
                )
            )
        anchor = parse_trust_anchor(anchors[0])
    else:
        var issuer = f.single(FLAG_ISSUER)
        var audience = f.single(FLAG_AUDIENCE)
        var jwks_url = f.single(FLAG_JWKS_URL)
        var alg = f.single(FLAG_JWKS_ALG)
        var typ = f.single(FLAG_ACCEPT_TYP)
        var ttl = f.single(FLAG_MAX_TTL)
        if not issuer:
            raise Error(String("komira_http_auth: missing required flag --issuer="))
        if not audience:
            raise Error(
                String("komira_http_auth: missing required flag --audience=")
            )
        if not jwks_url:
            raise Error(
                String("komira_http_auth: missing required flag --jwks-url=")
            )
        if not alg:
            raise Error(
                String("komira_http_auth: missing required flag --jwks-alg=")
            )
        if not typ:
            raise Error(
                String("komira_http_auth: missing required flag --accept-typ=")
            )
        if not ttl:
            raise Error(
                String("komira_http_auth: missing required flag --max-ttl=")
            )
        anchor = TrustAnchor(
            name=String("default"),
            issuer=issuer.value(),
            audience=audience.value(),
            jwks_url=jwks_url.value(),
            alg=alg.value(),
            typ=typ.value(),
            max_ttl_s=_parse_seconds(FLAG_MAX_TTL, ttl.value()),
        )

    var cfg = BearerJwtConfig(anchor^)
    var claims = f.all(FLAG_COPY_CLAIM)
    for i in range(len(claims)):
        cfg.copy_claims.append(claims[i])
    var leeway = f.single(FLAG_LEEWAY_S)
    if leeway:
        cfg.leeway_s = _parse_count(FLAG_LEEWAY_S, leeway.value())
    var max_stale = f.single(FLAG_JWKS_MAX_STALE)
    if max_stale:
        cfg.jwks_max_stale_s = _parse_duration_s(
            FLAG_JWKS_MAX_STALE, max_stale.value()
        )
    cfg.validate()
    return cfg^
