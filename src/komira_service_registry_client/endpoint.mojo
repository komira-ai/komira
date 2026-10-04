# =============================================================================
# komira_service_registry_client/endpoint.mojo — ★ THE BOOTSTRAP PROBLEM, AND
#   THE ONLY HONEST ANSWER TO IT.
# =============================================================================
#
# ★★ HOW DOES A SERVICE LEARN THE REGISTRY'S OWN ADDRESS?
#
# It CANNOT be a registry lookup — that is the definition of the bootstrap
# problem, and any design that tries becomes a service that must already know
# the thing it is asking for. Three candidate answers, and only one survives:
#
#  1. ⛔ A NAME CONVENTION (`registry.<something>`). This is DNS wearing a
#     different hat, and it is refused: the boundary is IAM/transport
#     identity, NEVER the network. It is also a SECOND key composition, which
#     can drift from the first with nothing going red.
#  2. ⛔ PLATFORM METADATA (the GCP metadata server, ECS task metadata). It is
#     the most convenient and it is disqualified twice over: it is
#     platform-specific, so an OSS consumer on a fourth platform cannot use this
#     package at all; and it is unavailable in exactly the case the registry
#     exists for — an AWS Lambda that has no GCP anything.
#  3. ★ IT IS SUPPLIED, AND A SERVICE THAT WAS NOT GIVEN ONE REFUSES TO START.
#
# ⇒ THE BASE URL IS A CONSTRUCTOR ARGUMENT, AND AN UNUSABLE ONE IS A REFUSAL AT
#   CONSTRUCTION — not at the first lookup, hours later, on a rare branch.
#
# ★ AND THE BINARY SUPPLIES IT FROM A FLAG, NOT FROM AN ENV VAR. A binary's
# configuration is flags, because env vars only get evaluated at runtime. The
# mechanism matters exactly here — `getenv("X")`
# returns `""` both for NEVER CONFIGURED and for CONFIGURED EMPTY, which are the
# two states this file most needs to tell apart, and it returns them at the
# moment the reading line executes rather than at startup. A flag is parsed
# before the process does anything and can be declared `required`, so an
# unconfigured registry is a refusal that NAMES THE FLAG instead of a peer
# lookup that fails in production on a Tuesday.
#
# `SERVICE_REGISTRY_URL_FLAG` below is that flag's canonical spelling, held here
# so every binary spells it identically. This library does not parse it: a
# library that read a process's argv would decide the CLI surface of every
# consumer. It takes the VALUE and refuses a bad one, loudly, by flag name.
#
# ⛔ THERE IS NO DEFAULT AND THERE MUST NEVER BE ONE. A default base URL is an
# unconfigured deployment that resolves SOMETHING: an unconfigured required
# input that becomes a plausible string (a committed placeholder, an empty
# render) instead of a refusal.
#
# ⛔ AND THERE IS NO "STAGE" PARAMETER. One registry serves one STAGE,
# but a stage is a deploy-model concept and this package may not hold one.
# Which stage a service belongs to is decided by WHICH URL it is given,
# resolved at deploy time.
# Nothing here can read it, check it, or default it, and that is deliberate.
#
# ENCAPSULATION: value types only, no I/O, no pointer, no origin.
# =============================================================================


comptime SERVICE_REGISTRY_URL_FLAG: String = "service-registry-url"
"""THE CANONICAL FLAG NAME. Every binary that resolves peers declares
`--service-registry-url=<base url>` and hands the value to `RegistryEndpoint`.

One spelling, held in the library, so a refusal message can name the exact
string an operator types — and so twelve binaries cannot invent twelve
near-synonyms for one input."""

comptime _SCHEME_HTTPS: StaticString = "https://"
comptime _SCHEME_HTTP: StaticString = "http://"


def registry_url_unset_refusal() -> String:
    """The message for a service that was given no registry URL.

    It names the FLAG, because that is the string the operator can type. A
    refusal that named an internal field, a struct or an env key would be a
    correct diagnosis of a problem the reader cannot act on."""
    return (
        String("service registry: no registry URL — pass --")
        + SERVICE_REGISTRY_URL_FLAG
        + String(
            "=<base url of the stage's service registry>. There is deliberately"
            " no default: a defaulted registry URL is an unconfigured"
            " deployment that resolves something."
        )
    )


