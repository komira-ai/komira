# =============================================================================
# komira_service_registry/identity.mojo — the PLATFORM IDENTITY and the
#   fingerprint that is its object key.
# =============================================================================
#
# A platform identity is the thing a cloud hands a running workload and that a
# peer can CHECK: a GCP service-account email, an AWS role ARN, a Kubernetes
# service-account subject. The registry's second job is `identity -> service`:
# given a caller that has proven WHICH platform principal it is, say WHICH
# logical service that is.
#
# # ⛔ THE PLATFORM IS A FREE-FORM TOKEN, NOT AN ENUM. THIS IS DELIBERATE.
#
# The obvious move is to reuse `komira_svcref`'s
# `CLOUD_GCP/AWS/AZURE/KUBERNETES/LOCAL` ordinals — which are themselves a
# comptime MIRROR of a deploy-configuration enum. Rejected on two grounds:
#
#   1. NO PRODUCT CONCEPTS. A closed set of clouds mirrored out of a deploy
#      configuration is a product concept, and taking it would give this
#      package a reason to know what a deploy configuration is.
#   2. IT WOULD BE ONE MORE MIRROR. Every copy of those integers is a copy
#      that can come to disagree with the others.
#
# So `platform` is a lowercase `[a-z0-9-]+` token supplied by the caller
# (`gcp`, `aws`, `azure`, `kubernetes`, `local`, and whatever comes next). A new
# platform needs NO edit here. What is enforced is only what the KEY needs:
# non-empty, and no `.` — because `.` is the separator between the platform and
# the escaped principal in the fingerprint.
#
# ⚠ WHAT IS LOST BY NOT USING THE ENUM: nothing catches `gpc` as a typo for
# `gcp`. That is the correct trade here — a mistyped platform yields a
# fingerprint that resolves to nothing, i.e. a failed lookup at the call site,
# not a silent mis-binding. The enum's value is in NAME composition
# (a regional name such as `scheduler-gcp-us-central1` must round-trip through
# whatever parses it); an identity fingerprint is in a different namespace and
# round-trips through nothing but this file.
#
# # THE FINGERPRINT IS AN ESCAPE, NOT A HASH.
#
#   fingerprint = "<platform>" "." <escape(principal)>
#   escape:  bytes in [A-Za-z0-9.-] pass through; every other byte, `_`
#            INCLUDED, becomes `_` + two UPPERCASE hex digits.
#
# Three properties, each of which a hash would cost:
#   * INJECTIVE — `escape` is prefix-free per byte and `_` is itself escaped, so
#     distinct principals give distinct fingerprints. Two services cannot end up
#     at one key by accident, and one identity cannot land at two.
#   * REVERSIBLE — `identity_from_fingerprint` recovers the principal VERBATIM,
#     so `list_identities` (and therefore the reap tooling) can report an orphan
#     by the string an operator typed, rather than by a digest nobody can map
#     back. The key IS the identity; there is no second copy of it in the value
#     to drift.
#   * NO CRYPTO DEP — this package's whole dep closure is `komira_objectstore`.
#     A sha256 would pull `komira_crypto` into it for the sake of a key.
#
# ⚠ CASE IS PRESERVED, NOT FOLDED. AWS role ARNs are case-sensitive in the role
# name, so folding would merge two distinct principals onto one key — the exact
# collision the enrollment refusal exists to make impossible.
#
# ⚠ `/` CAN NEVER SURVIVE THE ESCAPE, and that is load-bearing rather than
# cosmetic: an unescaped `/` in an ARN would split the object key into a second
# path segment, so `identity/<fp>` would silently become a two-level prefix and
# `list_identities`' delimiter listing would stop seeing it.
# =============================================================================


@fieldwise_init
struct PlatformIdentity(Copyable, Movable, Deinitable):
    """One checkable platform principal: the platform token it belongs to, and
    the principal string that platform issues.

    Flat `String`s only — ZERO UnsafePointer, ZERO wildcard origins, and a
    plain `List` element rather than a byte-slab (no pointer field, so no
    stale-pointer hazard across destroy and recreate).
    """

    var platform: String
    """The lowercase platform token — `gcp` / `aws` / `azure` / … . Free-form
    by design (see the module header); validated for KEY-SAFETY only."""

    var principal: String
    """The platform's own principal string, VERBATIM — e.g.
    `jm@proj.iam.gserviceaccount.com`, `arn:aws:iam::123:role/scheduler`."""


# -----------------------------------------------------------------------------
# Escape / unescape — the injective, reversible byte encoding.
# -----------------------------------------------------------------------------


comptime _ESCAPE: UInt8 = 95  # '_'


def _is_literal(b: UInt8) -> Bool:
    """True iff byte `b` passes through the escape unchanged: `[A-Za-z0-9.-]`.

    `_` is NOT in this set even though it is otherwise key-safe — it is the
    escape marker, and letting it through unescaped would destroy injectivity
    (`a_41` from a literal `_` would be indistinguishable from an escaped `A`).
    """
    if b >= UInt8(65) and b <= UInt8(90):  # A-Z
        return True
    if b >= UInt8(97) and b <= UInt8(122):  # a-z
        return True
    if b >= UInt8(48) and b <= UInt8(57):  # 0-9
        return True
    if b == UInt8(46) or b == UInt8(45):  # '.' '-'
        return True
    return False


def _hex_nibble(v: Int) -> String:
    """One UPPERCASE hex digit for `v` in [0, 16)."""
    if v < 10:
        return String(chr(48 + v))
    return String(chr(65 + (v - 10)))


def _nibble_value(b: UInt8) raises -> Int:
    """The value of one hex digit byte, accepting either case. Raises on a
    non-hex byte — a malformed fingerprint is a corrupt key, not a miss."""
    if b >= UInt8(48) and b <= UInt8(57):
        return Int(b) - 48
    if b >= UInt8(65) and b <= UInt8(70):
        return Int(b) - 55
    if b >= UInt8(97) and b <= UInt8(102):
        return Int(b) - 87
    raise Error(
        String(
            "service registry: malformed identity fingerprint — '_' must be"
            " followed by two hex digits, got byte "
        )
        + String(Int(b))
    )


def escape_principal(s: String) -> String:
    """The key-safe, injective encoding of a principal string."""
    var bs = s.as_bytes()
    var out = String("")
    for i in range(len(bs)):
        var b = bs[i]
        if _is_literal(b):
            out += chr(Int(b))
        else:
            out += "_"
            out += _hex_nibble(Int(b) // 16)
            out += _hex_nibble(Int(b) % 16)
    return out^


def unescape_principal(s: String) raises -> String:
    """The inverse of `escape_principal`. Raises on a truncated or non-hex
    escape sequence."""
    var bs = s.as_bytes()
    var out = String("")
    var i = 0
    while i < len(bs):
        if bs[i] != _ESCAPE:
            out += chr(Int(bs[i]))
            i += 1
            continue
        if i + 2 >= len(bs):
            raise Error(
                String(
                    "service registry: malformed identity fingerprint —"
                    " truncated escape at the end of '"
                )
                + s
                + String("'")
            )
        var hi = _nibble_value(bs[i + 1])
        var lo = _nibble_value(bs[i + 2])
        out += chr(hi * 16 + lo)
        i += 3
    return out^


# -----------------------------------------------------------------------------
# The fingerprint — `<platform>.<escaped principal>`.
# -----------------------------------------------------------------------------


def validate_platform(platform: String) raises:
    """REFUSE a platform token that cannot be half of a fingerprint.

    Non-empty and `[a-z0-9-]` only. The `.` exclusion is what makes
    `identity_from_fingerprint`'s split at the FIRST `.` unambiguous, and the
    lowercase restriction keeps `GCP` and `gcp` from being two platforms.

    Raising rather than normalising is deliberate: silently lowercasing a token
    would mean the string a caller passes and the string that keys its object
    are different, and the first person to debug a missing binding would be
    comparing two things that were never meant to be equal."""
    var bs = platform.as_bytes()
    if len(bs) == 0:
        raise Error(
            "service registry: an identity needs a PLATFORM token (e.g. 'gcp',"
            " 'aws'); the caller supplied an empty one, which is a caller that"
            " has not resolved its environment binding"
        )
    for i in range(len(bs)):
        var b = bs[i]
        var ok = (
            (b >= UInt8(97) and b <= UInt8(122))
            or (b >= UInt8(48) and b <= UInt8(57))
            or b == UInt8(45)
        )
        if not ok:
            raise Error(
                String(
                    "service registry: REJECTED platform token '"
                    + platform
                    + "' — a platform token is lowercase [a-z0-9-] only. In"
                    " particular it may not contain '.', which separates the"
                    " platform from the principal in an identity fingerprint."
                )
            )


def identity_fingerprint(identity: PlatformIdentity) raises -> String:
    """The object-key segment for `identity`: `<platform>.<escaped principal>`.

    THIS IS THE UNIQUENESS MECHANISM. The enrollment object is keyed by this
    value, so two services claiming ONE identity address ONE object and the
    store's create-if-absent precondition refuses the second — structurally,
    with no scan and therefore no race. Keying by the SERVICE instead would put
    the two claims at two keys where nothing collides."""
    validate_platform(identity.platform)
    if identity.principal.byte_length() == 0:
        raise Error(
            String(
                "service registry: an identity needs a PRINCIPAL; platform '"
            )
            + identity.platform
            + String(
                "' was given an empty one. An empty principal is not an"
                " identity — it is a caller that has not read its platform"
                " credential — and keying it would let the FIRST such caller"
                " enroll a binding every later one then collides with."
            )
        )
    return identity.platform + String(".") + escape_principal(
        identity.principal
    )


def identity_from_fingerprint(fingerprint: String) raises -> PlatformIdentity:
    """Recover the identity a fingerprint encodes — the inverse of
    `identity_fingerprint`.

    Splits at the FIRST `.`, which is unambiguous because `validate_platform`
    forbids `.` in a platform token. This is what lets `list_identities` report
    a binding by the principal an operator typed."""
    var bs = fingerprint.as_bytes()
    var dot = -1
    for i in range(len(bs)):
        if bs[i] == UInt8(46):
            dot = i
            break
    if dot <= 0:
        raise Error(
            String(
                "service registry: malformed identity fingerprint '"
                + fingerprint
                + "' — expected '<platform>.<escaped principal>'"
            )
        )
    var platform = String("")
    for i in range(dot):
        platform += chr(Int(bs[i]))
    var escaped = String("")
    for i in range(dot + 1, len(bs)):
        escaped += chr(Int(bs[i]))
    validate_platform(platform)
    return PlatformIdentity(platform^, unescape_principal(escaped))