def _hex2(v: Int) -> String:
    """A byte as two lowercase hex digits. Spelled out rather than reaching for
    a formatter: the refusal message must be identical on every platform."""
    comptime digits = "0123456789abcdef"
    return String(digits[byte = v // 16]) + String(digits[byte = v % 16])


def refuse_unsafe_segment(segment: String) -> String:
    """`""` if `segment` is safe as ONE path segment; otherwise the refusal.

    ★ IT REFUSES RATHER THAN PERCENT-ENCODES, AND THE SERVER IS WHY. The
    serving app does NO percent-DECODING, deliberately. So an encoding client would make the server consult a key
    containing a literal `%20`, i.e. resolve a name nobody registered and report
    `found:false` about it. That is the collapse this package exists to prevent,
    arriving through the front door.

    The accepted set is `[A-Za-z0-9._-]`.

    ⚠ THIS IS NARROWER THAN THE SERVER'S OWN RULE, AND THAT IS A STATED
    RESIDUAL. A service name is free-form in the registry's model; the serving
    app refuses only an EMPTY capture. So a name containing, say, `~` would be
    registered happily by the deploy and refused here. Refusing is still right —
    the alternative is composing a URL that means something other than the name
    — but a name outside this set is a real, if today hypothetical, gap and the
    fix is to widen this set deliberately, never to start encoding."""
    var n = segment.byte_length()
    if n == 0:
        return String(
            "service registry: empty lookup name — there is no key to consult"
        )
    var b = segment.as_bytes()
    for i in range(n):
        var c = b[i]
        var ok = (
            (c >= UInt8(97) and c <= UInt8(122))  # a-z
            or (c >= UInt8(65) and c <= UInt8(90))  # A-Z
            or (c >= UInt8(48) and c <= UInt8(57))  # 0-9
            or c == UInt8(46)  # .
            or c == UInt8(95)  # _
            or c == UInt8(45)  # -
        )
        if not ok:
            return (
                String("service registry: lookup name byte ")
                + String(i)
                + String(" (0x")
                + _hex2(Int(c))
                + String(
                    ") is not safe in one URL path segment. The registry does"
                    " no percent-decoding, so this client refuses rather than"
                    " encodes — an encoded name would consult a key nobody"
                    " registered and report it as unregistered."
                )
            )
    return String("")


def _host_of(authority: String) -> String:
    """The host part of an `authority` (`host`, `host:port`, `[v6]:port`)."""
    var b = authority.as_bytes()
    var n = len(b)
    if n > 0 and b[0] == UInt8(91):  # '[' — an IPv6 literal
        for i in range(n):
            if b[i] == UInt8(93):  # ']'
                return String(authority[byte = 0 : i + 1])
        return authority.copy()
    for i in range(n):
        if b[i] == UInt8(58):  # ':'
            return String(authority[byte=0:i])
    return authority.copy()


def host_of_base_url(base_url: String) -> String:
    """The HOST of a registry base URL, or EMPTY when there is not one to read.

    ★ PUBLIC BECAUSE A CALLER MUST BE ABLE TO ASK **WHICH ADDRESS IT DIALLED**,
    AND THAT QUESTION HAS EXACTLY ONE CORRECT ANSWER PER URL. The registry's
    in-env deploy gate has to distinguish "I traversed the published front door"
    from "I traversed the backend origin", and the only honest way to do that is
    to compare HOSTS. A substring test over the whole URL is a DIFFERENT
    question: `https://gateway.example.com/proxy/x.run.app` contains `.run.app`
    and is not a `.run.app` host; the converse mistake — a host hidden behind a
    port or a path — is the `127.evil.com` family two functions down.

    ⚠ EMPTY IS A REAL ANSWER AND CALLERS MUST FAIL CLOSED ON IT. A base with no
    recognised scheme, or with no authority, yields EMPTY — "I cannot tell what
    this names". Treating EMPTY as "not the backend" would let an unreadable
    address pass a check about which address it is.

    ⛔ IT DOES NOT VALIDATE — `parse` is the validation. This is the one host
    derivation they share, so a gate reading a host and the endpoint that dialled
    it can never disagree about what the host was."""
    var https = base_url.startswith(String(_SCHEME_HTTPS))
    var http = base_url.startswith(String(_SCHEME_HTTP))
    if not https and not http:
        return String("")
    var scheme_len = 8 if https else 7
    if base_url.byte_length() <= scheme_len:
        return String("")
    var rest = String(base_url[byte=scheme_len : base_url.byte_length()])
    var authority = rest.copy()
    var slash = rest.find(String("/"))
    if slash >= 0:
        authority = String(rest[byte=0:slash])
    if authority.byte_length() == 0:
        return String("")
    return _host_of(authority)


def _is_loopback(host: String) -> Bool:
    """Whether `host` names this machine. LITERALS ONLY.

    ⛔ IT IS AN EXACT-FORM TEST, NOT A PREFIX TEST, AND THAT DISTINCTION IS THE
    WHOLE VALUE OF THE FUNCTION. This package's first version was
    `host.startswith("127.")`, which accepts `127.evil.com`,
    `127.0.0.1.attacker.net` and (with the `localhost` arm written the same way)
    `localhost.attacker.net` — every one of them a PUBLIC DNS NAME whose
    resolution we do not control, admitted to the one carve-out that says "these
    bytes traverse nothing there is to intercept". A plaintext registry answer
    that can be rewritten in flight repoints every peer call that follows it,
    which is the serving app's own argument for having no write verb.
    `a_loopback_lookalike_hostname_is_not_loopback` is the falsifier, and it was
    RED before this function was written this way.

    A NAME that merely happens to resolve to 127.0.0.1 is likewise not accepted:
    whether it does is a property of a resolver, checked at a different time
    from the check."""
    if host == String("localhost"):
        return True
    if host == String("[::1]") or host == String("::1"):
        return True
    # A dotted quad `127.a.b.c`, every part digits-only and 1-3 long. Anything
    # with a non-digit anywhere is a NAME, not a literal.
    if not host.startswith(String("127.")):
        return False
    var b = host.as_bytes()
    var n = len(b)
    var parts = 1
    var part_len = 0
    for i in range(n):
        var c = b[i]
        if c == UInt8(46):  # '.'
            if part_len == 0:
                return False
            parts += 1
            part_len = 0
            continue
        if c < UInt8(48) or c > UInt8(57):
            return False
        part_len += 1
        if part_len > 3:
            return False
    return parts == 4 and part_len > 0


@fieldwise_init
struct RegistryEndpoint(Copyable, Movable, Deinitable):
    """A VALIDATED registry base URL. Constructing one is the bootstrap check.

    ⛔ THERE IS NO WAY TO BUILD AN UNVALIDATED ONE THROUGH `parse`, which is the
    only public constructor a caller should use."""

    var base: String
    """The base URL, trailing slashes stripped, so appending an absolute path
    can never produce `//v1/services/x`."""

    var plaintext: Bool
    """Whether this endpoint is `http://` (only possible for a loopback host —
    see `parse`)."""

    @staticmethod
    def parse(base_url: String) raises -> Self:
        """Validate and normalise a registry base URL, or RAISE naming the flag.

        ⛔ RAISING IS CORRECT HERE AND NOWHERE ELSE IN THIS PACKAGE. Every
        LOOKUP failure is a value, because a lookup failure is an ordinary
        runtime event a caller must branch on. A registry URL that cannot be
        used is a CONFIGURATION defect: there is no runtime branch that makes it
        better, the process cannot do its job, and the only correct response is
        to fail at startup where the operator is watching.

        ★ PLAINTEXT IS REFUSED EXCEPT TO A LOOPBACK LITERAL. Anyone who can
        rewrite `service/<name>` in flight owns every peer's traffic — which
        is the serving app's own argument for having no write verb, and it
        applies identically to an answer that can be rewritten on the way back.
        This is NOT an auth concept (it authenticates no principal and mints
        nothing); it is whether the bytes can be altered in transit. "It is a
        private network" is not an accepted argument in this repo: the boundary
        is IAM/transport identity, never the network. Loopback is carved out
        because local development needs it and a loopback dial does not
        traverse anything."""
        if base_url.byte_length() == 0:
            raise Error(registry_url_unset_refusal())

        var https = base_url.startswith(String(_SCHEME_HTTPS))
        var http = base_url.startswith(String(_SCHEME_HTTP))
        if not https and not http:
            raise Error(
                String("service registry: --")
                + SERVICE_REGISTRY_URL_FLAG
                + String(
                    " must be an absolute URL beginning http:// or https://."
                    " A bare host is ambiguous about the scheme, and the"
                    " scheme is what decides whether the answer can be"
                    " rewritten in flight."
                )
            )

        if base_url.find(String("?")) >= 0 or base_url.find(String("#")) >= 0:
            raise Error(
                String("service registry: --")
                + SERVICE_REGISTRY_URL_FLAG
                + String(
                    " must carry no query and no fragment — this client appends"
                    " a path to it, and appending after a query produces a URL"
                    " that means something else."
                )
            )

        # ★ ONE HOST DERIVATION, SHARED WITH `host_of_base_url`. The gate that
        # asks WHICH host was dialled and the parse that decided the URL was
        # usable must not be able to disagree about what the host is; a second
        # copy here is a second answer waiting to drift.
        var host = host_of_base_url(base_url)
        if host.byte_length() == 0:
            raise Error(
                String("service registry: --")
                + SERVICE_REGISTRY_URL_FLAG
                + String(" carries no host")
            )

        if http and not _is_loopback(host):
            raise Error(
                String("service registry: --")
                + SERVICE_REGISTRY_URL_FLAG
                + String(" is plaintext http:// to non-loopback host '")
                + host
                + String(
                    "'. Anyone who can rewrite a registry answer in flight"
                    " repoints every peer call that follows it. Use https://,"
                    " or a loopback literal for local development."
                )
            )

        # Strip trailing slashes. The temporary is load-bearing under Mojo
        # 1.0.0: assigning the slice straight back aliases one String as both
        # the initializer's argument and its destination.
        var b = base_url.copy()
        while b.byte_length() > 0 and b.endswith(String("/")):
            var trimmed = String(b[byte = 0 : b.byte_length() - 1])
            b = trimmed^
        return Self(b^, http)

    def url_for(self, path: String) -> String:
        """`<base><path>`, where `path` is absolute (`/v1/services/x`)."""
        return self.base + path
